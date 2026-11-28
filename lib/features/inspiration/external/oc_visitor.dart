part of 'oc_sources.dart';

class _Reply {
  _Reply(this.status, this.bytes, this.location, this.type);
  final int status;
  final Uint8List bytes;
  final Uri location;
  final String? type;
  bool get guestPage {
    if (bytes.isEmpty || (type != 'text/html' && bytes.first != 60)) {
      return false;
    }
    final page = utf8.decode(bytes.take(16384).toList(), allowMalformed: true);
    return RegExp(r'''data-auth=["']guest["']''').hasMatch(page);
  }

  bool get needsLogin =>
      status == 401 || status == 403 || location.path == '/login' || guestPage;
  Object? get json => jsonDecode(utf8.decode(bytes).replaceFirst('\uFEFF', ''));
}

// A visitor session belongs to one origin. A redirect never receives another
// origin's cookies, CSRF token or password.
class _Visitor {
  _Visitor(this.location, this.client, {this.restore, this.persist});
  final Uri location;
  final HttpClient client;
  final Future<String?> Function()? restore;
  Future<void> Function(String?)? persist;
  final _cookies = <(String, String), Cookie>{};
  Future<void>? _ready, _login;
  Future<void> _writing = Future.value();
  String? _lastSaved;
  int _generation = 0;
  DateTime? _retryAfter;
  OcAccessError? _rejection;

  bool _valid(Cookie c, DateTime now) =>
      c.expires == null || c.expires!.isAfter(now);
  bool _pathMatches(String path, String scope) =>
      path == scope || path.startsWith(scope.endsWith('/') ? scope : '$scope/');

  Future<void> _restore() async {
    try {
      final saved = await restore?.call();
      if (saved == null) return;
      for (final line in (jsonDecode(saved) as List).whereType<String>()) {
        final c = Cookie.fromSetCookieValue(line);
        if (c.expires != null && _valid(c, DateTime.now())) {
          _cookies[(c.name, c.path ?? '/')] = c;
        }
      }
      _lastSaved = saved;
    } catch (_) {
      // A discarded or unreadable cookie can be renewed by the normal login.
    }
  }

  Future<void> saveCookies() {
    final write = persist;
    if (write == null) return Future.value();
    final now = DateTime.now();
    final lines = [
      for (final c in _cookies.values)
        if (c.expires != null && _valid(c, now)) c.toString(),
    ]..sort();
    final payload = lines.isEmpty ? null : jsonEncode(lines);
    if (payload == _lastSaved) return _writing;
    _lastSaved = payload;
    // Secure storage is optional for live browsing. Serialize rotating
    // cookies so a slow older write cannot replace the current session.
    return _writing = _writing.then((_) async {
      if (persist == null) return;
      try {
        await write(payload);
      } catch (_) {
        if (_lastSaved == payload) _lastSaved = null;
      }
    });
  }

  Future<void> stopSaving() {
    persist = null;
    return _writing;
  }

  void _accept(Cookie cookie, Uri target) {
    final domain = cookie.domain?.toLowerCase().replaceFirst(
      RegExp(r'^\.'),
      '',
    );
    if (domain != null &&
        domain != target.host &&
        !target.host.endsWith('.$domain')) {
      return;
    }
    if (cookie.secure && target.scheme != 'https') return;
    final slash = target.path.lastIndexOf('/');
    if (cookie.path?.startsWith('/') != true) {
      cookie.path = slash > 0 ? target.path.substring(0, slash) : '/';
    }
    final now = DateTime.now().toUtc();
    final age = cookie.maxAge;
    final key = (cookie.name, cookie.path!);
    if (age != null && age <= 0) {
      _cookies.remove(key);
      return;
    }
    if (age != null) {
      // Persist an absolute expiry so relaunching never extends Max-Age.
      final maximum = DateTime.utc(9999, 12, 31).difference(now).inSeconds;
      cookie.expires = now.add(
        Duration(seconds: age > maximum ? maximum : age),
      );
      cookie.maxAge = null;
    }
    if (_valid(cookie, now)) {
      _cookies[key] = cookie;
    } else {
      _cookies.remove(key);
    }
  }

