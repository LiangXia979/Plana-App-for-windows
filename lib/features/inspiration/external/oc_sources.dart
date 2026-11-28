import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/auth/secure_storage.dart';
import '../../../core/net/network_proxy.dart';
import '../../../core/store/app_stores.dart';
import '../../../core/store/atomic_file.dart';
import '../../../core/util/runtime_diagnostics.dart';
import '../tag_models.dart';
import '../../assistant/assistant_settings.dart';
import 'oc_catalog.dart';

part 'oc_connection_diagnostics.dart';
part 'oc_visitor.dart';

class OcSource {
  OcSource(
    this.location,
    this.label,
    this.catalog,
    this.guest, {
    this.added = const {},
  });
  factory OcSource.fromJson(OcJson j) => OcSource(
    Uri.parse(j['location'] as String),
    j['label'] as String,
    OcCatalog.parse(j['catalog']),
    j['guest'] == true,
    added: {
      if (j['added'] case final Map dates)
        for (final e in dates.entries)
          if (e.key is String && e.value is int)
            e.key as String: e.value as int,
    },
  );
  final Uri location;
  final String label;
  final OcCatalog catalog;
  final bool guest;
  final Map<String, int> added;
  int timeOf(OcCharacter c) => c.updatedAt > 0 ? c.updatedAt : added[c.id] ?? 0;
  late final String id = ocKey(location.toString());

  Iterable<String> tagsWithEdits(Map<String, List<String>> overrides) sync* {
    yield* catalog.tags;
    for (final e in overrides.entries) {
      if (e.key.startsWith('ext:$id:')) yield* e.value;
    }
  }
}

class OcAccessError implements Exception {
  const OcAccessError(this.message, [this.status]) : _reason = null;
  const OcAccessError._(this.message, this._reason, [this.status]);
  final String message;
  final int? status;
  final String? _reason;
  @override
  String toString() => message;
}

Uri ocWebLocation(String text) {
  try {
    return _webLocation(text);
  } on OcAccessError catch (error) {
    _OcConnectionTrace(local: false, hourly: false).record('failed', error);
    rethrow;
  }
}

Uri _webLocation(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null ||
      !{'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const OcAccessError._('请输入完整的 http 或 https 网址', 'invalidAddress');
  }
  final normalized = uri.path.isEmpty ? uri.replace(path: '/') : uri;
  return normalized.removeFragment();
}

final ocRepositoryProvider = Provider<OcRepository>((ref) {
  final vault = ref.read(secureStorageProvider);
  final repo = OcRepository(
    Directory(
      p.join(ref.read(prefsStoreProvider).supportDirectory.path, 'external_oc'),
    ),
    readSecret: (id) => vault.read(key: 'external_oc_$id'),
    saveSecret: (id, s) => vault.write(key: 'external_oc_$id', value: s),
    deleteSecret: (id) => vault.delete(key: 'external_oc_$id'),
    onRemoved: (removed) async {
      if (!ref.mounted) return;
      final settings = await ref.read(assistantSettingsProvider.future);
      final saved = settings.sourceSelection;
      if (ref.mounted &&
          saved != null &&
          (saved.enabled.contains(removed) || saved.order.contains(removed))) {
        await ref
            .read(assistantSettingsProvider.notifier)
            .patch(
              (s) => s.copyWith(sourceSelection: s.libraries.without(removed)),
            );
      }
    },
  );
  ref.onDispose(repo.close);
  return repo;
});

typedef OcRead = Future<Uint8List> Function(Future<Uint8List> Function() load);

class OcRepository {
  OcRepository(
    this.root, {
    required this.readSecret,
    required this.saveSecret,
    required this.deleteSecret,
    this.onRemoved,
    this.now = DateTime.now,
  });
  final Directory root;
  final DateTime Function() now;
  final Future<String?> Function(String) readSecret;
  final Future<void> Function(String, String) saveSecret;
  final Future<void> Function(String) deleteSecret;
  final Future<void> Function(String removedId)? onRemoved;
  final _changes = StreamController<void>.broadcast(sync: true);
  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 3;
  final _visitors = <String, _Visitor>{};
  final _pending = <String, Future<Uint8List>>{};
  final _mutations = <String, Future<void>>{};
  final _checkedHour = <String, int>{};
  Timer? _refreshTimer;
  bool _closed = false;

