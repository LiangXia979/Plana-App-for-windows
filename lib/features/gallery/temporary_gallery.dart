import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/store/atomic_file.dart';
import '../../core/store/blob_store.dart';
import 'gallery_store.dart';
import 'models.dart';

const temporaryLibraryId = '@temporary';

class _Bucket {
  _Bucket(this.directory, this.canvas, this.name)
    : blobs = BlobStore(directory) {
    files = GalleryStore(blobs, directory);
  }
  final Directory directory;
  final String canvas;
  String name;
  final BlobStore blobs;
  late final GalleryStore files;
  List<ResultImage> images = [];
  final promoted = <String>{};
  final filed = <String>{};
  bool recovered = false;
  File get retained => File(p.join(directory.path, 'retained'));
  File get metadata => File(p.join(directory.path, 'canvas.json'));
  Future<void> saveMetadata() => writeStringAtomic(
    metadata,
    jsonEncode({
      'canvas': canvas,
      'name': name,
      'promoted': promoted.toList(),
      'filed': filed.toList(),
    }),
  );
  Future<void> saveIndex() {
    files.scheduleIndex(results: images, selectedId: null, seq: 0);
    return files.flushIndex();
  }
}

class _Session {
  _Session(this.root, this.lease);
  final Directory root;
  final RandomAccessFile lease;
  final buckets = <_Bucket>[];
}

/// Separate galleries and blob stores keep temporary originals out of permanent
/// search, storage caps, output folders and backup. An OS lock survives until
/// the owning process exits, including while another Plana instance starts.
class TemporaryGallery extends ChangeNotifier {
  TemporaryGallery(Directory support, this.permanent)
    : root = directoryIn(support) {
    permanent.temporarySource = sourceFor;
  }
  static Directory directoryIn(Directory support) =>
      Directory(p.join(support.path, 'temporary-gallery'));
  final Directory root;
  final GalleryStore permanent;
  final _sessions = <_Session>[];
  final _byId = <String, _Bucket>{};
  final _selected = <String, String>{};
  static final _processLeases = <String>{};
  final _random = Random.secure();
  _Session? _current;
  Future<void>? _opening;
  Future<void> _tail = Future.value();
  bool used = false;
  bool closing = false;
  final visitedCanvases = <String>{};
  final _activities = <String, int>{};
  bool hasActivity(String? canvas) =>
      canvas == null ? _activities.isNotEmpty : _activities.containsKey(canvas);
  VoidCallback holdCanvas(String? canvas) {
    if (canvas == null) return () {};
    _activities.update(canvas, (n) => n + 1, ifAbsent: () => 1);
    return () {
      final n = _activities[canvas]!;
      if (n == 1) {
        _activities.remove(canvas);
      } else {
        _activities[canvas] = n - 1;
      }
    };
  }

  VoidCallback holdImage(String id) => holdCanvas(_byId[id]?.canvas);
  Set<String> snapshot(Set<String> groups) => {
    for (final c in groups)
      for (final r in images(c)) '${r.id}/${isPromoted(r.id)}',
  };
  int pendingDeletion(int keep, {String? canvas}) =>
      (canvas == null ? canvases : {canvas}).fold(
        0,
        (n, c) =>
            n + max(0, images(c).where((r) => !isPromoted(r.id)).length - keep),
      );
  List<ResultImage> recoveredImages(String canvas) => [
    for (final b in _buckets.where((b) => b.canvas == canvas && b.recovered))
      ...b.images,
  ];
  Future<T> withFiles<T>(Future<T> Function() action) => _queue(action);
  Future<void> get idle => _tail;
  Iterable<_Bucket> get _buckets => _sessions.expand((s) => s.buckets);
  Set<String> get canvases => {
    for (final b in _buckets)
      if (b.images.isNotEmpty) b.canvas,
  };
  Set<String> get recoveredCanvases => {
    for (final b in _buckets)
      if (b.recovered && b.images.isNotEmpty) b.canvas,
  };
  String nameOf(String canvas) =>
      _buckets.where((b) => b.canvas == canvas).lastOrNull?.name ?? canvas;
  bool contains(String id) => _byId.containsKey(id);
  ResultImage? find(String? id) =>
      _byId[id]?.images.where((r) => r.id == id).firstOrNull;
  bool isFiled(String id) => _byId[id]?.filed.contains(id) ?? false;
  bool isPromoted(String id) => _byId[id]?.promoted.contains(id) ?? false;
  GalleryStore? sourceFor(String id) {
    final b = _byId[id];
    return b != null && !b.promoted.contains(id) ? b.files : null;
  }

