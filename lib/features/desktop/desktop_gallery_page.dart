import '../../l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/gallery_state.dart';
import 'desktop_gallery_browser.dart';
import '../../core/store/app_stores.dart';
import '../generate/canvas_state.dart';
import '../gallery/temporary_gallery.dart';
import '../gallery/temporary_gallery_state.dart';
import '../gallery/widgets/gallery_grid_sheet.dart';
import '../generate/generation_controller.dart';
import '../generate/widgets/common.dart' show hintSnack;
import '../inpaint/inpaint_overlay.dart' show inpaintSessionProvider;
import '../shell/shell_state.dart';
import 'desktop_library_picker.dart';
import 'desktop_library_state.dart';

void returnToDesktopCreation(WidgetRef ref) =>
    ref.read(shellIndexProvider.notifier).select(kTabCreate);

void openDesktopGallery(WidgetRef ref, {bool currentLibrary = false}) {
  ref.read(desktopLibraryProvider.notifier).refreshDay();
  ref
      .read(desktopGalleryLocationProvider.notifier)
      .open(
        currentLibrary ? ref.read(desktopLibraryProvider).albumId : null,
        overview: !currentLibrary,
      );
  ref.read(shellIndexProvider.notifier).select(kTabGallery);
}

Future<void> showDesktopLibraryPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  if (ref.read(inpaintSessionProvider) != null) {
    hintSnack(context, l10nNow.desktopFinishInpaintingToSwitchGalleries);
    return;
  }
  final canvas = ref.read(canvasWorkspaceProvider).activeId;
  final choice = await showLibraryChoiceDialog(context, allowTemporary: true);
  if (choice == null || !context.mounted) return;
  if (canvas != ref.read(canvasWorkspaceProvider).activeId) return;
  if (choice.choice == temporaryLibraryId) {
    await setDesktopCanvasGalleryMode(context, ref, canvas, temporary: true);
    return;
  }
  ref.read(temporaryOptionsProvider.notifier).choose(canvas, false);
  // 浏览别的图库不等于主动改选历史图，保留当前任务的画布跟随。
  final following = ref.read(generationProvider).selected != null;
  ref
      .read(desktopLibraryProvider.notifier)
      .choose(choice.albumId, automatic: choice.automatic);
  if (!following) {
    ref.read(generationProvider.notifier).select(null);
    ref.read(galleryResultPreviewProvider.notifier).clear();
    final images = ref.read(galleryViewProvider).results;
    final selected = ref.read(galleryProvider).selectedId;
    if (!images.any((r) => r.id == selected)) {
      ref.read(galleryProvider.notifier).select(images.firstOrNull?.id);
    }
  }
}

/// Change this canvas's pool without replacing the shared standard album.
Future<void> setDesktopCanvasGalleryMode(
  BuildContext context,
  WidgetRef ref,
  String canvas, {
  required bool temporary,
}) async {
  if (canvas != ref.read(canvasWorkspaceProvider).activeId) return;
  if (ref.read(inpaintSessionProvider) != null) {
    hintSnack(context, l10nNow.desktopFinishInpaintingToSwitchGalleries);
    return;
  }
  if (temporary) {
    try {
      await ref.read(appStoresProvider).temporaryGallery.open(canvas: canvas);
    } catch (error) {
      if (context.mounted) {
        hintSnack(context, context.l10n.temporaryOpenFailed(error.toString()));
      }
      return;
    }
    if (!context.mounted ||
        canvas != ref.read(canvasWorkspaceProvider).activeId) {
      return;
    }
  }
  ref.read(temporaryOptionsProvider.notifier).choose(canvas, temporary);
  ref.read(generationProvider.notifier).select(null);
  ref.read(galleryResultPreviewProvider.notifier).clear();
}

class DesktopGalleryPage extends StatelessWidget {
  const DesktopGalleryPage({super.key});
  @override
  Widget build(BuildContext context) => const DesktopGalleryBrowser();
}

class DesktopLibraryButton extends ConsumerWidget {
  const DesktopLibraryButton({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(desktopLibraryProvider);
    final temporary = ref.watch(temporaryCanvasProvider) != null;
    final browseHint =
        '快速浏览与批量导出 · ${desktopLibraryLabel(selection, ref.watch(albumsProvider))}';
    final libraryIcon = Icon(
      temporary
          ? Icons.hourglass_empty
          : selection.automatic
          ? Icons.calendar_month_outlined
          : Icons.photo_library_outlined,
      size: 16,
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final compact =
            bounds.maxWidth <
            (temporary ? 105 : 135) * MediaQuery.textScalerOf(context).scale(1);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (compact)
              IconButton(
                key: const ValueKey('desktop-library-picker'),
                tooltip: l10nNow.desktopSwitchGallery,
                style: IconButton.styleFrom(
                  backgroundColor: context.scheme.primary.withValues(
                    alpha: .08,
                  ),
                  minimumSize: const Size(30, 30),
                  padding: const EdgeInsets.all(5),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => showDesktopLibraryPicker(context, ref),
                icon: libraryIcon,
              )
            else
              Flexible(
                child: TextButton.icon(
                  key: const ValueKey('desktop-library-picker'),
                  style: TextButton.styleFrom(
                    backgroundColor: context.scheme.primary.withValues(
                      alpha: .08,
                    ),
                    shape: const StadiumBorder(),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(0, 36),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => showDesktopLibraryPicker(context, ref),
                  icon: libraryIcon,
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          temporary
                              ? context.l10n.temporaryName
                              : l10nNow.desktopSwitchGallery,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.labelMedium!.copyWith(
                            color: context.scheme.primary,
                          ),
                        ),
                      ),
                      if (temporary) ...[
                        const SizedBox(width: 4),
                        const Icon(Icons.expand_more, size: 14),
                      ],
                    ],
                  ),
                ),
              ),
            if (!temporary)
              IconButton(
                key: const ValueKey('desktop-history-browse'),
                tooltip: browseHint,
                onPressed: () => showGalleryGrid(
                  context,
                  desktop: true,
                  onChooseAlbum: (dialog, gridRef) async {
                    await showDesktopLibraryPicker(dialog, gridRef);
                    if (dialog.mounted &&
                        gridRef.read(temporaryCanvasProvider) != null) {
                      Navigator.of(dialog).pop();
                    }
                  },
                ),
                icon: const Icon(Icons.expand_less, size: 18),
                visualDensity: VisualDensity.compact,
              ),
          ],
        );
      },
    );
  }
}
