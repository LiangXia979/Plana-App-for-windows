import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';
import 'save_settings.dart';
import 'temporary_gallery.dart';
import 'zip_pipeline.dart';

/// Each archive is fully staged on its destination volume before publishing.
/// Export has no side effects on album membership or temporary retention.
Future<List<File>> exportTemporaryArchives(
  TemporaryGallery gallery,
  Directory directory,
  SaveSettings settings, {
  Iterable<String>? canvases,
  bool recoveredOnly = false,
  Set<String>? imageIds,
  Map<String, String> names = const {},
  DateTime? time,
  bool Function(int done, int total)? onProgress,
}) => gallery.withFiles(() async {
  if (!await directory.exists()) {
    throw FileSystemException('单独保存文件夹不存在', directory.path);
  }
  await gallery.checkExportDirectory(directory.path);
  final groups = <String, List<ResultImage>>{};
  for (final c in canvases ?? gallery.canvases) {
    final items = recoveredOnly
        ? gallery.recoveredImages(c)
        : gallery.images(c);
    final included = imageIds == null
        ? List.of(items)
        : items.where((r) => imageIds.contains(r.id)).toList();
    if (included.isNotEmpty) groups[c] = included;
  }
  if (groups.isEmpty) return <File>[];
  final total = groups.values.fold<int>(0, (n, items) => n + items.length);
  var completed = 0;
  bool cancelled = false;
  if (onProgress?.call(0, total) == false) return <File>[];
  final now = time ?? DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final staging = await directory.createTemp('.plana-zip-');
  final pending = <({String stem, File file})>[];
  try {
    for (final entry in groups.entries) {
      var name = sanitizeZipName(
        names[entry.key] ?? gallery.nameOf(entry.key),
      ).replaceAll(RegExp(r'[\x00-\x1f]'), '');
      name = String.fromCharCodes(name.runes.take(70));
      if (RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
        name = '_$name';
      }
      if (name.isEmpty) name = '画布';
      final archive = await packImagesZip(
        entry.value,
        store: gallery.permanent,
        settings: settings,
        stagingDirectory: staging,
        onEach: (n) {
          cancelled = onProgress?.call(completed + n, total) == false;
          return !cancelled;
        },
        fileName: '${pending.length}.zip',
      );
      if (cancelled) return <File>[];
      completed += entry.value.length;
      if (archive.file == null ||
          archive.failed != 0 ||
          archive.packed != entry.value.length) {
        throw FileSystemException('画布「$name」打包未完成，临时图片已保留');
      }
      final suffix = imageIds == null ? '' : '_精选';
      pending.add((stem: '$name${suffix}_$stamp', file: archive.file!));
    }
    if (onProgress?.call(completed, total) == false) return <File>[];
    final output = <File>[];
    for (final item in pending) {
      for (var serial = 1; ; serial++) {
        final suffix = serial == 1 ? '' : '_$serial';
        final dest = File(p.join(directory.path, '${item.stem}$suffix.zip'));
        if (await dest.exists()) continue;
        // Serialize name allocation across simultaneous Plana instances.
        final lock = File('${dest.path}.part');
        try {
          await lock.create(exclusive: true);
        } on FileSystemException {
          if (await lock.exists()) continue;
          rethrow;
        }
        try {
          if (await dest.exists()) continue;
          output.add(await item.file.rename(dest.path));
          break;
        } finally {
          await lock.delete();
        }
      }
    }
    return output;
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
});
