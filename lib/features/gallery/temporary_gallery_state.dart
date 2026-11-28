import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/platform/desktop.dart';
import '../../core/store/app_stores.dart';
import '../generate/canvas_state.dart';
import 'albums/album_state.dart';
import 'gallery_state.dart';
import 'models.dart';

enum TemporaryExitAction { ask, clean, zipThenClean }

class TemporaryGalleryOptions {
  const TemporaryGalleryOptions({
    this.collectSaved = true,
    this.temporaryForNewCanvases = false,
    this.exitAction = TemporaryExitAction.ask,
    this.lastKeepCount = 20,
    this.lastHistoryCount = 30,
    this.keepRecent = 0,
    this.initialHistory = 30,
    this.canvases = const {},
  });
  final bool collectSaved;
  final bool temporaryForNewCanvases;
  final TemporaryExitAction exitAction;
  final int lastKeepCount, lastHistoryCount;
  final int keepRecent, initialHistory;
  final Set<String> canvases;
}

final temporaryOptionsProvider =
    NotifierProvider<TemporaryOptionsNotifier, TemporaryGalleryOptions>(
      TemporaryOptionsNotifier.new,
    );

class TemporaryOptionsNotifier extends Notifier<TemporaryGalleryOptions> {
  static const _key = 'temporary_gallery_options';
  @override
  TemporaryGalleryOptions build() {
    try {
      final data =
          jsonDecode(ref.read(prefsStoreProvider).get(_key) ?? '{}') as Map;
      int number(String key, int fallback) =>
          data[key] is int && data[key] >= 0 ? data[key] as int : fallback;
      final keep = number('keepRecent', 0);
      final history = number('initialHistory', 30);
      int lastCount(String key, int fallback) {
        final n = number(key, fallback);
        return n > 0 ? n : fallback;
      }

      final storedAction = data['exitAction'];
      final action = TemporaryExitAction.values
          .where((value) => value.name == storedAction)
          .firstOrNull;
      return TemporaryGalleryOptions(
        collectSaved: data['collectSaved'] != false,
        temporaryForNewCanvases: data['temporaryForNewCanvases'] == true,
        exitAction:
            action ??
            (storedAction == null && data['confirmExit'] == false
                ? TemporaryExitAction.clean
                : TemporaryExitAction.ask),
        keepRecent: keep,
        initialHistory: history,
        lastKeepCount: keep > 0 ? keep : lastCount('lastKeepCount', 20),
        lastHistoryCount: history > 0
            ? history
            : lastCount('lastHistoryCount', 30),
        canvases: Set.of((data['canvases'] as List? ?? []).whereType<String>()),
      );
    } on FormatException {
      return const TemporaryGalleryOptions();
    } on TypeError {
      return const TemporaryGalleryOptions();
    }
  }

  void update({
    bool? collectSaved,
    bool? temporaryForNewCanvases,
    TemporaryExitAction? exitAction,
    int? keepRecent,
    int? initialHistory,
    Set<String>? canvases,
  }) {
    state = TemporaryGalleryOptions(
      collectSaved: collectSaved ?? state.collectSaved,
      temporaryForNewCanvases:
          temporaryForNewCanvases ?? state.temporaryForNewCanvases,
      exitAction: exitAction ?? state.exitAction,
      lastKeepCount: keepRecent != null && keepRecent > 0
          ? keepRecent
          : state.lastKeepCount,
      lastHistoryCount: initialHistory != null && initialHistory > 0
          ? initialHistory
          : state.lastHistoryCount,
      keepRecent: keepRecent ?? state.keepRecent,
      initialHistory: initialHistory ?? state.initialHistory,
      canvases: canvases ?? state.canvases,
    );
    unawaited(
      ref
          .read(prefsStoreProvider)
          .write(
            key: _key,
            value: jsonEncode({
              'collectSaved': state.collectSaved,
              'temporaryForNewCanvases': state.temporaryForNewCanvases,
              'exitAction': state.exitAction.name,
              'lastKeepCount': state.lastKeepCount,
              'lastHistoryCount': state.lastHistoryCount,
              'keepRecent': state.keepRecent,
              'initialHistory': state.initialHistory,
              'canvases': state.canvases.toList(),
            }),
          ),
    );
  }

  void choose(String canvas, bool temporary) {
    if (state.canvases.contains(canvas) == temporary) return;
    final next = Set.of(state.canvases);
    if (temporary) {
      next.add(canvas);
    } else {
      next.remove(canvas);
    }
    update(canvases: next);
  }
}

final temporaryCanvasProvider = Provider<String?>((ref) {
  if (!ref.watch(desktopModeProvider)) return null;
  final canvas = ref.watch(canvasWorkspaceProvider.select((w) => w.activeId));
  return ref.watch(
        temporaryOptionsProvider.select((o) => o.canvases.contains(canvas)),
      )
      ? canvas
      : null;
});

final temporaryReadyProvider = FutureProvider.autoDispose.family<void, String>(
  (ref, canvas) =>
      ref.watch(appStoresProvider).temporaryGallery.open(canvas: canvas),
);
final temporaryRevisionProvider = NotifierProvider<TemporaryRevision, int>(
  TemporaryRevision.new,
);

class TemporaryRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(appStoresProvider).temporaryGallery;
    void changed() => state++;
    store.addListener(changed);
    ref.onDispose(() => store.removeListener(changed));
    return 0;
  }
}

Provider<GalleryState> creationGalleryFor(String? canvas) =>
    canvas == null ? galleryViewProvider : _temporaryView(canvas);

final _temporaryView = Provider.autoDispose.family<GalleryState, String>((
  ref,
  canvas,
) {
  ref.watch(temporaryReadyProvider(canvas));
  ref.watch(temporaryRevisionProvider);
  final store = ref.read(appStoresProvider).temporaryGallery;
  final images = store.images(canvas);
  return GalleryState(
    results: images,
    selectedId: store.selected(canvas) ?? images.firstOrNull?.id,
  );
});

/// Only rows present on entry can be hidden. Newly generated images accumulate
/// until the user changes libraries or starts a new session.
class InitialHistoryWindow {
  String? _scope;
  int _limit = -1;
  final _hidden = <String>{};
  List<ResultImage>? _last, _visible;
  List<ResultImage> visible(String scope, int limit, List<ResultImage> images) {
    if (scope != _scope || limit != _limit) {
      _scope = scope;
      _limit = limit;
      _hidden.clear();
      if (limit > 0) _hidden.addAll(images.skip(limit).map((r) => r.id));
      _last = null;
    }
    if (_hidden.isEmpty) return images;
    if (!identical(_last, images)) {
      _last = images;
      _visible = [
        for (final r in images)
          if (!_hidden.contains(r.id)) r,
      ];
    }
    return _visible!;
  }

  void more(List<ResultImage> images) {
    _hidden.removeAll(
      images
          .where((r) => _hidden.contains(r.id))
          .take(_limit)
          .map((r) => r.id)
          .toList(),
    );
    _last = null;
  }
}
