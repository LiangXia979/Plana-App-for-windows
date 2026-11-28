library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';
import 'package:http/http.dart' as http;

import '../../core/app_info.dart';
import '../../core/store/prefs_store.dart';
import '../../core/store/app_stores.dart' show prefsStoreProvider;
import '../../core/util/log.dart';
import '../../l10n/l10n.dart';

part 'windows_release_feed.dart';

/// 检查更新失败。`toString()` 直接是可展示文案。
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _channel = MethodChannel('plana/update');

/// 当前运行应用的版本(Windows 随构建，Android 从系统读取)。
class InstalledInfo {
  const InstalledInfo({required this.versionName, required this.versionCode});

  final String versionName;
  final int versionCode;

  /// 无法取得版本时为空 —— 调用方据此跳过检查,
  /// 而不是拿空串去比出一个"有新版"。
  bool get isKnown => versionName.isNotEmpty;
}

/// GitHub 的一条 release。
class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.url,
    required this.prerelease,
    this.windowsPackage,
  });

  /// 形如 `v1.0.0-beta.2`(比较时会剥掉前导 v)。
  final String tag;
  final String name;
  final String notes;

  /// Release 页地址,用户点「去下载」时用浏览器打开。
  final String url;
  final bool prerelease;
  final WindowsReleasePackage? windowsPackage;

  Uri? get windowsDownload => windowsPackage?.url;

  /// 展示名:GitHub 上 release 标题常留空,回落到 tag。
  String get display => name.isNotEmpty ? name : tag;

  static GithubRelease? fromJson(
    Map<String, dynamic> j, {
    String repo = kGithubRepo,
  }) {
    if (j['draft'] == true) return null; // 草稿对外不存在
    final tag = j['tag_name'];
    final url = j['html_url'];
    if (tag is! String ||
        !validReleaseTag(tag) ||
        url is! String ||
        url.isEmpty) {
      return null;
    }
    return GithubRelease(
      windowsPackage: WindowsReleasePackage.pick(tag, j['assets'], repo: repo),
      tag: tag,
      name: (j['name'] as String?) ?? '',
      notes: j['body_html'] is String
          ? _readReleaseHtml(j['body_html'] as String)
          : (j['body'] as String?) ?? '',
      url: Uri.https('github.com', '/$repo/releases/tag/$tag').toString(),
      prerelease: j['prerelease'] == true,
    );
  }
}

bool validReleaseTag(String tag) => RegExp(
  r'^[vV]?\d+(?:\.\d+){2}(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z.-]+)?$',
).hasMatch(tag);

class WindowsReleasePackage {
  const WindowsReleasePackage._(this.url, this.sha256, this.size);
  final Uri url;
  final String? sha256;
  final int? size;
  String get name => url.pathSegments.last;
  bool get isInstaller => name.toLowerCase().endsWith('-setup.exe');

  static WindowsReleasePackage? pick(
    String tag,
    Object? assets, {
    String repo = kGithubRepo,
  }) {
    if (assets is! List || !validReleaseTag(tag)) return null;
    WindowsReleasePackage? portable;
    for (final asset in assets.whereType<Map>()) {
      final name = asset['name'];
      final raw = asset['browser_download_url'];
      if (name is! String ||
          raw is! String ||
          !RegExp(
            r'^Plana-Windows-[a-z0-9.+-]+-x64(?:-[a-z0-9.-]+)?(?:-setup\.exe|\.zip)$',
            caseSensitive: false,
          ).hasMatch(name)) {
        continue;
      }
      final uri = Uri.https(
        'github.com',
        '/$repo/releases/download/$tag/$name',
      );
      if (Uri.tryParse(raw) != uri) continue;
      final digest = asset['digest'];
      final hash = digest is String
          ? RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest)?.group(1)
          : null;
      final size = asset['size'];
      final package = WindowsReleasePackage._(
        uri,
        hash?.toLowerCase(),
        size is int && size > 0 ? size : null,
      );
      if (package.isInstaller) return package;
      portable ??= package;
    }
    return portable;
  }
}

/// 一次检查的结论。
class UpdateCheck {
  const UpdateCheck({required this.installed, this.release});

  final InstalledInfo installed;

  /// 比当前版本新的 release;没有(或拿不到)时为 null。
  final GithubRelease? release;

  bool get hasUpdate => release != null;
}

// ── 语义化版本比较 ───────────────────────────────────────────────────────

