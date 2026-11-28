part of 'oc_sources.dart';

enum _OcStage {
  address('检查网址'),
  readCache('读取本机缓存'),
  readFile('打开本地 JSON'),
  landing('打开资料库网址'),
  readPassword('读取访客口令'),
  session('建立访客会话'),
  guestLogin('验证访客口令'),
  catalog('获取角色目录'),
  parseCatalog('解析角色目录'),
  saveCredentials('保存访客凭据'),
  saveCache('保存本机目录缓存');

  const _OcStage(this.label);
  final String label;
}

enum _OcFailure {
  dns('无法解析域名，请检查网址、网络和代理设置。'),
  refused('连接被拒绝，请检查站点和代理是否可用。'),
  timeout('连接超时，请检查网络或代理后重试。'),
  tls('HTTPS 安全连接失败，请检查系统时间、站点证书和代理设置。'),
  network('网络连接中断或无法建立，请检查网络和代理设置。'),
  protocol('未收到有效的 HTTP 响应。'),
  format('返回的数据格式无法识别。'),
  file('无法读取或写入本机文件。'),
  credentials('无法访问本机安全存储。'),
  unexpected('请开启诊断日志后重试。');

  const _OcFailure(this.hint);
  final String hint;

  static _OcFailure from(Object error, _OcStage stage) => switch (error) {
    TimeoutException() => timeout,
    TlsException() => tls,
    SocketException(:final message, :final osError) => switch (osError
        ?.errorCode) {
      11001 || 11002 || 11003 || 11004 => dns,
      10061 || 111 || 61 => refused,
      10060 || 110 || 60 => timeout,
      _ => message.toLowerCase().contains('failed host lookup') ? dns : network,
    },
    HttpException() => protocol,
    _
        when stage == _OcStage.readPassword ||
            stage == _OcStage.saveCredentials =>
      credentials,
    FormatException() || TypeError() => format,
    FileSystemException() => file,
    _ => unexpected,
  };
}

/// One manual connection or hourly refresh. Only fixed field names, code
/// categories, and numeric status codes go into the shareable text log.
class _OcConnectionTrace {
  _OcConnectionTrace({required this.local, required this.hourly});
  final bool local, hourly;
  var stage = _OcStage.address;
  int? httpStatus;
  String? route;

  void enter(_OcStage next, {int? status}) {
    stage = next;
    httpStatus = status;
    if (status == null) route = null;
  }

  void requestTo(Uri target) {
    if (RuntimeDiagnostics.current == null) return;
    final overrides = HttpOverrides.current;
    if (overrides is NetworkProxyOverrides) {
      final settings = overrides.settings;
      // Record the routing policy, never the proxy address or the destination.
      route = !settings.enabled
          ? 'environment'
          : settings.bypassLocal && isLocalProxyDestination(target.host)
          ? 'local-bypass'
          : 'app-proxy';
    }
  }

  void record(String result, [Object? error]) {
    final log = RuntimeDiagnostics.current;
    if (log == null) return;
    final http = error is OcAccessError
        ? error.status ?? httpStatus
        : httpStatus;
    final reason = error is OcAccessError
        ? error._reason ?? (http != null ? 'http' : 'access')
        : error != null
        ? _OcFailure.from(error, stage).name
        : null;
    final os = switch (error) {
      SocketException(:final osError) ||
      TlsException(:final osError) ||
      FileSystemException(:final osError) => osError?.errorCode,
      _ => null,
    };
    log.event(
      'external-oc',
      [
        'action=${hourly ? 'hourly' : 'connect'}',
        'source=${local ? 'file' : 'web'}',
        'stage=${stage.name}',
        'result=$result',
        if (reason != null) 'reason=$reason',
        if (error != null) 'type=${error.runtimeType}',
        if (route != null) 'route=$route',
        if (http != null) 'http=$http',
        if (os != null) 'os=$os',
      ].join(' '),
    );
  }

  Future<OcSource> run(Future<OcSource> Function() connect) async {
    record('start');
    try {
      final source = await connect();
      record('success');
      return source;
    } catch (error, stack) {
      record('failed', error);
      if (error is OcAccessError ||
          (error is FormatException && stage == _OcStage.parseCatalog)) {
        rethrow;
      }
      final hint = _OcFailure.from(error, stage).hint;
      Error.throwWithStackTrace(
        OcAccessError('${stage.label}失败。$hint', httpStatus),
        stack,
      );
    }
  }
}