  void close() {
    _closed = true;
    _refreshTimer?.cancel();
    _client.close(force: true);
    unawaited(_changes.close());
  }

  File _file(String id, String name) => File(p.join(root.path, id, name));
  Future<void> Function(String?) _cookieWriter(String id) =>
      (value) => value == null
      ? deleteSecret('session_$id')
      : saveSecret('session_$id', value);

  _Visitor _visitor(Uri uri) => _visitors.putIfAbsent(uri.toString(), () {
    final id = ocKey(uri.toString());
    return _Visitor(
      uri,
      _client,
      restore: () => readSecret('session_$id'),
      persist: _cookieWriter(id),
    );
  });

  Future<T> _update<T>(String id, Future<T> Function() run) {
    final result = (_mutations[id] ?? Future.value()).then((_) => run());
    final done = result.then<void>((_) {}, onError: (Object _) {});
    _mutations[id] = done;
    unawaited(
      done.then((_) {
        if (identical(_mutations[id], done)) _mutations.remove(id);
      }),
    );
    return result;
  }

  // The guest atlas publishes on the hour. Let it finish switching releases.
  static const _grace = Duration(seconds: 10);
  int _hour(DateTime time) =>
      (time.millisecondsSinceEpoch - _grace.inMilliseconds) ~/
      Duration.millisecondsPerHour;

  void _schedule(List<OcSource> sources, {bool catchUp = true}) {
    _refreshTimer?.cancel();
    if (_closed || !sources.any((s) => s.guest && s.catalog.atlas)) return;
    final current = now();
    final hour = _hour(current);
    final due =
        catchUp &&
        sources.any(
          (s) =>
              s.guest && s.catalog.atlas && (_checkedHour[s.id] ?? -1) < hour,
        );
    final next = DateTime.fromMillisecondsSinceEpoch(
      (hour + 1) * Duration.millisecondsPerHour + _grace.inMilliseconds,
      isUtc: true,
    );
    _refreshTimer = Timer(
      due ? Duration.zero : next.difference(current),
      () async {
        try {
          await refreshDue();
          if (!_closed) _schedule(await this.sources());
        } on FileSystemException {
          if (!_closed) _schedule(sources, catchUp: false);
        }
      },
    );
  }

  Future<void> refreshDue() async {
    final hour = _hour(now());
    for (final source in await sources()) {
      if (_closed) return;
      if (!source.guest ||
          !source.catalog.atlas ||
          (_checkedHour[source.id] ?? -1) >= hour) {
        continue;
      }
      _checkedHour[source.id] = hour;
      try {
        await _update(source.id, () async {
          if (!_closed && await _file(source.id, 'source.json').exists()) {
            await _connect(source.location, hourly: true);
          }
        });
      } on Exception {
        // A failed check never replaces a working catalog. The user can retry
        // from the import page before the next scheduled check.
      }
    }
  }