/// 比较两个语义化版本。→ 负数 / 0 / 正数。
///
/// **不能用字符串比。** `1.0.0-beta.10` 按字典序小于 `1.0.0-beta.9`,直接
/// 字符串比会让 beta.9 的用户永远收不到 beta.10。按 semver 2.0 规则:
/// 主次修订逐段按数字比;**带预发布标识的版本小于同号正式版**;预发布标识
/// 逐段比,纯数字段按数字、含字母段按 ASCII,数字段小于字母段。
int compareSemver(String a, String b) {
  final (coreA, preA) = _split(a);
  final (coreB, preB) = _split(b);

  for (var i = 0; i < 3; i++) {
    final c = (i < coreA.length ? coreA[i] : 0).compareTo(
      i < coreB.length ? coreB[i] : 0,
    );
    if (c != 0) return c;
  }

  // 1.0.0-beta.1 < 1.0.0
  if (preA.isEmpty && preB.isEmpty) return 0;
  if (preA.isEmpty) return 1;
  if (preB.isEmpty) return -1;

  for (var i = 0; i < preA.length && i < preB.length; i++) {
    final x = preA[i], y = preB[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final int c;
    if (nx != null && ny != null) {
      c = nx.compareTo(ny);
    } else if (nx != null) {
      c = -1; // 数字段 < 字母段
    } else if (ny != null) {
      c = 1;
    } else {
      c = x.compareTo(y);
    }
    if (c != 0) return c;
  }
  // 前缀相同则段数少的更小(1.0.0-beta < 1.0.0-beta.1)
  return preA.length.compareTo(preB.length);
}

/// → (主次修订数组, 预发布标识数组)。剥前导 `v`,丢掉 `+build` 元数据。
(List<int>, List<String>) _split(String v) {
  var s = v.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  s = s.split('+').first; // build 元数据不参与比较
  final dash = s.indexOf('-');
  final core = dash < 0 ? s : s.substring(0, dash);
  final pre = dash < 0 ? '' : s.substring(dash + 1);
  return (
    [for (final p in core.split('.')) int.tryParse(p) ?? 0],
    pre.isEmpty ? const <String>[] : pre.split('.'),
  );
}

/// 该版本串是否是预发布(带 `-beta` 之类)。
bool isPrerelease(String v) => _split(v).$2.isNotEmpty;

// ── 检查 ─────────────────────────────────────────────────────────────────

/// Windows 使用随应用编译、与 pubspec 校验一致的版本；Android 读取系统通道。
/// 版本不可用时返回空 [InstalledInfo],不抛。
Future<InstalledInfo> installedInfo() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    return InstalledInfo(
      versionName: kAppVersion,
      versionCode: int.tryParse(kAppBuild) ?? 0,
    );
  }
  try {
    final m = await _channel.invokeMapMethod<String, dynamic>('info');
    if (m == null) return const InstalledInfo(versionName: '', versionCode: 0);
    return InstalledInfo(
      versionName: (m['versionName'] as String?) ?? '',
      versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
    );
  } catch (e) {
    logd('[update] 读取已安装版本失败: $e');
    return const InstalledInfo(versionName: '', versionCode: 0);
  }
}

/// 拉 GitHub 上比 [current] 新的 release;没有则 null。
///
/// 用 `/releases` 列表而**不是** `/releases/latest` —— 后者会把预发布整个排除,
/// 而我们发的就是 `1.0.0-beta.x`,用它等于永远查不到东西。
///
/// 缺少版本或仓库时不查询；非 200 响应抛出 [UpdateException]。
Future<GithubRelease?> fetchLatestRelease(
  String current, {
  String repo = kGithubRepo,
  PrefsStore? prefs,
}) async {
  if (repo.isEmpty || current.isEmpty) return null;
  try {
    if (prefs != null) _checkCooldown(prefs, _apiCooldownKey);
    final resp = await http
        .get(
          Uri.parse('https://api.github.com/repos/$repo/releases?per_page=10'),
          headers: const {'Accept': 'application/vnd.github.full+json'},
        )
        .timeout(const Duration(seconds: 15));
    await _respectRateLimit(resp, prefs, _apiCooldownKey);
    if (resp.statusCode != 200) {
      throw UpdateException(l10nNow.updateHttpFailed(resp.statusCode));
    }
    final j = jsonDecode(utf8.decode(resp.bodyBytes));
    if (j is! List) throw UpdateException(l10nNow.updateBadFormat);
    return pickNewer(current, j, repo: repo);
  } on TimeoutException {
    throw UpdateException(l10nNow.updateTimeout);
  } on http.ClientException {
    throw UpdateException(l10nNow.cantReachGithub);
  } on SocketException {
    throw UpdateException(l10nNow.cantReachGithub);
  } on TlsException {
    throw UpdateException(l10nNow.cantReachGithub);
  } on UpdateException {
    rethrow;
  } catch (e) {
    logd('[update] 检查更新异常: $e');
    throw UpdateException(l10nNow.updateFailed);
  }
}

