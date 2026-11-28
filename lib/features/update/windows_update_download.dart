import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../../core/app_info.dart';
import '../../l10n/l10n.dart';
import 'update_service.dart';

/// Each download owns its temporary directory. Only a fully verified file can
/// be opened, and dismissing the dialog discards an unused download.
class DownloadedUpdate {
  DownloadedUpdate._(this.package, this.file);
  final WindowsReleasePackage package;
  final File file;

  Future<void> discard() async {
    try {
      if (await file.exists()) await file.delete();
      await file.parent.delete();
    } on FileSystemException {
      // Windows can still own the file while the installer is in use.
    }
  }

  Future<void> open() async {
    if ((await crypto.sha256.bind(file.openRead()).first).toString() !=
        package.sha256) {
      throw UpdateException(l10nNow.updateIntegrityFailed);
    }
    if (package.isInstaller) {
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
    } else {
      await Process.start('explorer.exe', [
        file.parent.path,
      ], mode: ProcessStartMode.detached);
    }
  }
}

Future<WindowsReleasePackage> _releasePackage(
  GithubRelease release,
  http.Client client,
) async {
  final known = release.windowsPackage;
  if (known != null && known.sha256 != null) return known;
  final tag = release.tag;
  if (!validReleaseTag(tag)) throw UpdateException(l10nNow.updateBadFormat);
  final url = Uri.https(
    'github.com',
    '/$kGithubRepo/releases/expanded_assets/$tag',
  );
  final reply = await client.get(url).timeout(const Duration(seconds: 15));
  if (reply.statusCode != 200) {
    throw UpdateException(l10nNow.updateHttpFailed(reply.statusCode));
  }
  final fragment = html.parseFragment(utf8.decode(reply.bodyBytes));
  final assets = <Map<String, dynamic>>[];
  for (final row in fragment.querySelectorAll('li')) {
    final href = row.querySelector('a[href]')?.attributes['href'];
    final digest = row
        .querySelector('clipboard-copy[value^="sha256:"]')
        ?.attributes['value'];
    if (href == null || digest == null) continue;
    final uri = url.resolve(href);
    if (uri.pathSegments.isNotEmpty) {
      assets.add({
        'name': uri.pathSegments.last,
        'browser_download_url': uri.toString(),
        'digest': digest,
      });
    }
  }
  final package = WindowsReleasePackage.pick(tag, assets);
  if (package == null || package.sha256 == null) {
    throw UpdateException(l10nNow.updatePackageMissing);
  }
  return package;
}

Future<DownloadedUpdate> downloadWindowsUpdate(
  GithubRelease release, {
  required http.Client client,
  required void Function(int received, int? total) onProgress,
  Directory? tempRoot,
}) async {
  final package = await _releasePackage(release, client);
  final response = await client
      .send(http.Request('GET', package.url))
      .timeout(const Duration(seconds: 25));
  if (response.statusCode != 200) {
    throw UpdateException(l10nNow.updateHttpFailed(response.statusCode));
  }
  final directory = await (tempRoot ?? Directory.systemTemp).createTemp(
    'plana-update-',
  );
  final file = File.fromUri(directory.uri.resolve(package.name));
  final update = DownloadedUpdate._(package, file);
  try {
    final total = package.size ?? response.contentLength;
    var received = 0;
    final sink = file.openWrite();
    try {
      await sink.addStream(
        response.stream.timeout(const Duration(seconds: 30)).map((chunk) {
          received += chunk.length;
          if (total != null && received > total) {
            throw UpdateException(l10nNow.updateIntegrityFailed);
          }
          onProgress(received, total);
          return chunk;
        }),
      );
    } finally {
      await sink.close();
    }
    if (received == 0 ||
        (total != null && received != total) ||
        (await crypto.sha256.bind(file.openRead()).first).toString() !=
            package.sha256) {
      throw UpdateException(l10nNow.updateIntegrityFailed);
    }
    return update;
  } catch (_) {
    await update.discard();
    rethrow;
  }
}