  Future<List<OcSource>> sources() async {
    final all = <OcSource>[];
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final file = File(p.join(entity.path, 'source.json'));
        if (!await file.exists()) continue;
        try {
          final source = OcSource.fromJson(
            jsonDecode(await file.readAsString()) as OcJson,
          );
          if (p.basename(entity.path) == source.id) {
            if (source.guest && !_checkedHour.containsKey(source.id)) {
              _checkedHour[source.id] = _hour(await file.lastModified());
            }
            all.add(source);
          }
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }
    }
    return all..sort((a, b) => a.label.compareTo(b.label));
  }

  Future<OcSource> connect(
    Uri location, {
    String label = '',
    String? password,
  }) => _update(
    ocKey(location.toString()),
    () => _connect(location, label: label, password: password),
  );

  Future<OcSource> _connect(
    Uri location, {
    String label = '',
    String? password,
    bool hourly = false,
  }) {
    final trace = _OcConnectionTrace(
      local: location.isScheme('file'),
      hourly: hourly,
    );
    return trace.run(
      () => _loadSource(
        location,
        trace,
        label: label,
        password: password,
        preserveLabel: hourly,
      ),
    );
  }

  Future<OcSource> _loadSource(
    Uri location,
    _OcConnectionTrace trace, {
    required String label,
    required String? password,
    required bool preserveLabel,
  }) async {
    trace.enter(_OcStage.readCache);
    final id = ocKey(location.toString());
    final snapshot = _file(id, 'source.json');
    OcSource? previous;
    Object? oldCatalog;
    if (await snapshot.exists()) {
      try {
        final record = jsonDecode(await snapshot.readAsString()) as OcJson;
        previous = OcSource.fromJson(record);
        oldCatalog = record['catalog'];
      } on FormatException {
        // A fresh import can repair an older or damaged index.
      } on TypeError {
        // A fresh import can repair missing fields.
      }
    }
    Object? raw;
    late final OcCatalog catalog;
    var guest = false;
    if (location.isScheme('file')) {
      trace.enter(_OcStage.readFile);
      final file = File.fromUri(location);
      if (await file.length() > 24 << 20) {
        throw const OcAccessError._('JSON 文件过大', 'sizeLimit');
      }
      final text = await file.readAsString();
      trace.enter(_OcStage.parseCatalog);
      raw = jsonDecode(text.replaceFirst('\uFEFF', ''));
      catalog = OcCatalog.parse(raw);
    } else {
      trace.enter(_OcStage.address);
      _webLocation(location.toString());
      // Preserve the live session on refresh. Validate a replacement password
      // in isolation so a typo cannot discard an existing login.
      final resume = previous?.guest == true && password == null;
      final visitor = resume ? _visitor(location) : _Visitor(location, _client);
      Future<String?> secret() async => password ?? await readSecret(id);
      _Reply? listing;
      guest = resume;
      if (!resume) {
        final landing = await visitor.request(location, trace: trace);
        guest = landing.guestPage;
        if (landing.status != 200 &&
            !(guest && (landing.status == 401 || landing.status == 403))) {
          throw OcAccessError(
            '打开资料库网址失败（HTTP ${landing.status}）',
            landing.status,
          );
        }
        final page = utf8
            .decode(landing.bytes, allowMalformed: true)
            .trimLeft();
        if (page.startsWith('<')) {
          if (!guest && !page.contains('/gallery.js')) {
            throw const OcAccessError._(
              '请填写 JSON 资料库链接，或选择网站导出的 JSON 文件',
              'unsupportedPage',
            );
          }
          if (guest) await visitor.login(secret, trace: trace);
        } else {
          listing = landing;
        }
      }
      listing ??= await visitor.read(
        location.resolve('/api/catalog'),
        guest: guest,
        secret: secret,
        trace: trace,
      );
      trace.enter(_OcStage.parseCatalog, status: listing.status);
      raw = listing.json;
      catalog = OcCatalog.parse(raw);
      if (guest && !catalog.atlas) {
        throw const OcAccessError._('此访客图鉴没有提供形态目录', 'missingFormCatalog');
      }
      if (guest && password != null && password.isNotEmpty) {
        trace.enter(_OcStage.saveCredentials);
        await saveSecret(id, password);
      }
      if (!resume) {
        trace.enter(_OcStage.saveCredentials);
        await _visitors[location.toString()]?.stopSaving();
        if (previous?.guest == true) await deleteSecret('session_$id');
        _visitors[location.toString()] = visitor;
        if (guest) {
          visitor.persist = _cookieWriter(id);
          await visitor.saveCookies();
        }
      }
    }
    trace.enter(_OcStage.saveCache);
    final display = preserveLabel && previous != null
        ? previous.label
        : label.trim().isNotEmpty
        ? label.trim()
        : catalog.name.isNotEmpty
        ? catalog.name
        : location.isScheme('file')
        ? p.basenameWithoutExtension(location.toFilePath())
        : location.host;
    final checked = now();
    _checkedHour[id] = _hour(checked);
    if (previous != null &&
        previous.label == display &&
        previous.guest == guest &&
        jsonEncode(oldCatalog) == jsonEncode(raw)) {
      await snapshot.setLastModified(checked);
      return previous;
    }
    final added = <String, int>{};
    if (previous != null) {
      final known = previous.catalog.characters.map((c) => c.id).toSet();
      final now = checked.millisecondsSinceEpoch;
      for (final c in catalog.characters) {
        final time = previous.added[c.id] ?? (known.contains(c.id) ? 0 : now);
        if (time > 0) added[c.id] = time;
      }
    }
    final source = OcSource(location, display, catalog, guest, added: added);
    await writeStringAtomic(
      snapshot,
      jsonEncode({
        'location': location.toString(),
        'label': display,
        'guest': guest,
        'catalog': raw,
        if (added.isNotEmpty) 'added': added,
      }),
    );
    if (!_changes.isClosed) _changes.add(null);
    return source;
  }

  Future<void> remove(OcSource source) => _update(source.id, () async {
    await _visitors.remove(source.location.toString())?.stopSaving();
    await deleteSecret(source.id);
    if (source.guest) await deleteSecret('session_${source.id}');
    _checkedHour.remove(source.id);
    final dir = _file(source.id, 'source.json').parent;
    if (await dir.exists()) await dir.delete(recursive: true);
    if (!_changes.isClosed) _changes.add(null);
    await onRemoved?.call(source.id);
  });

  Future<Uint8List> _cached(File file, Future<Uint8List> Function() read) =>
      _pending.putIfAbsent(file.path, () async {
        try {
          if (await file.exists()) return await file.readAsBytes();
          final bytes = await read();
          await writeBytesAtomic(file, bytes);
          return bytes;
        } finally {
          unawaited(_pending.remove(file.path));
        }
      });

  Future<List<TagEntry>> character(
    OcSource source,
    OcCharacter character, {
    bool withImages = true,
    String? coverEntryId,
    OcRead? schedule,
  }) async {
    Future<Uint8List> cached(File file, Future<Uint8List> Function() load) =>
        schedule == null
        ? _cached(file, load)
        : schedule(() => _cached(file, load));
    final catalog = source.catalog;
    final details = <OcFormData>[];
    final visitor = source.location.isScheme('file')
        ? null
        : _visitor(source.location);
    Future<_Reply> read(Uri uri) => visitor!.read(
      uri,
      guest: source.guest,
      secret: () => readSecret(source.id),
    );
    for (final f in character.forms) {
      String? positive = f.positive;
      var negative = f.negative;
      if (positive == null) {
        if (visitor == null) throw const OcAccessError('本地文件需要包含各形态的提示词');
        final uri = source.location
            .resolve('/api/forms/${Uri.encodeComponent(f.id)}')
            .replace(
              queryParameters: catalog.release.isEmpty
                  ? null
                  : {'release': catalog.release},
            );
        final bytes = await cached(
          _file(source.id, 'forms/${ocKey(uri.toString())}.json'),
          () async {
            final reply = await read(uri);
            final data = reply.json;
            if (data is! Map ||
                data['id'] != f.id ||
                (!data.containsKey('prompt') &&
                    !data.containsKey('negativePrompt'))) {
              throw const OcAccessError('形态资料与目录不匹配，请刷新来源');
            }
            return reply.bytes;
          },
        );
        final data = jsonDecode(utf8.decode(bytes)) as Map;
        positive = data['prompt'] as String? ?? '';
        negative = data['negativePrompt'] as String? ?? '';
      }
      details.add((
        positive: positive,
        negative: negative,
        images: withImages ? f.images : const [],
      ));
    }
    final entries = groupOcForms(source.id, character, details);
    if (!withImages) return entries;
    final resolved = <TagEntry>[];
    for (final entry in entries) {
      if (coverEntryId != null && entry.id != coverEntryId) continue;
      final images = <String>{};
      for (final image in entry.previews) {
        final uri = source.location.isScheme('file') && p.isAbsolute(image)
            ? File(image).uri
            : source.location.resolve(image.replaceAll('\\', '/'));
        if (uri.isScheme('file') &&
            source.location.isScheme('file') &&
            uri.host.isEmpty) {
          images.add(uri.toFilePath());
        } else if ((uri.isScheme('https') || uri.isScheme('http')) &&
            uri.userInfo.isEmpty) {
          if (source.guest && uri.origin == source.location.origin) {
            final file = _file(
              source.id,
              'images/${ocKey('${catalog.release}|$uri')}.img',
            );
            try {
              await cached(file, () async {
                final reply = await read(uri);
                if (reply.type?.startsWith('image/') != true) {
                  throw const OcAccessError('站点未返回图片');
                }
                return reply.bytes;
              });
              images.add(file.path);
            } on OcAccessError catch (e) {
              if (e.status != 404 && e.status != 410) rethrow;
            }
          } else {
            images.add(uri.toString());
          }
        }
        if (coverEntryId != null && images.isNotEmpty) break;
      }
      resolved.add(entry.copyWith(previews: images.toList()));
    }
    return resolved;
  }

  // Character instances belong to one catalog revision. Lookup and prefetch
  // share their text without reading the artwork or pinning an old revision.
  final _referenceCache = Expando<Map<String, Future<List<TagEntry>>>>();
  Future<List<TagEntry>> referenceEntries(
    OcSource source, {
    bool Function(OcCharacter)? matches,
  }) async {
    final cache = _referenceCache[source] ??= {};
    final characters = matches == null
        ? source.catalog.characters
        : source.catalog.characters.where(matches).toList();
    final entries = List<List<TagEntry>?>.filled(characters.length, null);
    var next = 0;
    var failed = false;
    Future<void> worker() async {
      while (!failed && next < characters.length) {
        final i = next++;
        try {
          final item = characters[i];
          entries[i] = await (cache[item.id] ??=
              character(source, item, withImages: false).onError((
                Object error,
                StackTrace stack,
              ) {
                cache.remove(item.id);
                Error.throwWithStackTrace(error, stack);
              }));
        } catch (_) {
          failed = true;
          rethrow;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < 3 && i < characters.length; i++) worker(),
    ]);
    return [for (final group in entries) ...group!];
  }

  File get favoritesFile => File(p.join(root.path, 'favorites.json'));
}

