import '../../../l10n/l10n.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/store/app_stores.dart';
import '../../generate/widgets/common.dart' show hintSnack;
import '../gallery_output_folder.dart';
import 'gallery_toolbar_button.dart';

/// The archive folder is shared by the library overview and its image browser.
class GalleryOutputFolderButton extends ConsumerStatefulWidget {
  const GalleryOutputFolderButton({super.key, this.albumId});
  final String? albumId;

  @override
  ConsumerState<GalleryOutputFolderButton> createState() =>
      _GalleryOutputFolderButtonState();
}

class _GalleryOutputFolderButtonState
    extends ConsumerState<GalleryOutputFolderButton> {
  bool get _visible => TickerMode.getValuesNotifier(context).value.enabled;

  Future<void> _open() async {
    final store = ref.read(appStoresProvider).desktopOutput;
    final albumId = widget.albumId;
    try {
      await ref
          .read(galleryOutputFolderProvider.notifier)
          .open(albumId: albumId);
      if (mounted && _visible && store.lastMigration?.hasErrors == true) {
        hintSnack(
          context,
          l10nNow.desktopSomeOlderImagesAreStillInTheirOriginal,
        );
      }
    } on TimeoutException {
      if (mounted && _visible) {
        hintSnack(
          context,
          l10nNow.desktopOpeningTheImagesFolderTimedOutTryAgain,
        );
      }
    } catch (_) {
      if (mounted && _visible) {
        hintSnack(
          context,
          '无法打开作品文件夹，请检查目录是否可用：${store.browseFolder(albumId).path}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final opening = ref.watch(galleryOutputFolderProvider);
    return Tooltip(
      message:
          '自动保存：${ref.watch(appStoresProvider).desktopOutput.browseFolder(widget.albumId).path}',
      child: GalleryToolbarButton(
        key: const ValueKey('desktop-gallery-folder'),
        onPressed: opening ? null : _open,
        icon: Icons.folder_open_outlined,
        label: opening ? '正在打开…' : '作品文件夹',
      ),
    );
  }
}
