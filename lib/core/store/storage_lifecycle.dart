import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart';

import '../util/runtime_diagnostics.dart';
import 'app_stores.dart';

/// Commit editor drafts before flushing, and let desktop exit only after the
/// storage queues finish. Background transitions still start an immediate save.
AppLifecycleListener createStorageLifecycleListener(
  AppStores stores, {
  VoidCallback? beforeFlush,
  Future<bool> Function()? beforeExit,
}) {
  Future<AppExitResponse>? pending;
  Future<AppExitResponse> exitRequest() async {
    try {
      beforeFlush?.call();
      await stores.flushForExit();
      if (beforeExit != null && !await beforeExit()) {
        return AppExitResponse.cancel;
      }
      RuntimeDiagnostics.current?.event('exit-storage-flushed');
      return AppExitResponse.exit;
    } catch (error, stack) {
      RuntimeDiagnostics.current?.error('exit-storage-failed', error, stack);
      stores.reportSaveError('保存未完成，应用已保留打开，请检查磁盘后重试');
      return AppExitResponse.cancel;
    }
  }

  return AppLifecycleListener(
    onStateChange: (state) {
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused) {
        beforeFlush?.call();
        stores.flushNow();
      }
    },
    onExitRequested: () =>
        pending ??= exitRequest().whenComplete(() => pending = null),
  );
}
