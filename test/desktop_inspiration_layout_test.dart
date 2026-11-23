import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:plana_app/core/platform/desktop.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/theme/theme_settings.dart';
import 'package:plana_app/features/generate/generate_state.dart';
import 'package:plana_app/features/editor/data/tag_translation_service.dart';
import 'package:plana_app/features/inspiration/codex/codex_history.dart';
import 'package:plana_app/features/inspiration/codex/codex_models.dart';
import 'package:plana_app/features/inspiration/codex/codex_providers.dart';
import 'package:plana_app/features/inspiration/inspiration_page.dart';
import 'package:plana_app/features/inspiration/public_tags.dart';
import 'package:plana_app/features/inspiration/tag_library.dart';
import 'package:plana_app/features/inspiration/tag_models.dart';
import 'package:plana_app/features/inspiration/widgets/tag_card.dart';
import 'package:plana_app/features/inspiration/widgets/inspiration_entry_card.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

class _Acknowledged extends CodexIntro {
  @override
  bool? build() => true;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;
  late AppStores stores;
  late ProviderContainer container;
  final capture = GlobalKey();
  final art = Platform.environment['PLANA_SIDEBAR_TEST_ART'];
  const artNames = [
    'lolita',
    'maid-blue',
    'water-blue',
    'maid-pink',
    'lilac',
    'ribbon-pink',
  ];
  final entries = [
    for (var i = 0; i < 8; i++)
      TagEntry(
        id: 'char$i',
        category: TagCategory.character,
        name: [
          '白发少女',
          '森林旅人',
          '暮色精灵',
          '午后访客',
          '海风与少年',
          '花园来信',
          '雪中旅人',
          '星夜猫娘',
        ][i],
        positive: [
          'white hair, blue eyes, 1girl',
          'traveler, green eyes, forest',
          'elf, purple hair, sunset',
          '1girl, brown hair, cafe',
          '1boy, ocean, white shirt',
          '1girl, garden, flowers',
          'snow, traveler, white hair',
          'cat girl, night, stars',
        ][i],
        aliases: ['别名$i'],
        previews: [
          if (art != null) '$art/${artNames[i % artNames.length]}.webp',
        ],
        tags: [if (i == 0) '白发'],
        createdAt: 10 - i,
      ),
    const TagEntry(
      id: 'scene0',
      category: TagCategory.scene,
      name: '樱花树下',
      positive: 'cherry blossoms',
    ),
  ];
  const publicEntry = TagEntry(
    id: 'pub_cat',
    category: TagCategory.character,
    name: '公共猫娘',
    positive: 'cat girl, white hair',
    publicId: 'cat',
    createdBy: '10001',
  );

