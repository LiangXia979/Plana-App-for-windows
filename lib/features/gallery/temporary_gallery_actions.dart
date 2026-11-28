import '../../l10n/l10n.dart';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/store/app_stores.dart';
import '../desktop/desktop_library_picker.dart';
import '../generate/canvas_state.dart';
import '../generate/gen_queue.dart';
import '../generate/generation_controller.dart';
import '../generate/loop_controller.dart';
import '../generate/widgets/common.dart' show hintSnack;
import 'desktop_image_save.dart';
import 'gallery_state.dart';
import 'models.dart';
import 'save_settings.dart';
import 'temporary_gallery_exit_dialog.dart';
import 'temporary_gallery_export.dart';
import 'temporary_gallery_state.dart';

Future<List<File>?> packTemporaryGallery(
  BuildContext context,
  ProviderContainer container, {
  Iterable<String>? canvases,
  bool recoveredOnly = false,
  Set<String>? imageIds,
}) async {
  var directory = container.read(desktopSaveDirectoryProvider);
  if (directory == null) {
    directory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: context.l10n.temporaryFolder,
    );
    if (directory == null || !context.mounted) return null;
    await container
        .read(desktopSaveDirectoryProvider.notifier)
        .select(directory);
  }
  final names = {
    for (final c in container.read(canvasWorkspaceProvider).canvases)
      c.id: c.name,
  };
  final settings = await container.read(saveSettingsProvider.future);
  if (!context.mounted) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = ValueNotifier((done: 0, total: 0));
  bool cancelled = false;
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialog) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(context.l10n.temporaryPacking),
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (context, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: v.total == 0 ? null : v.done / v.total,
              ),
              const SizedBox(height: 10),
              Text(context.l10n.loopImageOf(v.done, v.total)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled = true,
            child: Text(context.l10n.temporaryCancelPack),
          ),
        ],
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    final archives = await exportTemporaryArchives(
      container.read(appStoresProvider).temporaryGallery,
      Directory(directory),
      settings,
      canvases: canvases,
      recoveredOnly: recoveredOnly,
      imageIds: imageIds,
      names: names,
      onProgress: (done, total) {
        progress.value = (done: done, total: total);
        return !cancelled;
      },
    );
    return archives.isEmpty ? null : archives;
  } finally {
    if (route.isActive) navigator.removeRoute(route);
    progress.dispose();
  }
}

