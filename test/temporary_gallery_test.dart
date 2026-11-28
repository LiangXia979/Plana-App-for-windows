import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/albums/album_state.dart';
import 'package:plana_app/features/gallery/gallery_state.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/save_settings.dart';
import 'package:plana_app/features/gallery/temporary_gallery_export.dart';
import 'package:plana_app/features/gallery/temporary_gallery_state.dart';
import 'package:plana_app/features/generate/canvas_state.dart';
import 'package:plana_app/features/generate/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = Uint8List.fromList(img.encodePng(img.Image(width: 3, height: 2)));
  late Directory root;
  late AppStores stores;
  late ProviderContainer c;
  late GalleryNotifier gallery;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plana-temp-gallery-test-');
    stores = await AppStores.open(rootOverride: root);
    c = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
      ],
    );
    gallery = c.read(galleryProvider.notifier);
  });
  tearDown(() async {
    await stores.temporaryGallery.abandon();
    await stores.flushForExit();
    c.dispose();
    await root.delete(recursive: true);
  });
  Future<ResultImage> generate(GallerySaveTarget target, int seed) =>
      gallery.addResultToGallery(
        bytes: png,
        width: 3,
        height: 2,
        seed: seed,
        target: target,
        input: GenerateState.initial().copyWith(prompt: 'cat $seed'),
      );
  const a = GallerySaveTarget.temporary('canvas1', '画布甲');
  const b = GallerySaveTarget.temporary('canvas2', '画布乙');
  test(
    'submitted destinations follow the originating canvas, with disk-backed originals and parameters',
    () async {
      final options = c.read(temporaryOptionsProvider.notifier);
      final canvases = c.read(canvasWorkspaceProvider.notifier);
      final first = c.read(canvasWorkspaceProvider).activeId;
      expect(c.read(gallerySaveTargetProvider).canvasId, isNull);
      options.choose(first, true);
      final queued = c.read(gallerySaveTargetProvider);
      canvases.create();
      expect(c.read(gallerySaveTargetProvider).canvasId, isNull);
      final standard = await generate(c.read(gallerySaveTargetProvider), 91);
      final image = await generate(queued, 11);
      expect(
        c
            .read(creationGalleryFor(c.read(temporaryCanvasProvider)))
            .results
            .single
            .id,
        standard.id,
      );
      expect(stores.temporaryGallery.images(first).single.bytes, isNull);
      expect(stores.temporaryGallery.images(first).single.input, isNull);
      expect(await stores.gallery.readImage(image.id), isNotNull);
      expect((await stores.gallery.readInput(image.id))!.prompt, 'cat 11');
      expect(await stores.gallery.readThumb(image.id), isNotEmpty);
      expect(
        File(
          p.join(root.path, 'gallery', 'images', '${image.id}.png'),
        ).existsSync(),
        isFalse,
      );
      canvases.select(first);
      expect(
        c
            .read(creationGalleryFor(c.read(temporaryCanvasProvider)))
            .results
            .single
            .id,
        image.id,
      );
      expect(c.read(galleryProvider).results.map((r) => r.id), [standard.id]);
    },
  );

  test(
    'single save and favorite share one permanent record; ZIP and download-only do not collect',
    () async {
      final image = await generate(a, 1);
      final exportedOnly = await generate(a, 2);
      final favoriteOnly = await generate(a, 3);
      final albumEntry = await generate(a, 4);
      final temp = stores.temporaryGallery;
      await Future.wait([
        gallery.markSaved([image.id]),
        gallery.retainTemporary(image.id, favorite: true),
      ]);
      final permanent = c.read(galleryProvider).results.single;
      expect(permanent.saved && permanent.favorite, isTrue);
      expect(temp.sourceFor(image.id), isNull);
      final originals = root
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (f) =>
                p.basename(f.path) == '${image.id}.png' &&
                p.basename(p.dirname(f.path)) == 'images',
          );
      expect(originals.length, 1);
      c.read(temporaryOptionsProvider.notifier).update(collectSaved: false);
      await gallery.markSaved([exportedOnly.id, favoriteOnly.id]);
      await gallery.retainTemporary(favoriteOnly.id, favorite: true);
      final dest = await c.read(albumsProvider.notifier).create('留下');
      await gallery.retainTemporary(
        albumEntry.id,
        destination: GallerySaveTarget.album(dest),
      );
      expect(c.read(albumsProvider).contains(dest, albumEntry.id), isTrue);
      expect(
        c.read(galleryProvider).results.where((r) => r.saved).map((r) => r.id),
        [image.id],
      );
      expect(temp.images('canvas1').length, 4);
      expect(
        temp.images('canvas1').firstWhere((r) => r.id == exportedOnly.id).saved,
        isTrue,
      );
      expect(temp.pendingDeletion(0), 1);
      await temp.finish(keep: 0, exit: true);
      expect(await stores.gallery.readImage(exportedOnly.id), isNull);
      for (final r in [image, favoriteOnly, albumEntry]) {
        expect(await stores.gallery.readImage(r.id), isNotEmpty);
      }
    },
  );

  test(
    'archives include every image, preserve gallery state and use unique canvas filenames',
    () async {
      final images = [
        await generate(a, 1),
        await generate(a, 1),
        await generate(b, 3),
      ];
      final temp = stores.temporaryGallery;
      await gallery.retainTemporary(images.first.id, favorite: true);
      final folder = await root.createTemp('downloads-');
      final now = DateTime(2026, 11, 28, 2, 34, 15);
      final files = await exportTemporaryArchives(
        temp,
        folder,
        const SaveSettings(),
        time: now,
      );
      expect(
        files.map((f) => p.basename(f.path)),
        containsAll(['画布甲_20261128_023415.zip', '画布乙_20261128_023415.zip']),
      );
      final archive = ZipDecoder().decodeBytes(
        await files.first.readAsBytes(),
        verify: true,
      );
      expect(
        archive.files.map((e) => e.name),
        containsAll(['plana_1.png', 'plana_1_2.png']),
      );
      expect(archive.files.every((e) => e.size > 0), isTrue);
      final subset = await exportTemporaryArchives(
        temp,
        folder,
        const SaveSettings(),
        canvases: ['canvas1'],
        imageIds: {images[1].id, images[2].id},
        time: now,
      );
      expect(p.basename(subset.single.path), contains('画布甲_精选_'));
      expect(
        ZipDecoder()
            .decodeBytes(await subset.single.readAsBytes(), verify: true)
            .files
            .single
            .name,
        'plana_1.png',
      );
      expect(temp.isPromoted(images[1].id), isFalse);
      final again = await exportTemporaryArchives(
        temp,
        folder,
        const SaveSettings(),
        canvases: ['canvas1'],
        time: now,
      );
      expect(p.basename(again.single.path), '画布甲_20261128_023415_2.zip');
      expect(temp.images('canvas1').length, 2);
      expect(c.read(galleryProvider).results.any((r) => r.saved), isFalse);
      expect(temp.pendingDeletion(0), 2);
      final broken = temp
          .sourceFor(images.last.id)!
          .imageFileForPreview(images.last.id);
      final bytes = await broken.readAsBytes();
      await broken.delete();
      await expectLater(
        exportTemporaryArchives(temp, folder, const SaveSettings(), time: now),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        folder.listSync().whereType<File>().length,
        files.length + subset.length + again.length,
      );
      expect(temp.images('canvas2').length, 1);
      await broken.writeAsBytes(bytes);
    },
  );

  test(
    'cancelled multi-canvas ZIP leaves every image and publishes no partial archive',
    () async {
      await generate(a, 1);
      await generate(b, 2);
      final folder = await root.createTemp('cancel-');
      final temp = stores.temporaryGallery;
      final result = await exportTemporaryArchives(
        temp,
        folder,
        const SaveSettings(),
        onProgress: (done, _) => done < 2,
      );
      expect(result, isEmpty);
      expect(folder.listSync(), isEmpty);
      expect(temp.pendingDeletion(0), 2);
    },
  );
  test(
    'removing a temporary favorite releases it unless another permanent membership exists',
    () async {
      final image = await generate(a, 1);
      await gallery.retainTemporary(image.id, favorite: true);
      await gallery.retainTemporary(image.id, favorite: false);
      expect(c.read(galleryProvider).results, isEmpty);
      expect(stores.temporaryGallery.pendingDeletion(0), 1);
      expect(await stores.gallery.readImage(image.id), isNotEmpty);
      await gallery.markSaved([image.id]);
      await gallery.retainTemporary(image.id, favorite: true);
      await gallery.retainTemporary(image.id, favorite: false);
      expect(c.read(galleryProvider).results.single.saved, isTrue);
      expect(stores.temporaryGallery.pendingDeletion(0), 0);
    },
  );
  test(
    'restoring a temporary image from trash and purging it leave no orphan filmstrip entry',
    () async {
      final image = await generate(a, 1);
      await gallery.retainTemporary(image.id, favorite: true);
      await gallery.deleteResults([image.id]);
      expect(c.read(galleryProvider).trash.single.image.id, image.id);
      await gallery.markSaved([image.id]);
      expect(c.read(galleryProvider).trash, isEmpty);
      expect(c.read(galleryProvider).results.single.saved, isTrue);
      await gallery.deleteResults([image.id]);
      expect(await gallery.purgeTrash([image.id]), {image.id});
      expect(stores.temporaryGallery.images('canvas1'), isEmpty);
      expect(await stores.gallery.readImage(image.id), isNull);
    },
  );

  test(
    'queued retry keeps one original, and exit cannot clean a newly active canvas outside its snapshot',
    () async {
      final image = await generate(a, 1);
      final temp = stores.temporaryGallery;
      await gallery.addResultToGallery(
        bytes: png,
        width: 3,
        height: 2,
        seed: 1,
        target: a,
        retryResult: image,
      );
      expect(temp.images('canvas1').single.id, image.id);
      final first = {'canvas1'};
      final before = temp.snapshot(first);
      await expectLater(
        temp.checkExportDirectory(temp.root.path),
        throwsStateError,
      );
      final raw = temp.sourceFor(image.id)!.imageFileForPreview(image.id);
      await expectLater(
        temp.checkExportDirectory(raw.parent.path),
        throwsStateError,
      );
      await temp.checkExportDirectory(root.path);
      await generate(b, 2);
      await expectLater(
        temp.finish(keep: 0, exit: true, onlyCanvases: first, expected: before),
        throwsStateError,
      );
      expect(temp.pendingDeletion(0), 2);
    },
  );

  test(
    'clean exit retains the newest N uncollected images separately for each canvas',
    () async {
      final older = await generate(a, 1);
      final newer = await generate(a, 2);
      final retained = await generate(a, 3);
      final other = await generate(b, 4);
      await gallery.markSaved([retained.id]);
      expect(stores.temporaryGallery.pendingDeletion(1), 1);
      await stores.temporaryGallery.finish(keep: 1, exit: true);
      final next = await AppStores.open(rootOverride: root);
      await next.temporaryGallery.open();
      try {
        expect(next.temporaryGallery.recoveredCanvases, isEmpty);
        expect(next.temporaryGallery.images('canvas1').map((r) => r.id), [
          newer.id,
        ]);
        expect(next.temporaryGallery.images('canvas2').single.id, other.id);
        expect(await next.gallery.readImage(older.id), isNull);
        expect(await next.gallery.readImage(retained.id), isNotEmpty);
        await next.temporaryGallery.finish(keep: 0, canvas: 'canvas1');
        expect(next.temporaryGallery.images('canvas2').single.id, other.id);
      } finally {
        await next.temporaryGallery.abandon();
        await next.flushForExit();
      }
    },
  );

  test(
    'crash recovery skips live owners, and clearing recovered canvases preserves this session',
    () async {
      final old = await generate(a, 1);
      final second = await AppStores.open(rootOverride: root);
      final other = second.temporaryGallery;
      await other.open();
      try {
        expect(other.canvases, isEmpty);
        final own = ResultImage(
          id: other.newId(),
          width: 3,
          height: 2,
          seed: 3,
          bytes: png,
        );
        await other.add('canvas1', '另一窗口', own, selectResult: () => true);
        await stores.temporaryGallery.abandon();
        final third = await AppStores.open(rootOverride: root);
        final recovery = third.temporaryGallery;
        await recovery.open();
        try {
          expect(recovery.recoveredImages('canvas1').single.id, old.id);
          expect(recovery.contains(own.id), isFalse);
          final fresh = ResultImage(
            id: recovery.newId(),
            width: 3,
            height: 2,
            seed: 9,
            bytes: png,
          );
          await recovery.add('canvas1', '新会话', fresh, selectResult: () => true);
          await recovery.finish(keep: 0, recoveredOnly: true);
          expect(recovery.images('canvas1').single.id, fresh.id);
          await recovery.finish(keep: 0, exit: true);
          expect(await other.permanent.readImage(own.id), png);
        } finally {
          await recovery.abandon();
          await third.flushForExit();
        }
      } finally {
        await other.abandon();
        await second.flushForExit();
      }
    },
  );

  test(
    'a separate Windows process with a live session lease cannot be recovered or swept',
    () async {
      final image = await generate(a, 7);
      final owner = stores.temporaryGallery;
      final lock = owner.root
          .listSync(recursive: true)
          .whereType<File>()
          .singleWhere((f) => p.basename(f.path) == 'owner.lock');
      await owner.abandon();
      final ready = File(p.join(root.path, 'test-ready'));
      final release = File(p.join(root.path, 'test-release'));
      final child = await Process.start(
        'powershell.exe',
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          r"$f=[IO.File]::Open($env:PLANA_TEST_GALLERY_LEASE,'Open','ReadWrite','ReadWrite'); try { $f.Lock(0,1); [IO.File]::WriteAllText($env:PLANA_TEST_READY,'yes'); for($i=0; $i -lt 300 -and -not [IO.File]::Exists($env:PLANA_TEST_RELEASE); $i++){Start-Sleep -Milliseconds 100} } finally { $f.Dispose() }",
        ],
        environment: {
          'PLANA_TEST_GALLERY_LEASE': lock.path,
          'PLANA_TEST_READY': ready.path,
          'PLANA_TEST_RELEASE': release.path,
        },
      );
      try {
        final clock = Stopwatch()..start();
        while (!await ready.exists() &&
            clock.elapsed < const Duration(seconds: 12)) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(await ready.exists(), isTrue);
        await owner.open();
        expect(owner.canvases, isEmpty);
        await owner.finish(keep: 0, exit: true);
      } finally {
        await release.writeAsString('done', flush: true);
        expect(
          await child.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              child.kill();
              return -1;
            },
          ),
          0,
        );
      }
      await owner.open();
      expect(owner.images('canvas1').single.id, image.id);
      expect(await owner.permanent.readImage(image.id), isNotEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'initial loading limits history on entry, appends new images, and permits loading earlier ones',
    () {
      final history = InitialHistoryWindow();
      List<ResultImage> rows(List<int> ids) => [
        for (final id in ids)
          ResultImage(id: '$id', width: 1, height: 1, seed: id),
      ];
      List<String> visible(String scope, int limit, List<int> ids) =>
          history.visible(scope, limit, rows(ids)).map((r) => r.id).toList();
      expect(visible('a', 2, [5, 4, 3, 2, 1]), ['5', '4']);
      expect(visible('a', 2, [7, 6, 5, 4, 3, 2, 1]), ['7', '6', '5', '4']);
      history.more(rows([7, 6, 5, 4, 3, 2, 1]));
      expect(visible('a', 2, [7, 6, 5, 4, 3, 2, 1]), [
        '7',
        '6',
        '5',
        '4',
        '3',
        '2',
      ]);
      expect(visible('b', 2, [3, 2, 1]), ['3', '2']);
      expect(visible('a', 2, [7, 6, 5, 4, 3, 2, 1]), ['7', '6']);
      expect(visible('a', 0, [7, 6, 5]), ['7', '6', '5']);
    },
  );
}