  setUpAll(loadDesktopCaptureFonts);
  setUp(() {
    // File decodes from a previous widget test can still belong to its fake clock.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    FlutterSecureStorage.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('plana_inspiration_layout_');
    File('${temp.path}/tag_library.json').writeAsStringSync(
      jsonEncode({'entries': entries.map((e) => e.toJson()).toList()}),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => temp.path,
    );
    stores = AppStores.ephemeral();
    container = ProviderContainer(
      overrides: [
        appStoresProvider.overrideWithValue(stores),
        desktopModeProvider.overrideWithValue(true),
        codexIntroProvider.overrideWith(_Acknowledged.new),
        codexIndexProvider.overrideWith(
          (ref) async => const [
            CodexMeta(id: 'styles', type: CodexType.string, title: '画风词典'),
          ],
        ),
        codexMediaProvider.overrideWith((ref) async => CodexMedia.fallback),
        codexDataProvider.overrideWith(
          (ref, id) async => const CodexData(
            meta: CodexMeta(
              id: 'styles',
              type: CodexType.string,
              title: '画风词典',
            ),
            entries: [
              CodexEntry(id: 'forest', title: '森林', tags: 'forest, sunlight'),
              CodexEntry(id: 'sea', title: '海岸', tags: 'sea, sunset'),
            ],
          ),
        ),
        codexTagZhProvider.overrideWith((ref, id) async => null),
        publicTagsProvider.overrideWith(
          (ref, cat) async => cat == TagCategory.character
              ? [
                  publicEntry.copyWith(
                    mosaic: true,
                    previews: [File('assets/app_icon.png').absolute.path],
                  ),
                ]
              : [],
        ),
        tagAuthorNamesProvider.overrideWith((ref) async => {'10001': '示例作者'}),
        tagTranslationServiceProvider.overrideWith((ref) {
          final service = TagTranslationService(enabled: false, baseUrl: '');
          ref.onDispose(service.dispose);
          return service;
        }),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    stores.flushNow();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    temp.deleteSync(recursive: true);
  });
  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> captureArt(
    WidgetTester tester,
    Finder region,
    String name,
  ) async {
    if (art != null && Platform.environment['PLANA_DESKTOP_CAPTURE'] == '1') {
      final images = find.descendant(
        of: region,
        matching: find.byType(RawImage),
      );
      await pumpUntil(
        tester,
        () =>
            images.evaluate().isNotEmpty &&
            tester
                .widgetList<RawImage>(images)
                .every((image) => image.image != null),
      );
      await tester.pumpAndSettle();
    }
    await captureDesktop(tester, capture, name);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => container.read(tagLibraryProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light().copyWith(
              platform: TargetPlatform.windows,
              textTheme: AppTheme.light().textTheme.apply(
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: const InspirationPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'scene and other use the managed category names and omit sample actions',
    (tester) async {
      await mount(tester);
      for (final category in [TagCategory.scene, TagCategory.other]) {
        final tab = key('inspiration-category-${category.name}');
        final label = tagCategoryDef(category).label;
        if (category == TagCategory.other) expect(label, '其它');
        expect(
          find.descendant(of: tab, matching: find.text(label)),
          findsOneWidget,
        );
        await tester.ensureVisible(tab);
        await tester.tap(tab);
        await tester.pumpAndSettle();
        expect(find.text('新建$label'), findsOneWidget);
        expect(find.text('添加预览示例'), findsNothing);
      }
      await finish(tester);
    },
  );

  testWidgets(
    'a tall character preview keeps the top of the source image in view',
    (tester) async {
      final portrait = img.Image(width: 80, height: 400);
      img.fill(portrait, color: img.ColorRgb8(0, 0, 255));
      img.fillRect(
        portrait,
        x1: 0,
        y1: 0,
        x2: 79,
        y2: 79,
        color: img.ColorRgb8(255, 0, 0),
      );
      final file = File('${temp.path}/portrait.png')
        ..writeAsBytesSync(img.encodePng(portrait));
      await mount(tester);
      final preview = find.descendant(
        of: key('inspiration-card-char0'),
        matching: find.byType(TagCardPreview),
      );
      final size = tester.getSize(preview);
      final config = tester.widget<TagCardPreview>(preview);
      final frameKey = GlobalKey();
      // Render the portrait with the grid's actual size and crop, independently
      // of the asynchronous name badge that normally overlays it.
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: RepaintBoundary(
              key: frameKey,
              child: SizedBox.fromSize(
                size: size,
                child: TagCardPreview(
                  url: file.path,
                  name: config.name,
                  decodeWidth: config.decodeWidth,
                  alignment: config.alignment,
                ),
              ),
            ),
          ),
        ),
      );
      final image = find.descendant(
        of: find.byKey(frameKey),
        matching: find.byType(RawImage),
      );
      await pumpUntil(
        tester,
        () => tester.widgetList<RawImage>(image).any((w) => w.image != null),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final point = Offset(size.width / 2, size.height * .2);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(frameKey),
      );
      await tester.runAsync(() async {
        final frame = await boundary.toImage();
        try {
          final pixels = (await frame.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final index = (point.dy.floor() * frame.width + point.dx.floor()) * 4;
          expect(pixels.getUint8(index), greaterThan(240));
          expect(pixels.getUint8(index + 2), lessThan(15));
        } finally {
          frame.dispose();
        }
      });
      await finish(tester);
      PaintingBinding.instance.imageCache.clear();
    },
  );

  testWidgets(
    'desktop toolbar, responsive cards, filters and details preserve browsing state',
    (tester) async {
      await mount(tester);
      final search = key('tag-search-character');
      AlignmentGeometry previewAlignment(String id) => tester
          .widget<TagCardPreview>(
            find.descendant(
              of: key('inspiration-card-$id'),
              matching: find.byType(TagCardPreview),
            ),
          )
          .alignment;
      expect(previewAlignment('char0'), Alignment.topCenter);
      expect(tester.getSize(search).width, 300);
      expect(
        tester.getCenter(search).dy,
        closeTo(tester.getCenter(key('inspiration-category-character')).dy, 4),
      );
      expect(
        tester.getTopLeft(key('inspiration-card-char0')).dy,
        tester.getTopLeft(key('inspiration-card-char5')).dy,
      );
      expect(
        tester.getTopLeft(key('inspiration-card-char6')).dy,
        greaterThan(tester.getTopLeft(key('inspiration-card-char0')).dy),
      );
      await captureDesktop(tester, capture, 'windows52-inspiration-wide');

      await tester.tap(key('inspiration-menu-char0'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(PopupMenuItem<InspirationEntryAction>, '查看提示词'),
      );
      await tester.pumpAndSettle();
      expect(key('inspiration-prompt-detail'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getSize(key('inspiration-prompt-detail')).width,
        lessThanOrEqualTo(1500),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        tester.widget<InspirationEntryCard>(key('char0')).selected,
        isFalse,
      );

      await tester.enterText(search, '别名0');
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char0'), findsOneWidget);
      expect(key('inspiration-card-char1'), findsNothing);
      tester.view.physicalSize = const Size(740, 700);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, '别名0');
      expect(tester.takeException(), isNull);
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      await captureDesktop(tester, capture, 'windows52-inspiration-compact');
      await tester.tap(find.widgetWithText(ChoiceChip, '白发'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-char1'), findsNothing);
      await tester.tap(key('inspiration-category-scene'));
      await tester.pumpAndSettle();
      expect(key('inspiration-scope-public'), findsNothing);
      expect(key('inspiration-card-scene0'), findsOneWidget);
      expect(previewAlignment('scene0'), Alignment.center);
      await finish(tester);
    },
  );

  testWidgets(
    'detail arrows stay within visible entries and zoom returns to the same item',
    (tester) async {
      final file = File(
        art == null ? 'assets/app_icon.png' : '$art/maid-blue.webp',
      ).absolute;
      File('${temp.path}/tag_library.json').writeAsStringSync(
        jsonEncode({
          'entries': [
            for (final e in entries)
              (e.id == 'char1' ? e.copyWith(previews: [file.path]) : e)
                  .toJson(),
          ],
        }),
      );
      await mount(tester);
      await tester.tap(key('inspiration-menu-char0'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(PopupMenuItem<InspirationEntryAction>, '查看提示词'),
      );
      await tester.pumpAndSettle();
      final detail = key('inspiration-prompt-detail');
      Finder page(String counter) =>
          find.descendant(of: detail, matching: find.text(counter));
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      expect(page('1 / 8'), findsOneWidget);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(page('1 / 8'), findsOneWidget);
      await captureArt(tester, detail, 'inspiration-main-detail');
      await press(LogicalKeyboardKey.arrowRight);
      expect(page('2 / 8'), findsOneWidget);
      await tester.tap(key('inspiration-enlarge-image'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Image>(key('reference-preview-image')).image,
        FileImage(file),
      );
      final viewer = find.descendant(
        of: key('reference-image-preview'),
        matching: find.byType(InteractiveViewer),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(viewer),
          scrollDelta: const Offset(0, -140),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<InteractiveViewer>(viewer)
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        greaterThan(1),
      );
      await press(LogicalKeyboardKey.arrowRight);
      await press(LogicalKeyboardKey.escape);
      expect(key('reference-image-preview'), findsNothing);
      expect(page('2 / 8'), findsOneWidget);
      for (var i = 0; i < 7; i++) {
        await press(LogicalKeyboardKey.arrowRight);
      }
      expect(page('8 / 8'), findsOneWidget);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(page('7 / 8'), findsOneWidget);
      await press(LogicalKeyboardKey.escape);
      await tester.enterText(key('tag-search-character'), '别名1');
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-menu-char1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看提示词'));
      await tester.pumpAndSettle();
      await press(LogicalKeyboardKey.arrowRight);
      expect(page('1 / 1'), findsOneWidget);
      await tester.tap(key('inspiration-detail-select'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<InspirationEntryCard>(key('char1')).selected,
        isTrue,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'categories scroll within one row and snap one wheel step without moving the tools',
    (tester) async {
      await mount(tester);
      final viewport = key('inspiration-category-viewport');
      final search = key('tag-search-character');
      final newButton = key('inspiration-new');
      final originalSearch = tester.getRect(search);
      final originalNew = tester.getRect(newButton);
      final originalViewport = tester.getRect(viewport);
      final added = <TagCategoryDef>[];
      await tester.runAsync(() async {
        for (var i = 1; i <= 24; i++) {
          added.add(
            await container
                .read(tagLibraryProvider.notifier)
                .addCategory(
                  label: i == 24 ? '带有很长名称的自定义服装分类及造型参考' : '分类 $i',
                  iconName: 'Shirt',
                  layout: TagCardLayout.portrait,
                ),
          );
        }
      });
      await tester.pumpAndSettle();
      final last = key('inspiration-category-${added.last.key.name}');
      final bar = tester.widget<Scrollbar>(
        find.descendant(of: viewport, matching: find.byType(Scrollbar)),
      );
      final controller = bar.controller!;
      final row = originalViewport.height;
      Future<void> wheel(double delta) async {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(viewport),
            scrollDelta: Offset(0, delta),
          ),
        );
        await tester.pumpAndSettle();
      }

      expect(tester.getRect(search), originalSearch);
      expect(tester.getRect(newButton), originalNew);
      expect(tester.getRect(viewport), originalViewport);
      expect(bar.thumbVisibility, isTrue);
      expect(controller.position.maxScrollExtent, greaterThan(row * 2));
      expect(last.hitTestable(), findsNothing);
      expect(find.byTooltip('管理类别').hitTestable(), findsOneWidget);
      await captureArt(
        tester,
        key('inspiration.character.mine'),
        'inspiration-main-categories',
      );
      await wheel(12);
      expect(controller.offset, closeTo(12, .1));
      container
          .read(themeSettingsProvider.notifier)
          .patch((s) => s.copyWith(inspirationRowSnap: true));
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      await wheel(500);
      expect(controller.offset, closeTo(row, .1));
      await wheel(2);
      expect(controller.offset, closeTo(2 * row, .1));
      await wheel(-500);
      expect(controller.offset, closeTo(row, .1));
      for (
        var step = 0;
        step <= (controller.position.maxScrollExtent / row).ceil();
        step++
      ) {
        await wheel(120);
      }
      expect(controller.offset, controller.position.maxScrollExtent);
      expect(key('inspiration-category-codex').hitTestable(), findsOneWidget);
      // Depending on label width, Codex can occupy the row after the last custom tab.
      if (last.hitTestable().evaluate().isEmpty) await wheel(-120);
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(search), originalSearch);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(key('tag-search-${added.last.webId}'), findsOneWidget);
      tester.view.physicalSize = const Size(760, 680);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getSize(viewport).height, row);
      expect(newButton.hitTestable(), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('compact codex toolbar preserves tag search and filtering', (
    tester,
  ) async {
    await mount(tester);
    final search = key('tag-search-character');
    await tester.enterText(search, '别名0');
    await tester.tap(find.widgetWithText(ChoiceChip, '白发'));
    await tester.pumpAndSettle();
    await tester.tap(key('inspiration-category-codex'));
    await tester.pumpAndSettle();
    final button = key('codex-picker-button');
    final query = key('desktop-codex-search');
    final draw = key('codex-main-draw-toggle');
    final manager = find.byTooltip('管理类别');
    final fieldRect = tester.getRect(query);
    expect(tester.getCenter(manager).dy, closeTo(fieldRect.center.dy, 1));
    expect(tester.getRect(manager).right, lessThan(fieldRect.left));
    expect(fieldRect.right, lessThan(tester.getRect(draw).left));
    expect(tester.getCenter(draw).dy, closeTo(fieldRect.center.dy, 1));
    expect(fieldRect.bottom, lessThan(tester.getRect(button).top));
    expect(
      find.descendant(of: draw, matching: find.text('随机灵感')),
      findsOneWidget,
    );

    await captureDesktop(tester, capture, 'codex-main-search-header');
    await tester.enterText(query, 'sunset');
    await tester.pump(const Duration(milliseconds: 300));
    expect(key('desktop-codex-card-sea'), findsOneWidget);
    expect(key('desktop-codex-card-forest'), findsNothing);
    await tester.runAsync(() => container.read(codexHistoryProvider.future));
    await tester.tap(draw);
    await tester.pumpAndSettle();
    expect(query.hitTestable(), findsOneWidget);
    expect(find.text('1 候选'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.widget<TextField>(query).focusNode!.hasFocus, isTrue);
    await tester.enterText(query, 'missing');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('0 候选'), findsOneWidget);
    await tester.enterText(query, 'sunset');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(key('codex-random-history'));
    await tester.pumpAndSettle();
    expect(query.hitTestable(), findsOneWidget);
    await tester.tap(draw);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(query).controller!.text, 'sunset');
    final anchor = tester.getRect(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(key('desktop-popover')).top,
      closeTo(anchor.bottom + 8, 1),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(740, 700);
    await tester.pumpAndSettle();
    expect(button.hitTestable(), findsOneWidget);
    expect(query.hitTestable(), findsOneWidget);
    expect(tester.getRect(query).bottom, lessThan(tester.getRect(button).top));
    await tester.ensureVisible(key('inspiration-category-character'));
    await tester.pumpAndSettle();
    await tester.tap(key('inspiration-category-character'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, '别名0');
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '白发')).selected,
      isTrue,
    );
    expect(key('inspiration-card-char0'), findsOneWidget);
    expect(key('inspiration-card-char1'), findsNothing);
    await finish(tester);
  });

  testWidgets(
    'new and edit actions open one dismissible editor; selection still imports to creation',
    (tester) async {
      await mount(tester);
      final create = tester
          .widget<FilledButton>(key('inspiration-new'))
          .onPressed!;
      create();
      create();
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭编辑器'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsNothing);
      await tester.tap(key('inspiration-menu-char0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(key('tag-editor-dialog'), findsOneWidget);
      expect(find.widgetWithText(TextField, '白发少女'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-select-char0'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<InspirationEntryCard>(key('char0')).selected,
        isTrue,
      );
      await tester.tap(find.text('主提示词'));
      // Selection clears after the usage record is saved. Wait for that
      // observable completion, rather than assuming disk I/O takes <150 ms.
      for (
        var i = 0;
        i < 100 && key('desktop-inspiration-selection').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      final imported = container
          .read(generateProvider)
          .sections
          .where((s) => !s.isMain)
          .single;
      expect(imported.name, '白发少女');
      expect(imported.positive, contains('white hair'));
      expect(
        tester.widget<InspirationEntryCard>(key('char0')).selected,
        isFalse,
      );
      await finish(tester);
    },
  );

  testWidgets(
    'desktop right-click actions retain the selected group and cancellation preserves data',
    (tester) async {
      await mount(tester);
      await tester.tap(key('inspiration-select-char0'));
      await tester.tap(key('inspiration-select-char1'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(key('desktop-inspiration-selection')).height,
        lessThan(80),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(key('inspiration-card-char0')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 项'), findsOneWidget);
      expect(
        find.widgetWithText(PopupMenuItem<String>, '加入角色'),
        findsOneWidget,
      );
      await captureDesktop(
        tester,
        capture,
        'windows17-inspiration-context-menu',
      );
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '取消选择'));
      await tester.pumpAndSettle();
      expect(key('desktop-inspiration-selection'), findsNothing);
      expect(
        tester.widget<InspirationEntryCard>(key('char0')).selected,
        isFalse,
      );
      expect(
        tester.widget<InspirationEntryCard>(key('char1')).selected,
        isFalse,
      );
      expect(
        container.read(tagLibraryProvider).value!.entries.length,
        entries.length,
      );

      await tester.tap(key('inspiration-select-char0'));
      await tester.tap(key('inspiration-select-char1'));
      await tester.pumpAndSettle();
      final unselected = await tester.startGesture(
        tester.getCenter(key('inspiration-card-char2')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await unselected.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        container.read(tagLibraryProvider).value!.entries.length,
        entries.length,
      );
      await tester.tap(key('inspiration-selection-menu'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(PopupMenuItem<String>, '主提示词'));
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      final imported = container
          .read(generateProvider)
          .sections
          .where((s) => !s.isMain)
          .single;
      expect(imported.name, '暮色精灵');
      expect(imported.positive, contains('purple hair'));
      expect(imported.positive, isNot(contains('white hair')));
      for (
        var i = 0;
        i < 50 && key('desktop-inspiration-selection').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(key('desktop-inspiration-selection'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'public collection appears under My favorites and search survives scope changes',
    (tester) async {
      await mount(tester);
      await tester.tap(key('inspiration-scope-public'));
      await tester.pumpAndSettle();
      expect(key('inspiration-card-pub_cat'), findsOneWidget);
      await tester.tap(key('inspiration-menu-pub_cat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看提示词'));
      await tester.pumpAndSettle();
      final dialog = key('inspiration-prompt-detail');
      expect(
        find.descendant(of: dialog, matching: key('inspiration-enlarge-image')),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: dialog,
          matching: find.widgetWithText(FilledButton, '点击显示原图'),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('inspiration-enlarge-image').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.enterText(key('tag-search-character'), '公共猫娘');
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-star-pub_cat'));
      await tester.pumpAndSettle();
      await pumpUntilComplete(
        tester,
        container.read(tagLibraryProvider.notifier).settled,
      );
      await pumpUntil(
        tester,
        () => container
            .read(tagLibraryProvider)
            .requireValue
            .entries
            .any((e) => e.publicId == 'cat' && e.isFavorite),
        reason: 'Collection must finish its file write before cleanup',
      );
      expect(
        tester.widget<IconButton>(key('inspiration-star-pub_cat')).icon,
        isA<Icon>().having((icon) => icon.icon, 'starred', Icons.star_rounded),
      );
      await tester.tap(key('inspiration-scope-mine'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '收藏'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('tag-search-character')).controller!.text,
        '公共猫娘',
      );
      expect(find.text('公共猫娘'), findsWidgets);
      expect(
        container
            .read(tagLibraryProvider)
            .value!
            .entries
            .where((e) => e.publicId == 'cat')
            .length,
        1,
      );
      await tester.tap(key('inspiration-scope-public'));
      await tester.pumpAndSettle();
      await tester.tap(key('inspiration-star-pub_cat'));
      await tester.pumpAndSettle();
      await pumpUntil(
        tester,
        () => !container
            .read(tagLibraryProvider)
            .requireValue
            .entries
            .singleWhere((e) => e.publicId == 'cat')
            .isFavorite,
      );
      expect(key('inspiration-card-pub_cat'), findsNothing);
      await pumpUntilComplete(
        tester,
        container.read(tagLibraryProvider.notifier).settled,
      );
      await finish(tester);
    },
  );
}