final ocSourcesProvider = FutureProvider<List<OcSource>>((ref) async {
  final repository = ref.watch(ocRepositoryProvider);
  final changes = repository._changes.stream.listen(
    (_) => ref.invalidateSelf(),
  );
  ref.onDispose(changes.cancel);
  final sources = await repository.sources();
  if (ref.mounted) repository._schedule(sources);
  return sources;
});

final ocFavoritesProvider = NotifierProvider<OcFavorites, Set<String>>(
  OcFavorites.new,
);

class OcFavorites extends Notifier<Set<String>> {
  Future<void> _writes = Future.value();
  @override
  Set<String> build() {
    final file = ref.watch(ocRepositoryProvider).favoritesFile;
    if (!file.existsSync()) return {};
    try {
      return (jsonDecode(file.readAsStringSync()) as List)
          .whereType<String>()
          .toSet();
    } on FormatException {
      return {};
    }
  }

  Future<void> toggle(String id) {
    final next = {...state};
    if (!next.remove(id)) next.add(id);
    state = next;
    final file = ref.read(ocRepositoryProvider).favoritesFile;
    final write = _writes.then(
      (_) => writeStringAtomic(file, jsonEncode(next.toList())),
    );
    _writes = write.catchError((Object _) {});
    return write;
  }
}
