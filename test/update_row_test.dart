import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/core/store/app_stores.dart';
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/main.dart';
import 'package:plana_app/features/update/update_sheet.dart';

import 'support/desktop_capture.dart';
import 'support/pump_until.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesktopCaptureFonts);
  const channel = MethodChannel('plana/update');
  late Directory directory;
  late PrefsStore prefs;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('plana_check_row');
    prefs = PrefsStore.emptyForTest(directory);
  });
  Widget app() => ProviderScope(
    overrides: [prefsStoreProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: UpdateRow()),
    ),
  );
  tearDown(() async {
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Windows successful check, failure and retry display the current result',
    (tester) async {
      var status = 200;
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        if (request.url.host == 'api.github.com') {
          expect(status, 404);
          return http.Response('{}', status);
        }
        expect(
          request.url.path,
          '/LiangXia979/Plana-App-for-windows/releases.atom',
        );
        return http.Response(status == 200 ? '<feed/>' : '', status);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        await tester.pumpWidget(app());
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        await pumpUntil(tester, () => find.text('已是最新').evaluate().isNotEmpty);
        expect(find.text('已是最新'), findsOneWidget);
        status = 404;
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        await pumpUntil(tester, () => find.text('检查失败').evaluate().isNotEmpty);
        expect(find.text('检查失败'), findsOneWidget);
        expect(find.text('已是最新'), findsNothing);
        expect(find.textContaining('HTTP 404'), findsOneWidget);
        status = 200;
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        await pumpUntil(tester, () => find.text('已是最新').evaluate().isNotEmpty);
        expect(find.text('已是最新'), findsOneWidget);
        expect(find.text('检查失败'), findsNothing);
        expect(requests, 4);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'Windows starts with one notice per release; About can reopen a dismissed update',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final stores = AppStores.ephemeral();
      final capture = GlobalKey();
      final dialog = find.byKey(const ValueKey('windows-update-dialog'));
      var tag = 'v9.1.0-windows.75';
      var checks = 0;
      final client = MockClient((request) async {
        if (request.url.path != '/$kGithubRepo/releases.atom') {
          return http.Response('', 404);
        }
        checks++;
        return http.Response(
          '<feed><entry><title>Plana $tag</title>'
          '<link rel="alternate" href="https://github.com/$kGithubRepo/releases/tag/$tag"/>'
          '<content type="html">&lt;h2&gt;创作页&lt;/h2&gt;&lt;p&gt;优化了提示词编辑。&lt;/p&gt;</content></entry></feed>',
          200,
          headers: {'content-type': 'application/atom+xml; charset=utf-8'},
        );
      });
      Future<void> launch() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStoresProvider.overrideWithValue(stores),
              prefsStoreProvider.overrideWithValue(prefs),
            ],
            child: RepaintBoundary(key: capture, child: const PlanaApp()),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
      }

      await http.runWithClient(() async {
        await launch();
        await pumpUntil(tester, () => dialog.evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(find.textContaining('优化了提示词编辑。'), findsOneWidget);
        await captureDesktop(tester, capture, 'windows-update-notice');
        await tester.tap(find.text('以后再说'));
        await tester.pumpAndSettle();
        await launch();
        await pumpUntil(tester, () => checks >= 2);
        await pumpUntilComplete(tester, prefs.idle);
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        await tester.tap(find.text('我的').hitTestable().first);
        await tester.pumpAndSettle();
        final about = find.text('关于 Plana');
        await tester.ensureVisible(about.first);
        await tester.tap(about.hitTestable().first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('检查更新').hitTestable().first);
        await pumpUntil(tester, () => dialog.evaluate().isNotEmpty);
        expect(find.textContaining('优化了提示词编辑。'), findsOneWidget);
        await tester.tap(find.text('以后再说'));
        await tester.pumpAndSettle();
        tag = 'v9.1.0-windows.76';
        await launch();
        await pumpUntil(tester, () => dialog.evaluate().isNotEmpty);
        expect(find.textContaining(tag), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await pumpUntilComplete(tester, prefs.idle);
      }, () => client);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'unavailable installed version displays no information instead of latest',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('[]', 200);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        await tester.pumpWidget(app());
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.text('暂无更新信息'), findsWidgets);
        expect(find.text('已是最新'), findsNothing);
        expect(find.text('已是最新版本'), findsNothing);
        expect(requests, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
