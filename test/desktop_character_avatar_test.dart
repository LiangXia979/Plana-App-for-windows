import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plana_app/core/net/remote_image.dart';
import 'package:plana_app/features/editor/editor_models.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';

import 'support/character_avatar_fixture.dart';

void main() {
  late CharacterAvatarFixture fixture;
  final avatar = find.byKey(const ValueKey('character-avatar-avatar'));
  final preview = find.byKey(const ValueKey('reference-image-preview'));
  final previewImage = find.byKey(const ValueKey('reference-preview-image'));

  setUp(() async {
    fixture = CharacterAvatarFixture();
    await fixture.initialize();
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await fixture.dispose();
  });

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    tester.view.reset();
  }

  for (final remote in [false, true]) {
    testWidgets(
      '${remote ? 'remote' : 'local'} left click previews the original, right click leaves the canvas alone',
      (tester) async {
        final source = remote ? CharacterAvatarFixture.remote : fixture.local;
        fixture.setCharacter(source, enabled: false);
        await fixture.mount(tester, width: 360, scale: 1.4);
        await waitForAvatarImage(tester, avatar);
        final gen = fixture.container.read(generateProvider);
        expect(
          find.byKey(const ValueKey('character-library-avatar')),
          findsNothing,
        );
        expect(find.byTooltip('角色库'), findsNothing);
        await tester.tap(avatar, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(preview, findsOneWidget);
        expect(find.text('选择角色'), findsNothing);
        await waitForAvatarImage(tester, preview);
        final image = tester.widget<Image>(previewImage);
        expect(image.fit, BoxFit.contain);
        expect(image.image, isNot(isA<ResizeImage>()));
        if (remote) {
          expect((image.image as RemoteImageProvider).url, source);
        } else {
          expect((image.image as FileImage).file.path, source);
        }
        final raw = tester.widget<RawImage>(
          find.descendant(of: preview, matching: find.byType(RawImage)),
        );
        expect(raw.image!.width, 90);
        expect(raw.image!.height, 270);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(preview, findsNothing);
        expect(
          fixture.container.read(generateProvider).characters.single,
          same(gen.characters.single),
        );
        await tester.tap(
          avatar,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(
          fixture.container.read(generateProvider).characters.single,
          same(gen.characters.single),
        );
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );

    testWidgets(
      '${remote ? 'remote' : 'local'} top crop shows face; shared default crop stays centered',
      (tester) async {
        final top = GlobalKey();
        final center = GlobalKey();
        final source = remote ? CharacterAvatarFixture.remote : fixture.local;
        Widget tile(GlobalKey key, {Alignment alignment = Alignment.center}) =>
            RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 90,
                height: 90,
                child: alignment == Alignment.center
                    ? TagCardPreview(url: source, name: 'test')
                    : TagCardPreview(
                        url: source,
                        name: 'test',
                        alignment: alignment,
                      ),
              ),
            );
        await fixture.mount(
          tester,
          child: Row(
            children: [
              tile(top, alignment: Alignment.topCenter),
              tile(center),
            ],
          ),
        );
        await waitForAvatarImage(tester, find.byKey(top));
        await waitForAvatarImage(tester, find.byKey(center));
        Future<List<int>> sample(GlobalKey key) async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          return (await tester.runAsync(() async {
            final bitmap = await boundary.toImage();
            try {
              final bytes = (await bitmap.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final offset = (10 * bitmap.width + 10) * 4;
              return [for (var i = 0; i < 3; i++) bytes.getUint8(offset + i)];
            } finally {
              bitmap.dispose();
            }
          }))!;
        }

        expect(await sample(top), [240, 140, 60]);
        expect(await sample(center), [50, 120, 220]);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets('a saved AI fold resolves its OC cover and left-click preview', (
    tester,
  ) async {
    fixture.setCharacter(null);
    const name = '☺ 新角色 · 角色';
    const body = '1.2::new traveler::';
    final gen = fixture.container.read(generateProvider.notifier);
    gen.updateCharacter(
      'avatar',
      name: '主角',
      positive: 'standing, $body, smiling',
      positiveRaw: 'standing, <#$name: $body$kFoldClose, smiling',
      foldLinks: const [
        PromptFoldLink(
          id: 'old-import',
          temporaryCategory: 'character',
          positiveName: name,
          positiveBody: body,
          negativeName: '',
          negativeBody: '',
        ),
      ],
    );
    final saved = fixture.container.read(generateProvider).characters.single;
    await fixture.mount(tester);
    await waitForAvatarImage(tester, avatar);
    await tester.tap(avatar, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(
      (tester.widget<Image>(previewImage).image as FileImage).file.path,
      fixture.local,
    );
    expect(
      fixture.container.read(generateProvider).characters.single,
      same(saved),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await finish(tester);
  });

  for (final missing in [true, false]) {
    testWidgets(
      '${missing ? 'empty' : 'unreadable'} avatar opens no picker and handles unavailable artwork',
      (tester) async {
        final corrupt = File('${fixture.root.path}/corrupt.png')
          ..writeAsStringSync('not an image');
        fixture.setCharacter(missing ? null : corrupt.path);
        await fixture.mount(tester);
        await tester.tap(avatar, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        if (missing) {
          expect(preview, findsNothing);
        } else {
          for (
            var i = 0;
            i < 100 && find.text('这张角色图片暂时无法读取').evaluate().isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(find.text('这张角色图片暂时无法读取'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭预览'));
          await tester.pumpAndSettle();
          expect(preview, findsNothing);
        }
        expect(find.text('选择角色'), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'preview wheel zoom, reset, outside close and repeated open leave editor draft intact',
    (tester) async {
      fixture.setCharacter(fixture.local);
      await fixture.mount(tester);
      final input = find.descendant(
        of: find.byKey(const ValueKey('desktop-character-avatar-text')),
        matching: find.byType(TextField),
      );
      await tester.enterText(input, 'traveler, pending words');
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(avatar, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        await waitForAvatarImage(tester, preview);
        final viewer = tester.widget<InteractiveViewer>(
          find.descendant(
            of: preview,
            matching: find.byType(InteractiveViewer),
          ),
        );
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(previewImage),
            scrollDelta: const Offset(0, -100),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          viewer.transformationController!.value.getMaxScaleOnAxis(),
          greaterThan(1),
        );
        await tester.tap(find.byTooltip('适应窗口'));
        await tester.pumpAndSettle();
        expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(preview, findsNothing);
        expect(
          tester.widget<TextField>(input).controller!.text,
          'traveler, pending words',
        );
      }
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  group('mobile', () {
    setUp(() async {
      await fixture.dispose();
      fixture = CharacterAvatarFixture();
      await fixture.initialize(desktop: false);
    });
    testWidgets(
      'avatar keeps centered cropping and opens the full image on tap',
      (tester) async {
        fixture.setCharacter(fixture.local);
        await fixture.mount(tester);
        final thumb = find.byType(TagCardPreview);
        expect(
          tester.widget<TagCardPreview>(thumb).alignment,
          Alignment.center,
        );
        final before = fixture.container
            .read(generateProvider)
            .characters
            .single;
        await tester.tap(thumb);
        await tester.pumpAndSettle();
        await waitForAvatarImage(tester, preview);
        expect(preview, findsOneWidget);
        expect(
          fixture.container.read(generateProvider).characters.single,
          same(before),
        );
        await tester.tap(find.byTooltip('关闭预览'));
        await tester.pumpAndSettle();
        await finish(tester);
      },
    );
  });
}