  Future<_Reply> request(
    Uri start, {
    OcJson? body,
    String? csrf,
    int limit = 24 << 20,
    _OcConnectionTrace? trace,
    _OcStage stage = _OcStage.landing,
  }) async {
    trace?.enter(stage);
    await (_ready ??= _restore());
    final generation = _generation;
    var target = start;
    for (var redirect = 0; redirect <= 5; redirect++) {
      if (target.origin != location.origin || target.userInfo.isNotEmpty) {
        throw const OcAccessError._(
          '此链接跳转到了另一个站点，请输入最终资料库网址',
          'crossOriginRedirect',
        );
      }
      trace?.httpStatus = null;
      trace?.requestTo(target);
      final req = await client
          .openUrl(body == null ? 'GET' : 'POST', target)
          .timeout(const Duration(seconds: 20));
      req.followRedirects = false;
      req.cookies.addAll(
        _cookies.values.where(
          (c) =>
              _valid(c, DateTime.now()) &&
              _pathMatches(target.path, c.path!) &&
              (!c.secure || target.scheme == 'https'),
        ),
      );
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.headers.set('Origin', location.origin);
        req.headers.set('Referer', location.resolve('/login').toString());
        if (csrf != null) req.headers.set('X-CSRF-Token', csrf);
        req.add(utf8.encode(jsonEncode(body)));
      }
      final response = await req.close().timeout(const Duration(seconds: 25));
      trace?.httpStatus = response.statusCode;
      if (generation == _generation && response.cookies.isNotEmpty) {
        for (final cookie in response.cookies) {
          _accept(cookie, target);
        }
        await saveCookies();
      }
      if (response.isRedirect) {
        final next = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>().timeout(const Duration(seconds: 20));
        if (next == null || body != null) {
          throw const OcAccessError._('访客请求被重定向', 'unexpectedRedirect');
        }
        target = target.resolve(next);
        continue;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 25))) {
        if (bytes.length + chunk.length > limit) {
          throw const OcAccessError._('单个资料文件过大', 'sizeLimit');
        }
        bytes.add(chunk);
      }
      return _Reply(
        response.statusCode,
        bytes.takeBytes(),
        target,
        response.headers.contentType?.mimeType,
      );
    }
    throw const OcAccessError._('资料库重定向次数过多', 'redirectLimit');
  }

  Future<void> login(
    Future<String?> Function() password, {
    _OcConnectionTrace? trace,
  }) {
    trace?.enter(_OcStage.guestLogin);
    if (_retryAfter?.isAfter(DateTime.now()) == true) {
      return Future.error(_rejection!);
    }
    return _login ??= _authenticate(password, trace)
        .then((_) {
          _rejection = null;
          _retryAfter = null;
        })
        .onError((OcAccessError e, StackTrace stack) {
          if (e._reason == 'guestRejected' ||
              (e._reason == 'guestHttp' && e.status == 429)) {
            _rejection = e;
            _retryAfter = DateTime.now().add(const Duration(minutes: 1));
          }
          Error.throwWithStackTrace(e, stack);
        })
        .whenComplete(() => _login = null);
  }

  Future<void> _authenticate(
    Future<String?> Function() secret,
    _OcConnectionTrace? trace,
  ) async {
    _generation++;
    if (location.scheme != 'https' &&
        !{'localhost', '127.0.0.1', '::1'}.contains(location.host)) {
      throw const OcAccessError._('带口令的资料库需要 HTTPS', 'httpsRequired');
    }
    trace?.enter(_OcStage.readPassword);
    final pw = await secret();
    if (pw == null || pw.isEmpty) {
      throw const OcAccessError._('此资料库需要访客口令，请在导入页填写', 'passwordRequired');
    }
    final session = await request(
      location.resolve('/api/session'),
      trace: trace,
      stage: _OcStage.session,
    );
    if (session.status != 200) {
      throw OcAccessError('建立访客会话失败（HTTP ${session.status}）', session.status);
    }
    final data = session.json;
    if (data is! Map) {
      throw const OcAccessError._('访客会话接口返回的数据格式无法识别', 'format');
    }
    final csrf = data['csrfToken'];
    final auth = await request(
      location.resolve('/api/session/guest'),
      body: {'password': pw},
      csrf: csrf is String ? csrf : null,
      trace: trace,
      stage: _OcStage.guestLogin,
    );
    if (auth.status == 401 || auth.status == 403) {
      throw OcAccessError._(
        '站点拒绝访客登录（HTTP ${auth.status}），请检查访客口令和访问权限。',
        'guestRejected',
        auth.status,
      );
    }
    if (auth.status != 200) {
      throw OcAccessError._(
        '站点未接受访客登录（HTTP ${auth.status}）',
        'guestHttp',
        auth.status,
      );
    }
  }

  Future<_Reply> read(
    Uri url, {
    required bool guest,
    required Future<String?> Function() secret,
    _OcConnectionTrace? trace,
  }) async {
    if (guest && _login != null) {
      trace?.enter(_OcStage.guestLogin);
      await _login;
    }
    final generation = _generation;
    var r = await request(url, trace: trace, stage: _OcStage.catalog);
    if (guest && r.needsLogin) {
      if (generation == _generation) {
        await login(secret, trace: trace);
      } else if (_login != null) {
        trace?.enter(_OcStage.guestLogin);
        await _login;
      }
      r = await request(url, trace: trace, stage: _OcStage.catalog);
    }
    if (r.status != 200) {
      throw OcAccessError('资料读取失败（HTTP ${r.status}），可在导入页更新连接', r.status);
    }
    if (guest && r.needsLogin) {
      throw OcAccessError._(
        '登录后站点仍要求访客验证，请在导入页重新连接。',
        'sessionRequired',
        r.status,
      );
    }
    return r;
  }
}
