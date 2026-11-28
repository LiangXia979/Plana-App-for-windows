import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../l10n/l10n.dart';
import '../gallery/albums/album_state.dart';
import '../gallery/albums/album_ui.dart' show AlbumCoverImage, showAlbumName;
import '../gallery/albums/album_models.dart';
import 'desktop_album_menu.dart';
import '../gallery/temporary_gallery.dart';
import '../gallery/temporary_gallery_state.dart';
import '../generate/canvas_state.dart';
import '../../core/store/app_stores.dart';
import 'desktop_library_state.dart';

Future<DesktopLibrarySelection?> showLibraryChoiceDialog(
  BuildContext context, {
  bool allowTemporary = false,
  DesktopLibrarySelection? initialSelection,
  bool browseOnly = false,
  String? browseAlbumId,
}) => showDialog<DesktopLibrarySelection>(
  context: context,
  builder: (_) => _DesktopLibraryPicker(
    allowTemporary: allowTemporary,
    initialSelection: initialSelection,
    browseOnly: browseOnly,
    browseAlbumId: browseAlbumId,
  ),
);

class _DesktopLibraryPicker extends ConsumerStatefulWidget {
  const _DesktopLibraryPicker({
    required this.allowTemporary,
    required this.initialSelection,
    required this.browseOnly,
    required this.browseAlbumId,
  });

  final bool allowTemporary;
  final DesktopLibrarySelection? initialSelection;
  final bool browseOnly;
  final String? browseAlbumId;

  @override
  ConsumerState<_DesktopLibraryPicker> createState() =>
      _DesktopLibraryPickerState();
}

class _DesktopLibraryPickerState extends ConsumerState<_DesktopLibraryPicker> {
  final _albumMenu = DesktopAlbumMenuController();

  void _choose(String choice) => Navigator.pop(
    context,
    DesktopLibrarySelection(choice: choice, day: desktopDayKey(DateTime.now())),
  );

  @override
  Widget build(BuildContext context) {
    final albums = ref.watch(albumsProvider);
    final counts = ref.watch(albumSummariesProvider);
    final selection = widget.browseOnly
        ? null
        : widget.initialSelection ?? ref.watch(desktopLibraryProvider);
    final temp =
        widget.allowTemporary && ref.watch(temporaryCanvasProvider) != null;
    final activeChoice = temp
        ? temporaryLibraryId
        : selection?.choice ?? widget.browseAlbumId ?? '';
    final temporaryCount = widget.allowTemporary
        ? ref
              .read(appStoresProvider)
              .temporaryGallery
              .images(
                ref.watch(canvasWorkspaceProvider.select((w) => w.activeId)),
              )
              .length
        : 0;
    final choices = [
      if (selection != null)
        (
          id: 'auto',
          name: '按日期自动',
          detail: selection.day,
          scope: 'day_${selection.day}',
        ),
      (id: '', name: allPhotosName, detail: '查看所有图片', scope: null),
      if (widget.allowTemporary)
        (
          id: temporaryLibraryId,
          name: context.l10n.temporaryName,
          detail: context.l10n.temporaryScope,
          scope: temporaryLibraryId,
        ),
      for (final a in albums.albums)
        (id: a.id, name: a.name, detail: '浏览并保存到这里', scope: a.id),
    ];
    return Dialog(
      child: SizedBox(
        key: const ValueKey('desktop-library-dialog'),
        width: 740,
        height: 540,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10nNow.desktopChooseGallery,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (!widget.browseOnly)
                    TextButton.icon(
                      key: const ValueKey('desktop-new-album'),
                      onPressed: () async {
                        final id = await showAlbumName(context);
                        if (id != null && context.mounted) {
                          _choose(id);
                        }
                      },
                      icon: const Icon(Icons.add, size: 17),
                      label: Text(l10nNow.desktopNewGallery),
                    ),
                  IconButton(
                    tooltip: l10nNow.close,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (!widget.browseOnly) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10nNow.desktopNewImagesAreSavedToTheGalleryYou,
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 205,
                    childAspectRatio: .93,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: choices.length,
                  itemBuilder: (_, i) {
                    final entry = choices[i];
                    final count = entry.id == temporaryLibraryId
                        ? temporaryCount
                        : counts[entry.scope]?.count ?? 0;
                    final active = activeChoice == entry.id;
                    return Material(
                      color: active
                          ? context.scheme.primaryContainer
                          : context.scheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: active
                              ? context.scheme.primary
                              : context.scheme.outlineVariant,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: ValueKey('desktop-album-${entry.id}'),
                        onSecondaryTapDown:
                            widget.browseOnly ||
                                entry.id == 'auto' ||
                                entry.id == temporaryLibraryId
                            ? null
                            : (details) => _albumMenu.show(
                                context,
                                entry.scope,
                                details.globalPosition,
                              ),
                        onTap: () => _choose(entry.id),
                        child: Padding(
                          padding: const EdgeInsets.all(9),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: entry.id == temporaryLibraryId
                                    ? Icon(
                                        Icons.hourglass_empty,
                                        size: 36,
                                        color: context.scheme.primary,
                                      )
                                    : entry.id == 'auto' &&
                                          count == 0 &&
                                          albums.cover(entry.scope) == null
                                    ? Icon(
                                        Icons.calendar_month_outlined,
                                        size: 36,
                                        color: context.scheme.primary,
                                      )
                                    : AlbumCoverImage(albumId: entry.scope),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                widget.browseOnly
                                    ? context.l10n.totalImagesN(count)
                                    : '$count 张 · ${entry.detail}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