  List<ResultImage> images(String canvas) {
    final buckets = _buckets.where((b) => b.canvas == canvas);
    if (buckets.length == 1) return buckets.first.images;
    return [for (final b in buckets) ...b.images]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  String? selected(String canvas) => _selected[canvas];
  void select(String id) {
    final b = _byId[id];
    if (b != null && _selected[b.canvas] != id) {
      _selected[b.canvas] = id;
      notifyListeners();
    }
  }

  Future<void> checkExportDirectory(String path) async {
    final directory = Directory(path);
    if (!await root.exists() || !await directory.exists()) return;
    final managed = p.normalize(await root.resolveSymbolicLinks());
    final chosen = p.normalize(await directory.resolveSymbolicLinks());
    if (p.equals(managed, chosen) || p.isWithin(managed, chosen)) {
      throw StateError('请选择临时图库以外的保存位置');
    }
  }

  String newId() =>
      'temp_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}_${_random.nextInt(1 << 32)}';
  Future<T> _queue<T>(Future<T> Function() action) {
    final work = _tail.then((_) => action());
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> open({String? canvas, bool markUsed = true}) async {
    if (markUsed) used = true;
    await (_opening ??= _load().catchError((Object error) {
      _opening = null;
      throw error;
    }));
    if (canvas != null && visitedCanvases.add(canvas)) {
      for (final b in _buckets.where((b) => b.canvas == canvas).toList()) {
        if (await b.retained.exists()) await b.retained.delete();
      }
    }
  }

  Future<_Session?> _claim(Directory d) async {
    final key = p.normalize(d.absolute.path);
    if (!_processLeases.add(key)) return null;
    RandomAccessFile? file;
    try {
      file = await File(
        p.join(d.path, 'owner.lock'),
      ).open(mode: FileMode.append);
      await file.lock(FileLock.exclusive);
      return _Session(d, file);
    } on FileSystemException {
      await file?.close();
      _processLeases.remove(key);
      return null;
    }
  }

  Future<void> _load() async {
    await root.create(recursive: true);
    final permanentEntries = {
      for (final r in permanent.initialResults) r.id: r,
      for (final t in permanent.initialTrash) t.image.id: t.image,
    };
    try {
      await for (final dir in root.list(followLinks: false)) {
        if (dir is! Directory || !p.basename(dir.path).startsWith('session-')) {
          continue;
        }
        if (!await File(p.join(dir.path, 'ready')).exists()) continue;
        final s = await _claim(dir);
        if (s == null) continue;
        _sessions.add(s);
        await recoverPendingWrites(dir);
        await for (final group in dir.list(followLinks: false)) {
          if (group is! Directory ||
              !p.basename(group.path).startsWith('canvas-')) {
            continue;
          }
          final meta = File(p.join(group.path, 'canvas.json'));
          if (!await meta.exists()) continue;
          final json = jsonDecode(await meta.readAsString()) as Map;
          final b = _Bucket(
            group,
            json['canvas'] as String,
            json['name'] as String,
          );
          b.promoted.addAll(
            (json['promoted'] as List? ?? []).whereType<String>(),
          );
          b.filed.addAll((json['filed'] as List? ?? []).whereType<String>());
          await b.files.load();
          b.images = [...b.files.initialResults];
          await _reconcile(b, permanentEntries);
          b.recovered = !await b.retained.exists();
          s.buckets.add(b);
          for (final image in b.images) {
            _byId[image.id] = b;
          }
        }
      }
      notifyListeners();
    } catch (_) {
      await _release();
      rethrow;
    }
  }

  /// A crash can occur between writing the permanent record, recording its
  /// membership here and removing its temporary original.
  Future<void> _reconcile(_Bucket b, Map<String, ResultImage> entries) async {
    var changed = false;
    final duplicates = <String>[];
    final images = <ResultImage>[];
    for (final image in b.images) {
      final id = image.id;
      final record = entries[id];
      if (record == null && !b.promoted.contains(id)) {
        images.add(image);
        continue;
      }
      final local = await b.files.imageFileForPreview(id).exists();
      if (await permanent.imageFileForPreview(id).exists()) {
        changed = b.promoted.add(id) || changed;
        final merged = record == null
            ? image
            : record.withSaved(record.saved || image.saved);
        changed =
            changed ||
            image.favorite != merged.favorite ||
            image.saved != merged.saved;
        images.add(merged);
        if (record != null && local) duplicates.add(id);
      } else {
        changed = true;
        b.promoted.remove(id);
        b.filed.remove(id);
        if (local) images.add(image.withFavorite(false));
      }
    }
    b.images = images;
    if (changed) {
      await b.saveMetadata();
      await b.saveIndex();
    }
    if (duplicates.isNotEmpty) {
      await b.files.deleteResultFilesVerified(duplicates);
      await b.blobs.gc(
        await b.files.liveRefs(strict: true),
        minAge: Duration.zero,
      );
    }
  }

  Future<_Bucket> _bucket(String canvas, String name) async {
    final session = _current ??= (await _claim(
      await root.createTemp('session-'),
    ))!;
    if (!_sessions.contains(session)) {
      _sessions.add(session);
      await File(
        p.join(session.root.path, 'ready'),
      ).writeAsString('1', flush: true);
    }
    final existing = session.buckets
        .where((b) => b.canvas == canvas)
        .firstOrNull;
    if (existing != null) {
      if (existing.name != name) {
        existing.name = name;
        await existing.saveMetadata();
      }
      return existing;
    }
    final dir = await session.root.createTemp('canvas-');
    final b = _Bucket(dir, canvas, name);
    await b.saveMetadata();
    session.buckets.add(b);
    return b;
  }

  Future<void> add(
    String canvas,
    String name,
    ResultImage image, {
    required bool Function() selectResult,
  }) => _queue(() async {
    await open(canvas: canvas);
    final previous = _byId[image.id];
    if (previous != null && previous.canvas != canvas) {
      throw StateError('待保存的图片属于另一张画布');
    }
    final b = previous ?? await _bucket(canvas, name);
    if (previous == null) {
      await b.files.persistResult(image);
      b.images = [image.stripped(), ...b.images];
      _byId[image.id] = b;
    }
    await b.saveIndex();
    if (selectResult()) _selected[canvas] = image.id;
    notifyListeners();
  });

  /// Commit the permanent record before unlinking local bytes. Keep its small
  /// filmstrip entry so exports still cover the whole canvas session.
  Future<void> change(
    String id, {
    bool exported = false,
    bool filed = false,
    bool Function()? canReleaseFavorite,
    Future<bool> Function()? releaseFavorite,
    required bool retain,
    required Future<ResultImage> Function(ResultImage) commit,
  }) => _queue(() async {
    final b = _byId[id];
    if (b == null) return;
    final entry = b.images.firstWhere((r) => r.id == id);
    var next = exported ? entry.markSaved() : entry;
    if (releaseFavorite != null &&
        b.promoted.contains(id) &&
        !b.filed.contains(id) &&
        canReleaseFavorite?.call() == true) {
      // First restore a local copy, then revoke the last permanent membership.
      // A failed or interrupted write always leaves at least one original.
      final bytes = await permanent.readImage(id);
      final input = entry.hasInput ? await permanent.readInput(id) : null;
      if (bytes == null || (entry.hasInput && input == null)) {
        throw StateError('无法读取已收藏的图片');
      }
      await b.files.persistResult(entry.withContent(bytes, input));
      if (await releaseFavorite()) {
        next = next.withFavorite(false);
        b.promoted.remove(id);
        await b.saveMetadata();
        b.images = [
          for (final r in b.images)
            if (r.id == id) next.stripped() else r,
        ];
        await b.saveIndex();
        notifyListeners();
        return;
      }
    }
    if (retain) {
      final retained = await commit(next);
      next = retained;
      if (entry.saved || exported) next = next.markSaved();
      b.promoted.add(id);
      if (filed) b.filed.add(id);
      await b.saveMetadata();
      final removed = await b.files.deleteResultFilesVerified([id]);
      if (!removed.contains(id)) throw FileSystemException('临时副本待清理');
      await b.blobs.gc(
        await b.files.liveRefs(strict: true),
        minAge: Duration.zero,
      );
    }
    b.images = [
      for (final r in b.images)
        if (r.id == id) next.stripped() else r,
    ];
    await b.saveIndex();
    notifyListeners();
  });

  Future<void> _remove(_Bucket b, Set<String> ids) async {
    if (ids.isEmpty) return;
    final removed = await b.files.deleteResultFilesVerified(ids.toList());
    if (!removed.containsAll(ids)) throw FileSystemException('临时图库清理未完成');
    b.images = b.images.where((r) => !ids.contains(r.id)).toList();
    b.promoted.removeAll(ids);
    b.filed.removeAll(ids);
    for (final id in ids) {
      _byId.remove(id);
      if (_selected[b.canvas] == id) _selected.remove(b.canvas);
    }
    await b.saveIndex();
    await b.saveMetadata();
    await b.blobs.gc(
      await b.files.liveRefs(strict: true),
      minAge: Duration.zero,
    );
  }

  /// Permanent removal must also retire filmstrip links to those originals.
  Future<Set<String>> deletePermanent(Future<Set<String>> Function() delete) =>
      _queue(() async {
        final deleted = await delete();
        for (final bucket in _buckets) {
          final stale = bucket.promoted.intersection(deleted);
          if (stale.isNotEmpty) await _remove(bucket, stale);
        }
        if (deleted.isNotEmpty) notifyListeners();
        return deleted;
      });

  Future<void> remove(String id) => _queue(() async {
    final b = _byId[id];
    if (b != null) {
      await _remove(b, {id});
      notifyListeners();
    }
  });

  /// Clean only directories for which this instance holds a live lease.
  /// A failed export calls neither this method nor the exit commit.
  Future<void> finish({
    required int keep,
    String? canvas,
    bool recoveredOnly = false,
    bool exit = false,
    Set<String>? onlyCanvases,
    Set<String>? expected,
  }) => _queue(() async {
    final currentGroups = exit && onlyCanvases != null
        ? canvases.intersection(visitedCanvases)
        : onlyCanvases ?? (canvas == null ? canvases : {canvas});
    if (expected != null &&
        (!setEquals(expected, snapshot(currentGroups)) ||
            hasActivity(canvas))) {
      throw StateError('图库内容或正在执行的操作已变化，请重新确认');
    }
    if (_opening != null) await _opening;
    final targets = _buckets
        .where(
          (b) =>
              (canvas == null || b.canvas == canvas) &&
              (onlyCanvases == null || onlyCanvases.contains(b.canvas)) &&
              (!recoveredOnly || b.recovered),
        )
        .toList();
    final keepIds = <String>{};
    for (final key in targets.map((b) => b.canvas).toSet()) {
      final candidates = [
        for (final b in targets.where((b) => b.canvas == key))
          for (final r in b.images)
            if (!b.promoted.contains(r.id)) r,
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      keepIds.addAll(candidates.take(keep).map((r) => r.id));
    }
    for (final b in targets) {
      await _remove(b, {
        for (final r in b.images)
          if (!keepIds.contains(r.id)) r.id,
      });
      b.recovered = false;
      if (b.images.isEmpty) {
        final session = _sessions.firstWhere((s) => s.buckets.contains(b));
        if (!p.equals(p.dirname(b.directory.path), session.root.path)) {
          throw StateError('无效临时目录');
        }
        await b.files.idle;
        await b.directory.delete(recursive: true);
        session.buckets.remove(b);
      } else if (exit) {
        await b.retained.writeAsString('1', flush: true);
      }
    }
    if (exit) {
      for (final s in _sessions) {
        if (s.buckets.isEmpty) {
          final ready = File(p.join(s.root.path, 'ready'));
          if (await ready.exists()) await ready.delete();
        }
      }
      await _release(pruneEmpty: true);
    }
    notifyListeners();
  });

  Future<void> _release({bool pruneEmpty = false}) async {
    for (final s in _sessions) {
      await s.lease.close();
      _processLeases.remove(p.normalize(s.root.absolute.path));
      if (pruneEmpty && s.buckets.isEmpty) {
        try {
          for (final f in [File(p.join(s.root.path, 'owner.lock'))]) {
            if (await f.exists()) await f.delete();
          }
          await s.root.delete();
        } on FileSystemException {
          /* Empty lease directories may still be open. */
        }
      }
    }
    _sessions.clear();
    _byId.clear();
    _selected.clear();
    _current = null;
    _opening = null;
    visitedCanvases.clear();
    used = false;
  }

  /// Release a lease without committing an exit (also used by recovery tests).
  Future<void> abandon() async {
    await idle;
    await _release();
  }
}
