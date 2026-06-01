import 'dart:async';

import 'sidecar_manager.dart';

/// Orchestrates the engine [SidecarManager] across (re)starts and exposes a
/// single, stable lifecycle stream for the UI to gate on (task 6.2 support).
///
/// A [SidecarManager] is effectively one-shot: its [SidecarManager.start] runs
/// the startup sequence once and, on failure, lands in a terminal
/// [SidecarStatus.failed]; recovering means launching a *fresh* manager (per the
/// design's retry/restart edges). [SidecarBootstrap] hides that churn behind:
///
///  * a stable broadcast [status] stream that re-emits the current manager's
///    transitions, surviving manager swaps so the UI's subscription never has
///    to be rebuilt;
///  * [currentStatus] and [capturedStderr] pass-throughs the startup-failure UI
///    reads when rendering (Requirements 3.5, 3.9);
///  * [start] / [restart] entry points that (re)create and launch a manager,
///    used by the engine-stopped **Restart** and failure **Retry** actions
///    (Requirements 3.9, 3.10).
///
/// This wrapper contains zero engine logic — it only consumes the manager's
/// public surface ([SidecarManager.status], [SidecarManager.start],
/// [SidecarManager.stop], [SidecarManager.capturedStderr],
/// [SidecarManager.baseUrl]).
class SidecarBootstrap {
  /// Creates a bootstrap that builds each manager via [createManager]. Defaults
  /// to the production [SidecarManager.new]; tests inject a factory returning a
  /// fully-stubbed manager so no real process is spawned.
  SidecarBootstrap({SidecarManager Function()? createManager})
      : _createManager = createManager ?? SidecarManager.new;

  final SidecarManager Function() _createManager;

  final StreamController<SidecarStatus> _statusController =
      StreamController<SidecarStatus>.broadcast();

  SidecarManager? _manager;
  StreamSubscription<SidecarStatus>? _managerSub;
  SidecarStatus _status = SidecarStatus.selectingPort;

  /// Stable lifecycle stream the UI subscribes to once. Re-emits each manager's
  /// [SidecarStatus] transitions, including across [restart].
  Stream<SidecarStatus> get status => _statusController.stream;

  /// The most recently observed status, used to seed the UI before the first
  /// stream event arrives.
  SidecarStatus get currentStatus => _status;

  /// The current manager's captured stderr (verbatim), or empty when no manager
  /// has been created yet. Read by the startup-failure UI (Requirements 3.5,
  /// 3.9).
  String get capturedStderr => _manager?.capturedStderr ?? '';

  /// The published Base_URL once the engine is ready, else null.
  Uri? get baseUrl {
    if (_status != SidecarStatus.ready) return null;
    return _manager?.baseUrl;
  }

  /// Launches a fresh manager and runs its startup sequence. Any
  /// [SidecarStartException] is swallowed because the failure is already
  /// reflected on the [status] stream (the manager emits [SidecarStatus.failed]
  /// before throwing); the UI reacts to the stream rather than to a thrown
  /// error.
  Future<void> start() async {
    await _disposeCurrentManager();

    final manager = _createManager();
    _manager = manager;
    _managerSub = manager.status.listen((next) {
      _status = next;
      if (!_statusController.isClosed) {
        _statusController.add(next);
      }
    });

    try {
      await manager.start();
    } on SidecarStartException {
      // Expected on startup failure / exhausted retries — already surfaced via
      // the status stream (Requirements 3.5, 3.9).
    } catch (_) {
      // Defensive: any other launch error is reflected by the manager's status;
      // never let it escape and crash the app shell.
    }
  }

  /// Re-initiates startup after a failure or an unexpected engine stop. Tears
  /// down the previous manager (and its process) before launching a new one.
  Future<void> restart() => start();

  /// Tears down the bootstrap and any live manager. Call on app shutdown.
  Future<void> dispose() async {
    await _disposeCurrentManager();
    await _statusController.close();
  }

  Future<void> _disposeCurrentManager() async {
    // Detach our listener first so the old manager's shutdown transitions
    // ([SidecarStatus.stopped]) don't leak onto the stable stream and confuse
    // the UI mid-restart.
    await _managerSub?.cancel();
    _managerSub = null;

    final manager = _manager;
    _manager = null;
    if (manager != null) {
      await manager.stop();
      await manager.dispose();
    }
  }
}
