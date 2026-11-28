import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/platform/windows_semantics.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/gallery/albums/album_models.dart';
import 'package:plana_app/features/gallery/models.dart';
import 'package:plana_app/features/gallery/temporary_gallery_state.dart';
import 'package:plana_app/features/gallery/widgets/film_strip.dart';
import 'package:plana_app/features/generate/widgets/anlas_panel.dart';
import 'package:plana_app/main.dart';

// Verify the traversal tree actually sent to the desktop engine. Widget
// finders alone cannot see disconnected nodes in an incremental update.
class _TraversalBinding extends AutomatedTestWidgetsFlutterBinding {
  final children = <int, List<int>>{};
  final errors = <String>[];
  String phase = 'startup';

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _TraversalBuilder(super.createSemanticsUpdateBuilder(), this);

  void check(Map<int, List<int>> batch) {
    if (batch.isEmpty) return;
    children.addAll(batch);
    final reachable = <int>{};
    final todo = [0];
    while (todo.isNotEmpty) {
      final id = todo.removeLast();
      final descendants = children[id];
      if (descendants == null) {
        errors.add('$phase: parent references missing node $id');
        continue;
      }
      if (!reachable.add(id)) {
        errors.add('$phase: node $id has multiple parents or a cycle');
        continue;
      }
      todo.addAll(descendants);
    }
    final detached = batch.keys.where((id) => !reachable.contains(id));
    if (detached.isNotEmpty) errors.add('$phase: detached updates $detached');
    children.removeWhere((id, _) => !reachable.contains(id));
  }
}

class _WindowsTraversalBinding extends _TraversalBinding
    with WindowsSemanticsBinding {}

class _TraversalBuilder implements ui.SemanticsUpdateBuilder {
  _TraversalBuilder(this.delegate, this.binding);
  final ui.SemanticsUpdateBuilder delegate;
  final _TraversalBinding binding;
  final _batch = <int, List<int>>{};

  // Forward all SDK metadata untouched while observing only traversal edges.
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName != #updateNode) return super.noSuchMethod(call);
    final args = call.namedArguments;
    _batch[args[#id] as int] = args[#childrenInTraversalOrder] as List<int>;
    return Function.apply(delegate.updateNode, call.positionalArguments, args);
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => delegate.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  ui.SemanticsUpdate build() {
    binding.check(_batch);
    return delegate.build();
  }
}

void main() {
  final binding = _WindowsTraversalBinding();
  testWidgets('a portal is readable again when its traversal parent returns', (
    tester,
  ) async {
    final parentIdentifier = Object();
    const parentKey = ValueKey('traversal-parent');
    const childKey = ValueKey('traversal-child');
    Future<void> frame(bool hasParent, String label) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            if (hasParent)
              Semantics(
                key: parentKey,
                container: true,
                traversalParentIdentifier: parentIdentifier,
                child: const SizedBox.square(dimension: 30),
              ),
            Semantics(
              key: childKey,
              container: true,
              label: label,
              traversalChildIdentifier: parentIdentifier,
              child: const SizedBox.square(dimension: 30),
            ),
          ],
        ),
      ),
    );

    binding.children.clear();
    binding.errors.clear();
    await frame(false, '等待');
    final child = tester.getSemantics(find.byKey(childKey)).id;
    expect(binding.errors, isEmpty);
    expect(binding.children, isNot(contains(child)));
    await frame(false, '刷新');
    await frame(true, '刷新');
    final parent = tester.getSemantics(find.byKey(parentKey)).id;
    expect(binding.children[parent], contains(child));
    await frame(false, '刷新');
    expect(binding.children, isNot(contains(child)));
    await frame(true, '刷新');
    expect(
      binding.children[tester.getSemantics(find.byKey(parentKey)).id],
      contains(child),
    );
    expect(binding.errors, isEmpty);
  });
  for (final (total, history) in [(504, 7), (1500, 1500)]) {
    testWidgets(
      'gallery to creation keeps Windows traversal connected ($total images)',
      (tester) async {
        binding.children.clear();
        binding.errors.clear();
        binding.phase = 'mount';
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final stores = AppStores.ephemeral();
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
        );
        final photos = [
          for (var i = 0; i < total; i++)
            ResultImage(
              id: 'image-$i',
              width: 1024,
              height: 1024,
              seed: i,
              bytes: png,
            ),
        ];
        stores.gallery.initialResults = photos;
        stores.gallery.initialSelectedId = photos.first.id;
        stores.albums.data = AlbumsData(
          albums: [const GalleryAlbum(id: 'work', name: '测试图库', createdAt: 0)],
          memberships: {
            for (final photo in photos.take(history)) photo.id: {'work'},
          },
        );
        await tester.runAsync(
          () =>
              stores.prefs.write(key: 'desktop_gallery_choice', value: 'work'),
        );
        final container = ProviderContainer(
          overrides: [
            appStoresProvider.overrideWithValue(stores),
            desktopModeProvider.overrideWithValue(true),
          ],
        );
        // Keep all fixture images in the strip while exercising Windows traversal.
        container
            .read(temporaryOptionsProvider.notifier)
            .update(initialHistory: 0);
        container
            .read(themeSettingsProvider.notifier)
            .patch(
              (settings) =>
                  settings.copyWith(showAssistant: false, showTools: false),
            );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const PlanaApp(),
            ),
          );
          await tester.pumpAndSettle();
          final popover = find.byKey(const ValueKey('desktop-popover'));
          for (var i = 0; i < 3; i++) {
            binding.phase = 'gallery $i';
            await tester.tap(find.byKey(const ValueKey('desktop-nav-1')));
            await tester.pumpAndSettle();
            binding.phase = 'creation $i';
            await tester.tap(find.byKey(const ValueKey('desktop-nav-0')));
            await tester.pumpAndSettle();
            expect(
              tester.widget<FilmStrip>(find.byType(FilmStrip)).results.length,
              history,
            );
            binding.phase = 'balance $i';
            await tester.tap(find.byType(AnlasChip));
            await tester.pumpAndSettle();
            expect(popover, findsOneWidget);
            await tester.tap(
              find.descendant(
                of: popover,
                matching: find.byIcon(Icons.refresh),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.descendant(of: popover, matching: find.byIcon(Icons.close)),
            );
            await tester.pumpAndSettle();
            expect(popover, findsNothing);
          }
          expect(binding.children.length, greaterThan(10));
          expect(binding.errors, isEmpty);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          container.dispose();
          await tester.pump(const Duration(seconds: 2));
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }
}
