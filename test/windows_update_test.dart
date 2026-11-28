import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/app_info.dart';
import 'package:plana_app/core/store/prefs_store.dart';
import 'package:plana_app/features/update/update_service.dart';
import 'package:plana_app/features/update/windows_update_download.dart';

const _tag = 'v2.0.0-windows.77';
const _official = 'https://github.com/$kGithubRepo';
String _feed(String tag) =>
    '''<feed xmlns="http://www.w3.org/2005/Atom"><entry>
  <title>Plana $tag</title><link rel="alternate" href="$_official/releases/tag/$tag" />
  <content type="html">&lt;h2&gt;Canvas&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;First change&lt;/li&gt;&lt;li&gt;Second change&lt;/li&gt;&lt;/ul&gt;</content>
</entry></feed>''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PrefsStore prefs;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = Directory.systemTemp.createTempSync('plana_release_test_');
    prefs = PrefsStore.emptyForTest(root);
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await prefs.idle;
    await root.delete(recursive: true);
  });

  test(
    'conditional feed checks share in-flight work; reminders persist per version and manual checks reopen',
    () async {
      var calls = 0;
      var tag = _tag;
      final gate = Completer<void>();
      final client = MockClient((req) async {
        expect(req.url.toString(), '$_official/releases.atom');
        await gate.future;
        calls++;
        if (calls == 2) {
          expect(req.headers['If-None-Match'], '"feed1"');
          return http.Response('', 304);
        }
        return http.Response(
          _feed(tag),
          200,
          headers: {'etag': '"feed$calls"'},
        );
      });
      await http.runWithClient(() async {
        final service = UpdateService(prefs);
        final one = service.check(), two = service.check();
        expect(one, same(two));
        gate.complete();
        final first = (await one).release!;
        expect(calls, 1);
        expect(first.notes, contains('• First change\n• Second change'));
        expect(service.beginNotice(first.tag, automatic: true), isTrue);
        expect(service.beginNotice(first.tag, automatic: false), isFalse);
        await service.rememberNotice(first.tag);
        service.endNotice();
        final reloaded = await PrefsStore.open(
          root,
          legacyRead: (_) async => null,
          legacyDelete: (_) async {},
        );
        final reboot = UpdateService(reloaded);
        final cached = (await reboot.check()).release!;
        expect(cached.notes, first.notes);
        expect(reboot.beginNotice(cached.tag, automatic: true), isFalse);
        expect(reboot.beginNotice(cached.tag, automatic: false), isTrue);
        reboot.endNotice();
        tag = 'v2.0.0-windows.78';
        final newer = (await reboot.check()).release!;
        expect(reboot.beginNotice(newer.tag, automatic: true), isTrue);
        await reboot.rememberNotice(newer.tag);
        reboot.endNotice();
        expect(reboot.beginNotice(first.tag, automatic: true), isFalse);
        expect(calls, 3);
      }, () => client);
    },
  );

  test(
    'when the feed is unavailable, respect the REST rate reset across restarts and recover via feed',
    () async {
      var feedAvailable = false;
      var apiCalls = 0;
      final client = MockClient((req) async {
        if (req.url.host == 'github.com') {
          return http.Response(
            feedAvailable ? _feed(_tag) : 'offline',
            feedAvailable ? 200 : 503,
          );
        }
        apiCalls++;
        return http.Response(
          '{}',
          403,
          headers: {'x-ratelimit-remaining': '0', 'retry-after': '3600'},
        );
      });
      await http.runWithClient(() async {
        for (var i = 0; i < 2; i++) {
          await expectLater(
            UpdateService(prefs).check(),
            throwsA(
              isA<UpdateException>().having(
                (e) => e.message,
                'reason',
                contains('次数已达上限'),
              ),
            ),
          );
        }
        expect(apiCalls, 1);
        feedAvailable = true;
        expect((await UpdateService(prefs).check()).release?.tag, _tag);
        expect(apiCalls, 1);
      }, () => client);
    },
  );

  test(
    'corrupt Atom cache and malformed feed fall back to the repository API and select the highest version',
    () async {
      await prefs.write(key: 'update_windows_release_feed', value: '{');
      var apiAvailable = true;
      final client = MockClient((req) async {
        if (req.url.host == 'github.com') {
          return http.Response('<html>Bad gateway</html>', 200);
        }
        if (!apiAvailable) return http.Response('', 503);
        return http.Response(
          jsonEncode([
            for (final tag in ['v2.0.0', 'v2.1.0', 'v1.3.0'])
              {
                'tag_name': tag,
                'html_url': '$_official/releases/tag/$tag',
                'body': 'Changes',
              },
          ]),
          200,
        );
      });
      await http.runWithClient(() async {
        expect((await UpdateService(prefs).check()).release?.tag, 'v2.1.0');
        apiAvailable = false;
        expect((await UpdateService(prefs).check()).release?.tag, 'v2.1.0');
      }, () => client);
    },
  );

  const packageName = 'Plana-Windows-2.0.0-windows.77-x64-build90-setup.exe';
  final bytes = utf8.encode('test package bytes; never executed');
  final hash = sha256.convert(bytes).toString();
  const release = GithubRelease(
    tag: _tag,
    name: '',
    notes: '',
    url: '$_official/releases/tag/$_tag',
    prerelease: false,
  );
  for (final valid in [true, false]) {
    test(
      'official package is kept only after a matching digest (match=$valid)',
      () async {
        final visited = <String>[];
        final client = MockClient((req) async {
          visited.add(req.url.path);
          if (req.url.path.contains('expanded_assets')) {
            return http.Response(
              '<ul><li><a href="/$kGithubRepo/releases/download/$_tag/$packageName">setup</a>'
              '<clipboard-copy value="sha256:$hash"></clipboard-copy></li></ul>',
              200,
            );
          }
          expect(
            req.url.toString(),
            '$_official/releases/download/$_tag/$packageName',
          );
          return http.Response.bytes(valid ? bytes : [1, 2, 3], 200);
        });
        final result = downloadWindowsUpdate(
          release,
          client: client,
          tempRoot: root,
          onProgress: (_, _) {},
        );
        if (valid) {
          final verified = await result;
          expect(await verified.file.readAsBytes(), bytes);
          expect(verified.package.isInstaller, isTrue);
          await verified.discard();
        } else {
          await expectLater(
            result,
            throwsA(
              isA<UpdateException>().having(
                (e) => e.message,
                'reason',
                contains('校验失败'),
              ),
            ),
          );
        }
        expect(root.listSync(), isEmpty);
        expect(visited, hasLength(2));
      },
    );
  }
  test(
    'unknown external or unsigned files do not start a package download',
    () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
          '<li><a href="https://example.org/$packageName">setup</a><clipboard-copy value="sha256:$hash"></clipboard-copy></li>'
          '<li><a href="$_official/releases/download/$_tag/$packageName">setup</a></li>',
          200,
        );
      });
      await expectLater(
        downloadWindowsUpdate(
          release,
          client: client,
          tempRoot: root,
          onProgress: (_, _) {},
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(calls, 1);
      expect(root.listSync(), isEmpty);
    },
  );
}
