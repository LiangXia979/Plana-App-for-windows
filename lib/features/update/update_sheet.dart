import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_info.dart';
import '../../core/theme/app_theme.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../profile/widgets/settings_ui.dart';
import 'update_service.dart';
import 'windows_update_download.dart';
import '../../l10n/l10n.dart';

/// 「检查更新」行。放在关于页,按设置行规范:单行 + 右侧状态,不写副标题。
class UpdateRow extends ConsumerStatefulWidget {
  const UpdateRow({super.key});

  @override
  ConsumerState<UpdateRow> createState() => _UpdateRowState();
}

class _UpdateRowState extends ConsumerState<UpdateRow> {
  bool _checking = false;
  UpdateCheck? _result;
  bool _failed = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _failed = false;
      _result = null;
    });
    try {
      final service = ref.read(updateServiceProvider);
      final check = await service.check();
      final installed = check.installed;
      if (!mounted) return;
      setState(() => _result = check);
      if (check.hasUpdate) {
        await showUpdateSheet(context, check, service);
      } else if (kGithubRepo.isEmpty || !installed.isKnown) {
        // 没填仓库 / 拿不到本机版本 —— 不是错误,别报红
        hintSnack(context, context.l10n.noUpdateInfo, icon: Icons.info_outline);
      } else {
        hintSnack(
          context,
          context.l10n.onLatestVersion,
          icon: Icons.check_circle_outline,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
      hintSnack(context, '$e', icon: Icons.error_outline);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    final r = _result;
    final (String value, Color? color) = switch (null) {
      _ when _checking => (context.l10n.checking, null),
      _ when _failed => (context.l10n.checkFailed, scheme.error),
      _ when r != null && r.hasUpdate => (
        context.l10n.newVersion(r.release!.display),
        scheme.tertiary,
      ),
      _ when r != null && (!r.installed.isKnown || kGithubRepo.isEmpty) => (
        context.l10n.noUpdateInfo,
        null,
      ),
      _ when r != null => (context.l10n.upToDate, null),
      _ => ('', null),
    };
    return SettingsRow(
      icon: Icons.system_update_alt,
      title: context.l10n.checkUpdates,
      value: value,
      valueColor: color,
      onTap: _check,
    );
  }
}

Future<void> showUpdateSheet(
  BuildContext context,
  UpdateCheck check,
  UpdateService service, {
  bool automatic = false,
}) async {
  final release = check.release;
  if (release == null ||
      !service.beginNotice(release.tag, automatic: automatic)) {
    return;
  }
  try {
    final dismissed = defaultTargetPlatform == TargetPlatform.windows
        ? showDialog<void>(
            context: context,
            builder: (_) => _WindowsUpdateDialog(
              release: release,
              installed: check.installed,
            ),
          )
        : showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) =>
                _UpdateSheet(release: release, installed: check.installed),
          );
    await service.rememberNotice(release.tag);
    await dismissed;
  } finally {
    service.endNotice();
  }
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.release, required this.installed});

  final GithubRelease release;
  final InstalledInfo installed;

  Future<void> _open(BuildContext context, Uri url) async {
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!context.mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      hintSnack(
        context,
        context.l10n.cantOpenBrowserShort,
        icon: Icons.link_off,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.scheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update_alt,
                    size: 26,
                    color: scheme.tertiary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.newVersion(release.display),
                          style: context.texts.titleMedium!.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          context.l10n.currentVersion(installed.versionName),
                          style: context.texts.bodySmall!.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  // 更新说明是 GitHub 上的 Markdown 原文,长度不可控 —— 限高可滚,
                  // 不能让它把按钮顶出屏幕
                  constraints: const BoxConstraints(maxHeight: 260),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      release.notes,
                      style: context.texts.bodySmall!.copyWith(height: 1.55),
                    ),
                  ),
                ),
              ],
              if (release.windowsDownload != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => _open(context, Uri.parse(release.url)),
                    child: Text(context.l10n.downloadOnGithub),
                  ),
                ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.l10n.later),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: () => _open(
                        context,
                        release.windowsDownload ?? Uri.parse(release.url),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(
                        release.windowsDownload == null
                            ? context.l10n.downloadOnGithub
                            : context.l10n.downloadWindowsPackage,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowsUpdateDialog extends StatefulWidget {
  const _WindowsUpdateDialog({required this.release, required this.installed});
  final GithubRelease release;
  final InstalledInfo installed;

  @override
  State<_WindowsUpdateDialog> createState() => _WindowsUpdateDialogState();
}

class _WindowsUpdateDialogState extends State<_WindowsUpdateDialog> {
  http.Client? _client;
  DownloadedUpdate? _ready;
  double? _progress;
  String? _error;
  bool _opening = false;

  Future<void> _download() async {
    if (_client != null) return;
    final client = http.Client();
    setState(() {
      _client = client;
      _error = null;
      _progress = null;
    });
    try {
      final update = await downloadWindowsUpdate(
        widget.release,
        client: client,
        onProgress: (received, total) {
          final progress = total != null && total > 0
              ? (received * 100 ~/ total) / 100
              : null;
          if (mounted && progress != _progress) {
            setState(() => _progress = progress);
          }
        },
      );
      if (!mounted) {
        await update.discard();
        return;
      }
      setState(() => _ready = update);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is UpdateException
              ? error.message
              : context.l10n.updateDownloadFailed,
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _client = null);
    }
  }

  Future<void> _openPackage() async {
    final update = _ready;
    if (update == null || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      await update.open();
      // The installer or the user opening a portable package now owns the file.
      _ready = null;
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted || error is UpdateException) {
        _ready = null;
        await update.discard();
      }
      if (mounted) {
        setState(
          () => _error = error is UpdateException
              ? error.message
              : context.l10n.updateLaunchFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _openReleasePage() async {
    try {
      if (await launchUrl(
        Uri.parse(widget.release.url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {}
    if (mounted) setState(() => _error = context.l10n.cantOpenBrowserShort);
  }

  @override
  void dispose() {
    _client?.close();
    final ready = _ready;
    if (ready != null && !_opening) unawaited(ready.discard());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final release = widget.release;
    final busy = _client != null;
    final ready = _ready;
    return AlertDialog(
      key: const ValueKey('windows-update-dialog'),
      title: Row(
        children: [
          Icon(Icons.system_update_alt, color: context.scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(l.newVersion(release.tag))),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.currentVersion(widget.installed.versionName),
              style: context.texts.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(l.updateReleaseNotes, style: context.texts.titleSmall),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  release.notes.trim().isEmpty
                      ? l.updateNotesUnavailable
                      : release.notes,
                  style: context.texts.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ),
            if (busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 4),
              Text(l.updateDownloading, style: context.texts.bodySmall),
            ],
            if (_error case final message?) ...[
              const SizedBox(height: 10),
              Text(
                message,
                style: context.texts.bodySmall?.copyWith(
                  color: context.scheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _openReleasePage,
          child: Text(l.updateReleasePage),
        ),
        TextButton(
          onPressed: _opening ? null : () => Navigator.pop(context),
          child: Text(busy ? l.cancel : l.later),
        ),
        FilledButton.icon(
          onPressed: busy || _opening
              ? null
              : ready == null
              ? _download
              : _openPackage,
          icon: Icon(
            ready == null ? Icons.download_outlined : Icons.open_in_new,
            size: 18,
          ),
          label: Text(
            ready == null
                ? l.updateDownload
                : ready.package.isInstaller
                ? l.updateRunInstaller
                : l.updateOpenPackageFolder,
          ),
        ),
      ],
    );
  }
}