/// 从 release 列表里挑出比 [current] 新的那个(纯逻辑,单独抽出来可测)。
///
/// 已在正式版上的用户**不会**被推预发布 —— 否则装着 1.0.0 的人会被 1.1.0-beta.1
/// 拽回测试轨道。仍在 beta 上的人则照收 beta。
GithubRelease? pickNewer(
  String current,
  List<dynamic> releases, {
  String repo = kGithubRepo,
}) {
  final onPrerelease = isPrerelease(current);
  Map<String, dynamic>? newest;
  var bestTag = current;
  for (final item in releases.whereType<Map<String, dynamic>>()) {
    final tag = item['tag_name'];
    if (tag is! String ||
        !validReleaseTag(tag) ||
        item['draft'] == true ||
        (item['prerelease'] == true && !onPrerelease) ||
        item['html_url'] is! String ||
        (item['html_url'] as String).isEmpty) {
      continue;
    }
    if (compareSemver(tag, bestTag) > 0) {
      newest = item;
      bestTag = tag;
    }
  }
  return newest == null ? null : GithubRelease.fromJson(newest, repo: repo);
}

// ── 自动检查的节流 ───────────────────────────────────────────────────────

const _kLastCheckKey = 'update_last_check';

/// 记下"刚查过"。**不进 `PrefsStore.migrateKeys`** —— 那份名单只为「曾经在
/// secure storage 里、需要迁出」的键而设;这是个全新的键,从没在别处待过。
///
/// 收 [PrefsStore] 而不是 ref:`Ref` 与 `WidgetRef` 在 Riverpod 3 是两个类型,
/// 而调用方一个在 provider 里、一个在 State 里 —— 直接收 store 两边都能用。
Future<void> markUpdateChecked(PrefsStore prefs) async {
  try {
    await prefs.write(
      key: _kLastCheckKey,
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
  } catch (_) {}
}

/// 距上次检查是否已超过 [interval](默认 24h)。启动时自动检查用,避免每次
/// 冷启都打一次 GitHub。
bool shouldAutoCheck(
  PrefsStore prefs, {
  Duration interval = const Duration(hours: 24),
}) {
  final last = int.tryParse(prefs.get(_kLastCheckKey) ?? '');
  if (last == null) return true;
  return DateTime.now().millisecondsSinceEpoch - last > interval.inMilliseconds;
}

final updateServiceProvider = Provider<UpdateService>(
  (ref) => UpdateService(ref.watch(prefsStoreProvider)),
);

class UpdateService {
  UpdateService(this.prefs);
  final PrefsStore prefs;
  Future<UpdateCheck>? _pending;
  bool _noticeOpen = false;

  Future<UpdateCheck> check() => _pending ??= _check().whenComplete(() {
    _pending = null;
  });

  Future<UpdateCheck> _check() async {
    final installed = await installedInfo();
    GithubRelease? release;
    if (installed.isKnown && kGithubRepo.isNotEmpty) {
      release = defaultTargetPlatform == TargetPlatform.windows
          ? await _windowsRelease(installed.versionName, prefs)
          : await fetchLatestRelease(installed.versionName, prefs: prefs);
    }
    return UpdateCheck(installed: installed, release: release);
  }

  bool beginNotice(String tag, {required bool automatic}) {
    final previous = prefs.get('update_last_presented_tag');
    if (_noticeOpen ||
        (automatic && previous != null && compareSemver(tag, previous) <= 0)) {
      return false;
    }
    _noticeOpen = true;
    return true;
  }

  Future<void> rememberNotice(String tag) async {
    final previous = prefs.get('update_last_presented_tag');
    if (previous == null || compareSemver(tag, previous) > 0) {
      await prefs.write(key: 'update_last_presented_tag', value: tag);
    }
  }

  void endNotice() => _noticeOpen = false;
}
