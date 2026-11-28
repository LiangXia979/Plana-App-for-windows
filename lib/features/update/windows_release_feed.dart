part of 'update_service.dart';

const _apiCooldownKey = 'update_github_api_retry_at';
const _feedCooldownKey = 'update_github_feed_retry_at';
const _feedCacheKey = 'update_windows_release_feed';

void _checkCooldown(PrefsStore prefs, String key) {
  final until = int.tryParse(prefs.get(key) ?? '') ?? 0;
  if (DateTime.now().millisecondsSinceEpoch < until) {
    throw UpdateException(l10nNow.ghRateLimited);
  }
}

Future<void> _respectRateLimit(
  http.Response response,
  PrefsStore? prefs,
  String key,
) async {
  final headers = response.headers;
  final retry = headers['retry-after'];
  if (response.statusCode != 429 &&
      !(response.statusCode == 403 &&
          (headers['x-ratelimit-remaining'] == '0' ||
              retry != null ||
              response.body.toLowerCase().contains('rate limit')))) {
    return;
  }
  if (prefs != null) {
    final now = DateTime.now();
    var until = now.add(const Duration(minutes: 1));
    if (retry != null) {
      final seconds = int.tryParse(retry);
      try {
        final date = seconds == null
            ? HttpDate.parse(retry)
            : now.add(Duration(seconds: seconds));
        if (date.isAfter(until)) until = date;
      } on FormatException {
        // Some proxies return a header that is neither seconds nor an HTTP date.
      } on HttpException {
        // HttpDate.parse uses HttpException for malformed dates.
      }
    }
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    if (reset != null && reset > until.millisecondsSinceEpoch ~/ 1000) {
      until = DateTime.fromMillisecondsSinceEpoch(reset * 1000);
    }
    await prefs.write(key: key, value: until.millisecondsSinceEpoch.toString());
  }
  throw UpdateException(l10nNow.ghRateLimited);
}

/// The public release feed does not consume GitHub REST API requests. Serve a
/// 304 only with the cached result for the same repository and installed build.
Future<GithubRelease?> _windowsRelease(String current, PrefsStore prefs) async {
  final endpoint = Uri.https('github.com', '/$kGithubRepo/releases.atom');
  Map<String, dynamic>? cached;
  GithubRelease? previous;
  try {
    final value = jsonDecode(prefs.get(_feedCacheKey) ?? 'null');
    if (value is Map<String, dynamic> &&
        value['source'] == endpoint.toString() &&
        value['installed'] == current &&
        value.containsKey('release')) {
      final raw = value['release'];
      previous = raw is Map<String, dynamic>
          ? GithubRelease.fromJson(raw)
          : null;
      if (raw == null || previous != null) cached = value;
    }
  } on FormatException {
    // A damaged or old cache can be refreshed by an unconditional request.
  } on TypeError {
    // Ignore settings saved in an incompatible format.
  }
  Future<void> cacheRelease(GithubRelease? release, {String? etag}) async {
    await prefs.write(
      key: _feedCacheKey,
      value: jsonEncode({
        'source': endpoint.toString(),
        'installed': current,
        'etag': etag,
        'release': release == null
            ? null
            : {
                'tag_name': release.tag,
                'name': release.name,
                'body': release.notes,
                'html_url': release.url,
                'prerelease': release.prerelease,
              },
      }),
    );
  }

  try {
    _checkCooldown(prefs, _feedCooldownKey);
    final etag = cached?['etag'];
    final reply = await http
        .get(
          endpoint,
          headers: {
            'Accept': 'application/atom+xml',
            if (etag is String &&
                etag.isNotEmpty &&
                !etag.contains(RegExp(r'[\r\n]')))
              'If-None-Match': etag,
          },
        )
        .timeout(const Duration(seconds: 8));
    if (reply.statusCode == 304 && cached != null) return previous;
    await _respectRateLimit(reply, prefs, _feedCooldownKey);
    if (reply.statusCode != 200) {
      throw UpdateException(l10nNow.updateHttpFailed(reply.statusCode));
    }
    final release = _parseReleaseFeed(utf8.decode(reply.bodyBytes), current);
    await cacheRelease(release, etag: reply.headers['etag']);
    return release;
  } on Exception {
    try {
      final release = await fetchLatestRelease(current, prefs: prefs);
      await cacheRelease(release);
      return release;
    } on UpdateException {
      // A previously discovered update is still available for a manual reminder.
      // An offline/failed request cannot establish that a build is up to date.
      if (previous != null && compareSemver(previous.tag, current) > 0) {
        return previous;
      }
      rethrow;
    }
  }
}

GithubRelease? _parseReleaseFeed(String source, String current) {
  final root = XmlDocument.parse(source).rootElement;
  if (root.name.local != 'feed') {
    throw const FormatException('Expected Atom feed');
  }
  final releases = <Map<String, dynamic>>[];
  final entries = root.findElements('entry');
  for (final entry in entries) {
    final link = entry
        .findElements('link')
        .where((e) => e.getAttribute('rel') == 'alternate')
        .firstOrNull;
    final url = Uri.tryParse(link?.getAttribute('href') ?? '');
    if (url == null || url.pathSegments.isEmpty) continue;
    final tag = url.pathSegments.last;
    if (!validReleaseTag(tag) ||
        url != Uri.https('github.com', '/$kGithubRepo/releases/tag/$tag')) {
      continue;
    }
    releases.add({
      'tag_name': tag,
      'html_url': url.toString(),
      'name': entry.getElement('title')?.innerText.trim() ?? '',
      // Windows build tags on this repository use -windows.N for public releases.
      'prerelease':
          isPrerelease(tag) && !RegExp(r'-windows\.\d+$').hasMatch(tag),
      'body_html':
          entry.getElement('content')?.innerText ??
          entry.getElement('summary')?.innerText ??
          '',
    });
  }
  if (entries.isNotEmpty && releases.isEmpty) {
    throw const FormatException('No valid release entries');
  }
  return pickNewer(current, releases);
}

String _readReleaseHtml(String markup) {
  final text = StringBuffer();
  void visit(dom.Node node) {
    if (node is dom.Text) {
      text.write(node.data.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    final name = node is dom.Element ? node.localName : null;
    if (name == 'script' || name == 'style') return;
    const blocks = {
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'p',
      'pre',
      'ul',
      'ol',
      'blockquote',
      'div',
      'tr',
    };
    if (blocks.contains(name) || name == 'br' || name == 'li') text.writeln();
    if (name == 'li') text.write('• ');
    for (final child in node.nodes) {
      visit(child);
    }
    if (blocks.contains(name)) text.writeln();
  }

  visit(html.parseFragment(markup));
  return text
      .toString()
      .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
