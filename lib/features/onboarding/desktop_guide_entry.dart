import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_mode.dart';
import '../../core/auth/bot_session_store.dart';
import '../../core/auth/token_store.dart';
import '../../core/store/app_stores.dart';
import '../../core/store/gen_settings.dart';
import '../../l10n/l10n.dart';
import '../gallery/desktop_image_save.dart';
import 'welcome_page.dart';

/// A fresh desktop profile can start the guide without blocking the workspace.
class DesktopGuideEntry extends ConsumerStatefulWidget {
  const DesktopGuideEntry({super.key, required this.active});
  final bool active;

  @override
  ConsumerState<DesktopGuideEntry> createState() => _DesktopGuideEntryState();
}

class _DesktopGuideEntryState extends ConsumerState<DesktopGuideEntry> {
  static const _seen = 'desktop_welcome_entry_seen';
  bool _visible = false, _checked = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _check();
  }

  @override
  void didUpdateWidget(DesktopGuideEntry oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _check();
  }

  Future<void> _check() async {
    if (_checked) return;
    final stores = ref.read(appStoresProvider);
    if (stores.prefs.get(_seen) != null ||
        stores.workspace.initial != null ||
        stores.workspace.initialCanvases != null ||
        stores.gallery.initialResults.isNotEmpty ||
        stores.prefs.get(DesktopSaveDirectory.preferenceKey) != null) {
      return;
    }
    _checked = true;
    try {
      final results = await Future.wait([
        ref.read(genSettingsProvider.future).then((s) => s.notifyPrimed),
        ref.read(authModeProvider.future).then((m) => m != null),
        ref
            .read(tokenProvider.future)
            .then((token) => token?.isNotEmpty ?? false),
        ref.read(botSessionProvider.future).then((session) => session != null),
      ]);
      if (!mounted || results.contains(true)) return;
      if (!widget.active) {
        _checked = false;
        return;
      }
      if (stores.prefs.get(_seen) != null) return;
      setState(() => _visible = true);
    } catch (_) {
      // Account storage can be unavailable; the About entry still works.
    }
  }

  void _markSeenAndHide() {
    unawaited(
      ref.read(appStoresProvider).prefs.write(key: _seen, value: '1'),
    );
    setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final l = context.l10n;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(l.guideBanner)),
            TextButton(
              onPressed: () {
                _markSeenAndHide();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const WelcomePage()),
                );
              },
              child: Text(l.guideOpen),
            ),
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonLabel,
              onPressed: _markSeenAndHide,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