Future<bool> closeTemporaryGallery(
  BuildContext context, {
  String? canvas,
  Future<bool> Function()? confirmEmpty,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final store = container.read(appStoresProvider).temporaryGallery;
  final options = container.read(temporaryOptionsProvider);
  bool affected(String? id) => id != null && (canvas == null || id == canvas);
  bool busy() =>
      store.hasActivity(canvas) ||
      container
          .read(generationProvider)
          .jobs
          .any((j) => affected(j.galleryTarget.canvasId)) ||
      container
          .read(genQueueProvider)
          .items
          .any((j) => affected(j.galleryTarget.canvasId)) ||
      affected(container.read(loopStatusProvider).temporaryCanvas);
  if (busy()) {
    hintSnack(context, context.l10n.temporaryBusy);
    return false;
  }
  if (canvas == null && !store.used) {
    await store.abandon();
    return true;
  }
  if (canvas != null && !store.used && !store.root.existsSync()) {
    return confirmEmpty == null || await confirmEmpty();
  }
  if (store.closing || !context.mounted) return false;
  store.closing = true;
  try {
    await store.open(markUsed: false);
    await store.idle;
    final groups = canvas == null
        ? store.canvases.intersection(store.visitedCanvases)
        : {canvas};
    final expected = store.snapshot(groups);
    final keep = canvas == null ? options.keepRecent : 0;
    final workspace = container.read(canvasWorkspaceProvider);
    final counts = <TemporaryCanvasCounts>[];
    for (final id in groups) {
      final images = store.images(id);
      if (images.isEmpty) continue;
      final collected = images.where((r) => store.isPromoted(r.id)).length;
      final removing = store.pendingDeletion(keep, canvas: id);
      counts.add((
        name: workspace.find(id)?.name ?? store.nameOf(id),
        collected: collected,
        removing: removing,
        kept: images.length - collected - removing,
      ));
    }
    final shouldClean = counts.any((c) => c.removing > 0);
    var action = canvas == null ? options.exitAction : TemporaryExitAction.ask;
    var remember = false;
    if (!shouldClean && confirmEmpty != null && !await confirmEmpty()) {
      return false;
    }
    if (shouldClean) {
      if (!context.mounted) return false;
      if (action == TemporaryExitAction.ask) {
        final decision = await showDialog<TemporaryExitDecision>(
          context: context,
          builder: (_) => TemporaryGalleryExitDialog(
            canvases: counts,
            deletingCanvas: canvas != null,
          ),
        );
        if (decision == null || !context.mounted) return false;
        action = decision.action;
        remember = decision.remember;
      }
      if (action == TemporaryExitAction.zipThenClean &&
          await packTemporaryGallery(context, container, canvases: groups) ==
              null) {
        return false;
      }
    }
    if (busy()) return false;
    await store.finish(
      keep: keep,
      canvas: canvas,
      exit: canvas == null,
      onlyCanvases: groups,
      expected: expected,
    );
    final notifier = container.read(temporaryOptionsProvider.notifier);
    if (remember && canvas == null) notifier.update(exitAction: action);
    if (canvas != null) notifier.choose(canvas, false);
    await container.read(appStoresProvider).prefs.idle;
    return true;
  } catch (error) {
    if (context.mounted) {
      hintSnack(
        context,
        context.l10n.temporaryCleanupFailed(error.toString()),
        icon: Icons.error_outline,
      );
    }
    return false;
  } finally {
    store.closing = false;
  }
}

/// Actions on the current temporary selection stay available even when only
/// the first page of historical thumbnails has been loaded.
class TemporaryFilmActions extends ConsumerStatefulWidget {
  const TemporaryFilmActions({
    super.key,
    required this.canvas,
    required this.image,
    required this.compactZip,
    this.batchMenu,
    required this.builder,
  });
  final String canvas;
  final ResultImage image;
  final bool compactZip;
  final Widget? batchMenu;
  final Widget Function(Widget archive, Widget imageActions) builder;
  @override
  ConsumerState<TemporaryFilmActions> createState() =>
      _TemporaryFilmActionsState();
}

class _TemporaryFilmActionsState extends ConsumerState<TemporaryFilmActions> {
  bool working = false;
  Future<void> _run(Future<void> Function() action) async {
    if (working) return;
    setState(() => working = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        hintSnack(context, context.l10n.temporaryActionFailed(e.toString()));
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    final iconStyle = IconButton.styleFrom(
      minimumSize: const Size(30, 32),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      iconSize: 18,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final imageActions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('temporary-film-star'),
          style: iconStyle,
          tooltip: image.favorite
              ? context.l10n.unfavorite
              : context.l10n.temporaryStar,
          icon: Icon(image.favorite ? Icons.star : Icons.star_border),
          onPressed: working
              ? null
              : () => _run(
                  () => ref
                      .read(galleryProvider.notifier)
                      .retainTemporary(image.id, favorite: !image.favorite),
                ),
        ),
        IconButton(
          key: const ValueKey('temporary-film-file'),
          style: iconStyle,
          tooltip: context.l10n.temporaryFile,
          icon: const Icon(Icons.create_new_folder_outlined),
          onPressed: working
              ? null
              : () => _run(() async {
                  final choice = await showLibraryChoiceDialog(context);
                  if (choice == null || !mounted) return;
                  await ref
                      .read(galleryProvider.notifier)
                      .retainTemporary(
                        image.id,
                        destination: choice.capture(DateTime.now()),
                      );
                  if (context.mounted) {
                    hintSnack(context, context.l10n.temporaryFiled);
                  }
                }),
        ),
      ],
    );
    final label = context.l10n.packZip;
    final archive = Tooltip(
      message: label,
      child: OutlinedButton(
        key: const ValueKey('temporary-film-zip'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(32, 32),
          shape: widget.batchMenu == null
              ? null
              : const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(16),
                  ),
                ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.symmetric(horizontal: widget.compactZip ? 7 : 10),
          visualDensity: VisualDensity.compact,
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        onPressed: working
            ? null
            : () => _run(() async {
                final files = await packTemporaryGallery(
                  context,
                  ProviderScope.containerOf(context, listen: false),
                  canvases: [widget.canvas],
                );
                if (context.mounted && files != null && files.isNotEmpty) {
                  hintSnack(
                    context,
                    context.l10n.temporarySavedPath(files.first.path),
                  );
                }
              }),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_zip_outlined, size: 16),
            if (!widget.compactZip) ...[const SizedBox(width: 5), Text(label)],
          ],
        ),
      ),
    );
    return widget.builder(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [archive, ?widget.batchMenu],
      ),
      imageActions,
    );
  }
}

class TemporaryRecoveryBanner extends ConsumerStatefulWidget {
  const TemporaryRecoveryBanner({super.key});
  @override
  ConsumerState<TemporaryRecoveryBanner> createState() =>
      _TemporaryRecoveryBannerState();
}

class _TemporaryRecoveryBannerState
    extends ConsumerState<TemporaryRecoveryBanner> {
  bool working = false;
  Future<void> handle(bool export) async {
    if (working) return;
    setState(() => working = true);
    final container = ProviderScope.containerOf(context, listen: false);
    final store = container.read(appStoresProvider).temporaryGallery;
    final groups = store.recoveredCanvases;
    try {
      if (export) {
        final files = await packTemporaryGallery(
          context,
          container,
          canvases: groups,
          recoveredOnly: true,
        );
        if (mounted && files != null) {
          hintSnack(context, context.l10n.temporaryPacked(files.length));
        }
      } else {
        final ok = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(context.l10n.temporaryRecoveryQuestion),
            content: Text(context.l10n.temporaryRecoveryHint),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(context.l10n.actClean),
              ),
            ],
          ),
        );
        if (ok == true) await store.finish(keep: 0, recoveredOnly: true);
      }
    } catch (e) {
      if (mounted) {
        hintSnack(context, context.l10n.temporaryActionFailed(e.toString()));
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(temporaryRevisionProvider);
    final store = ref.read(appStoresProvider).temporaryGallery;
    final count = store.recoveredCanvases.fold<int>(
      0,
      (sum, c) => sum + store.recoveredImages(c).length,
    );
    if (count == 0) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(context.l10n.temporaryRecovered(count)),
          TextButton(
            onPressed: working ? null : () => handle(true),
            child: Text(context.l10n.packZip),
          ),
          TextButton(
            onPressed: working ? null : () => handle(false),
            child: Text(context.l10n.temporaryClearAll),
          ),
        ],
      ),
    );
  }
}
