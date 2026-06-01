/// Owns the Qpic engine **sidecar** process lifecycle (Requirement 3).
///
/// The Flutter app never embeds CPython; instead it launches the unchanged
/// FastAPI engine as a headless child process and drives it over a private
/// localhost port. [SidecarManager] is the single owner of that lifecycle:
///
///   1. **Select a free port** (Req 3.1) — bind a [ServerSocket] to
///      `127.0.0.1:0`, read the OS-assigned ephemeral port (always within
///      1024–65535), then close the socket so the sidecar can bind it.
///   2. **Spawn** (Req 3.2) — `Process.start` the resolved sidecar command
///      (see `paths.dart`'s [resolveSidecarCommand]) with the chosen port, the
///      per-user writable temp dir, and `TESSERACT_CMD` (when set) passed
///      through the environment. stdout/stderr are captured for diagnostics.
///   3. **Wait for health** (Req 3.3) — poll `GET /api/health` every 500 ms
///      until it reports `status == "ok"` or a 30 s startup timeout elapses.
///   4. **Publish Base_URL** (Req 3.4) — on readiness, expose
///      `http://127.0.0.1:{port}` as [baseUrl] and emit [SidecarStatus.ready].
///
/// The **core happy-path lifecycle** (task 5.1) lives alongside the
/// failure/retry/shutdown/unexpected-exit behaviors layered on by task 5.2:
///
///   * **Port-conflict retry (Req 3.8, 3.9)** — if a freshly chosen port is
///     stolen between selection and the sidecar binding it, the engine exits
///     with an "address already in use" error; the manager picks another free
///     port and relaunches, up to [kMaxPortRetries] attempts, then fails.
///   * **Clean shutdown (Req 3.6, 3.7)** — [stop] requests graceful termination
///     (`SIGTERM`), waits [kShutdownGracePeriod], then force-kills (`SIGKILL`
///     on POSIX, `taskkill /F /T` kill-tree on Windows) so no orphan remains.
///   * **App-exit wiring (Req 24.3)** — [installLifecycleHandlers] hooks
///     Flutter's `AppLifecycleState.detached` and `window_manager`'s close
///     intercept so the engine is torn down whichever way the app closes.
///   * **Orphan backstop** — the manager records the child PID in
///     `QPIC_TEMP_DIR/sidecar.pid` and reaps a stale PID (a leftover from a
///     hard crash) on the next launch.
///   * **Unexpected exit (Req 3.10)** — once [SidecarStatus.ready], the
///     process `exitCode` is watched; an unsolicited exit transitions to
///     [SidecarStatus.engineStopped] so the UI can disable itself.
///
/// The state machine (see design "SidecarManager"):
///
/// ```
/// SelectingPort ─▶ Starting ─▶ WaitingHealth ─▶ Ready ─▶ Stopped
///        ▲ │                        │             └────▶ EngineStopped
///        │ └─(port conflict)        └─(30s timeout)─▶ Failed
///        └───(retry ≤3)──────────────────────────────▶ Failed (exhausted)
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'api_client.dart';
import 'paths.dart';

/// Environment variable carrying the localhost port the sidecar must bind.
///
/// `packaging/sidecar.py` reads this as `int(os.environ["QPIC_PORT"])`.
const String kQpicPortEnv = 'QPIC_PORT';

/// Environment variable carrying the per-user writable temp dir (Req 3.11).
///
/// `packaging/sidecar.py` maps it onto the engine's `TEMP_DIR`.
const String kQpicTempDirEnv = 'QPIC_TEMP_DIR';

/// Environment variable for an explicit Tesseract binary path. Forwarded to the
/// sidecar only when set, preserving the engine's `TESSERACT_CMD` → bundled →
/// system → PATH lookup order (Req 1.6, 20).
const String kTesseractCmdEnv = 'TESSERACT_CMD';

/// How often the Health_Endpoint is polled while waiting for readiness
/// (Req 3.3).
const Duration kHealthPollInterval = Duration(milliseconds: 500);

/// Maximum time to wait for the sidecar to report ready before treating startup
/// as failed (Req 3.3, 3.5).
const Duration kStartupTimeout = Duration(seconds: 30);

/// How long to wait after requesting graceful termination before force-killing
/// the sidecar on shutdown (Req 3.6, 3.7).
const Duration kShutdownGracePeriod = Duration(seconds: 5);

/// Maximum number of *retry* launches after a port-conflict before startup is
/// reported as failed (Req 3.8, 3.9). The total number of launch attempts is
/// therefore `kMaxPortRetries + 1`.
const int kMaxPortRetries = 3;

/// File (under `QPIC_TEMP_DIR`) where the manager records the live sidecar PID
/// so a stale child left by a hard crash can be reaped on the next launch.
const String kSidecarPidFileName = 'sidecar.pid';

/// Lifecycle states surfaced on the [SidecarManager.status] stream so the UI can
/// gate itself on engine readiness (Req 3.4, 3.5, 3.9, 3.10).
enum SidecarStatus {
  /// Choosing a free localhost port (Req 3.1).
  selectingPort,

  /// The sidecar process has been spawned (Req 3.2).
  starting,

  /// Polling `GET /api/health` for readiness (Req 3.3).
  waitingHealth,

  /// Health reported `ok`; [SidecarManager.baseUrl] is published (Req 3.4).
  ready,

  /// Startup failed (timeout, or exhausted port retries) (Req 3.5, 3.9).
  failed,

  /// The sidecar was shut down cleanly on app exit (Req 3.6, 3.7).
  stopped,

  /// The sidecar exited unexpectedly after having been [ready] (Req 3.10).
  engineStopped,
}

/// Thrown when the sidecar fails to reach a [SidecarStatus.ready] state.
///
/// Carries a human-readable [message] and the engine's captured [stderr] (when
/// any) so the startup-failure UI (task 6.2) can show actionable diagnostics
/// (Req 3.5, 3.9).
class SidecarStartException implements Exception {
  const SidecarStartException(this.message, {this.stderr = ''});

  /// A human-readable explanation of why startup failed (Req 3.5).
  final String message;

  /// stderr captured from the sidecar process, included verbatim to aid
  /// diagnosis. Empty when the process produced none.
  final String stderr;

  @override
  String toString() => stderr.isEmpty
      ? 'SidecarStartException: $message'
      : 'SidecarStartException: $message\n--- sidecar stderr ---\n$stderr';
}

/// Selects a free localhost port. Defaults to a real [ServerSocket] bind; an
/// override is injectable for deterministic tests and for the port-retry logic.
typedef PortSelector = Future<int> Function();

/// Spawns the sidecar process. Mirrors the subset of [Process.start] the manager
/// needs; injectable so tests can supply a fake process.
typedef ProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

/// Builds an [ApiClient] bound to the sidecar's Base_URL (used for health
/// polling). Injectable so tests can stub the health endpoint.
typedef ApiClientFactory = ApiClient Function(Uri baseUrl);

/// Returns the current wall-clock time. Injectable so the startup-timeout can be
/// driven deterministically in tests.
typedef Clock = DateTime Function();

/// Sleeps for [duration]. Injectable so the poll loop and the shutdown grace
/// period can be advanced deterministically in tests.
typedef Sleeper = Future<void> Function(Duration duration);

/// Best-effort kills a whole process tree by PID. On Windows this maps to
/// `taskkill /F /T /PID` (the Job-Object/kill-tree backstop, Req 24.3); on
/// POSIX it sends `SIGKILL`. Injectable so tests can observe reap/force-kill
/// calls without touching real OS processes.
typedef ProcessTreeKiller = Future<void> Function(int pid);

/// Wires an [onExit] callback to the OS/Flutter app-exit signals so the sidecar
/// is always torn down (Req 3.6, 3.7, 24.3). The production implementation hooks
/// `AppLifecycleState.detached` and `window_manager`'s close intercept; tests
/// inject a fake to avoid requiring a window/binding.
abstract class SidecarLifecycleBinder {
  /// Registers [onExit] against the app-exit signals.
  Future<void> bind(Future<void> Function() onExit);

  /// Removes any registered handlers.
  Future<void> unbind();
}

/// Manages the sidecar process lifecycle. See the library doc for the full
/// state machine and requirement mapping.
class SidecarManager {
  SidecarManager({
    SidecarCommandResolver? resolveCommand,
    Future<Directory> Function()? resolveTempDir,
    PortSelector? selectPort,
    ProcessStarter? startProcess,
    ApiClientFactory? createApiClient,
    Map<String, String>? environment,
    Duration startupTimeout = kStartupTimeout,
    Duration healthPollInterval = kHealthPollInterval,
    Duration shutdownGracePeriod = kShutdownGracePeriod,
    int maxPortRetries = kMaxPortRetries,
    bool? isWindows,
    ProcessTreeKiller? killProcessTree,
    SidecarLifecycleBinder? lifecycleBinder,
    Clock? clock,
    Sleeper? sleep,
  })  : _resolveCommand = resolveCommand ?? resolveSidecarCommand,
        _resolveTempDir = resolveTempDir ?? writableTempDir,
        _selectPort = selectPort ?? _selectFreePort,
        _startProcess = startProcess ?? _defaultStartProcess,
        _createApiClient = createApiClient ?? ApiClient.new,
        _environment = environment ?? Platform.environment,
        _startupTimeout = startupTimeout,
        _healthPollInterval = healthPollInterval,
        _shutdownGracePeriod = shutdownGracePeriod,
        _maxPortRetries = maxPortRetries,
        _isWindows = isWindows ?? Platform.isWindows,
        _killTree = killProcessTree ??
            _defaultProcessTreeKiller(isWindows ?? Platform.isWindows),
        _lifecycleBinder = lifecycleBinder ?? _FlutterLifecycleBinder(),
        _clock = clock ?? DateTime.now,
        _sleep = sleep ?? Future<void>.delayed;

  final SidecarCommandResolver _resolveCommand;
  final Future<Directory> Function() _resolveTempDir;
  final PortSelector _selectPort;
  final ProcessStarter _startProcess;
  final ApiClientFactory _createApiClient;
  final Map<String, String> _environment;
  final Duration _startupTimeout;
  final Duration _healthPollInterval;
  final Duration _shutdownGracePeriod;
  final int _maxPortRetries;
  final bool _isWindows;
  final ProcessTreeKiller _killTree;
  final SidecarLifecycleBinder _lifecycleBinder;
  final Clock _clock;
  final Sleeper _sleep;

  final StreamController<SidecarStatus> _statusController =
      StreamController<SidecarStatus>.broadcast();

  SidecarStatus _status = SidecarStatus.selectingPort;
  Uri? _baseUrl;
  int? _port;

  /// The live sidecar process, set once spawned. Used for graceful terminate →
  /// force-kill (Req 3.6) and to watch `exitCode` for unexpected exit (Req 3.10).
  Process? _process;

  /// The resolved per-user temp dir; retained so the PID file can be written and
  /// reaped (orphan backstop) and cleaned up on a clean stop.
  Directory? _tempDir;

  /// Accumulated sidecar stdout/stderr. stderr is surfaced in
  /// [SidecarStartException] and reused by the failure UI (task 6.2). The
  /// buffers are reset on each spawn so a retry's diagnostics reflect only that
  /// attempt (Req 3.8, 3.9).
  final StringBuffer _stdoutBuffer = StringBuffer();
  final StringBuffer _stderrBuffer = StringBuffer();
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  /// Completes when the current process's stderr stream is fully drained, so an
  /// early-exit classification (port-conflict vs hard failure) inspects the
  /// complete stderr rather than racing the `exitCode` future.
  Future<void>? _stderrDone;

  /// True once [stop] has begun, so the unexpected-exit watcher (Req 3.10) does
  /// not misread an intentional shutdown as an engine crash.
  bool _stopping = false;

  /// True once [dispose] has run, guarding late stream emissions.
  bool _disposed = false;

  /// True once app-exit handlers are installed (so [dispose] can unbind them).
  bool _lifecycleBound = false;

  // ---------------------------------------------------------------------------
  // Public surface.
  // ---------------------------------------------------------------------------

  /// Lifecycle status stream for the UI (broadcast; emits each transition).
  Stream<SidecarStatus> get status => _statusController.stream;

  /// The most recently emitted [SidecarStatus] (for late subscribers).
  SidecarStatus get currentStatus => _status;

  /// The published Base_URL (`http://127.0.0.1:{port}`). Throws a [StateError]
  /// if read before the sidecar reaches [SidecarStatus.ready].
  Uri get baseUrl {
    final url = _baseUrl;
    if (url == null) {
      throw StateError('Base_URL is not available until the sidecar is ready.');
    }
    return url;
  }

  /// The selected port, available once port selection has run.
  int? get port => _port;

  /// Captured sidecar stderr (verbatim). Empty until the process produces any.
  String get capturedStderr => _stderrBuffer.toString();

  /// Captured sidecar stdout (verbatim).
  String get capturedStdout => _stdoutBuffer.toString();

  /// Runs the startup sequence and returns the Base_URL once the engine is
  /// ready (Req 3.1–3.4), retrying on port conflict up to [kMaxPortRetries]
  /// times (Req 3.8, 3.9).
  ///
  /// Throws a [SidecarStartException] if the engine does not become healthy
  /// within the 30 s startup timeout (Req 3.5), if it exits during startup for
  /// a non-recoverable reason, or if the port-conflict retries are exhausted
  /// (Req 3.9). On any such failure the status transitions to
  /// [SidecarStatus.failed] and the UI stays disabled.
  Future<Uri> start() async {
    // Resolve the writable temp dir once and reap any stale child a previous
    // (crashed) run may have orphaned (Req 3.7 backstop).
    final tempDir = await _resolveTempDir();
    _tempDir = tempDir;
    await _reapStalePidFile(tempDir);

    SidecarStartException? lastFailure;

    for (var attempt = 0; attempt <= _maxPortRetries; attempt++) {
      // 1. Select a free localhost port (Req 3.1 / 3.8 on retry).
      _emit(SidecarStatus.selectingPort);
      final port = await _selectPort();
      _port = port;

      // 2. Spawn the sidecar bound to that port (Req 3.2).
      await _spawn(port, tempDir);
      _emit(SidecarStatus.starting);

      // 3. Wait for the Health_Endpoint to report ready (Req 3.3), watching for
      //    an early process exit (a stolen port shows up as a bind failure).
      _emit(SidecarStatus.waitingHealth);
      final candidateBaseUrl = _baseUrlForPort(port);
      final outcome = await _awaitStartupOutcome(candidateBaseUrl);

      if (outcome == _StartupOutcome.ready) {
        // 4. Publish Base_URL, watch for unexpected exit, enable the UI (3.4).
        _baseUrl = candidateBaseUrl;
        _watchForUnexpectedExit();
        _emit(SidecarStatus.ready);
        return candidateBaseUrl;
      }

      // This attempt failed: tear down its process and stream subscriptions
      // before retrying or giving up so nothing dangles.
      await _killCurrentProcess();
      await _cancelOutputCapture();

      if (outcome == _StartupOutcome.portConflict &&
          attempt < _maxPortRetries) {
        // A bind race: pick another free port and relaunch (Req 3.8).
        continue;
      }

      lastFailure = SidecarStartException(
        _failureMessage(outcome, attempts: attempt + 1),
        stderr: capturedStderr,
      );
      break;
    }

    // Timeout, non-recoverable exit, or retries exhausted (Req 3.5, 3.9).
    _emit(SidecarStatus.failed);
    throw lastFailure ??
        SidecarStartException(
          'The Qpic engine failed to start.',
          stderr: capturedStderr,
        );
  }

  /// Stops the sidecar: graceful termination, then force-kill after the grace
  /// period (Req 3.6, 3.7).
  ///
  /// Sends `SIGTERM` (mapped to `process.kill` on Windows), waits up to
  /// [kShutdownGracePeriod] for a clean exit, and otherwise force-kills the
  /// whole process tree (`SIGKILL` on POSIX, `taskkill /F /T` on Windows) so no
  /// orphan remains. The PID file is removed so the next launch sees no stale
  /// child. Safe to call when nothing is running and idempotent on repeat calls.
  Future<void> stop() async {
    _stopping = true;
    final proc = _process;

    if (proc != null) {
      // Graceful termination first (Req 3.6).
      _tryKill(proc, ProcessSignal.sigterm);

      final exitedGracefully = await _waitForExit(proc, _shutdownGracePeriod);
      if (!exitedGracefully) {
        // Force-kill the tree after the grace period (Req 3.6, 3.7, 24.3).
        await _killTree(proc.pid);
        if (!_isWindows) {
          _tryKill(proc, ProcessSignal.sigkill);
        }
        // Best-effort wait so we don't report stopped before it's gone.
        await _waitForExit(proc, _shutdownGracePeriod);
      }
    }

    _process = null;
    await _cancelOutputCapture();
    _deletePidFile();
    _emit(SidecarStatus.stopped);
  }

  /// Hooks the app-exit signals so the sidecar is always shut down — Flutter's
  /// `AppLifecycleState.detached` and `window_manager`'s window-close intercept
  /// (Req 3.6, 3.7, 24.3). Call once after the window is created. Idempotent.
  Future<void> installLifecycleHandlers() async {
    if (_lifecycleBound) return;
    _lifecycleBound = true;
    await _lifecycleBinder.bind(stop);
  }

  /// Releases the status stream and unbinds any app-exit handlers. Call when the
  /// manager is no longer needed.
  Future<void> dispose() async {
    _disposed = true;
    if (_lifecycleBound) {
      _lifecycleBound = false;
      await _lifecycleBinder.unbind();
    }
    await _cancelOutputCapture();
    await _statusController.close();
  }

  // ---------------------------------------------------------------------------
  // Internals.
  // ---------------------------------------------------------------------------

  /// Spawns the sidecar process with the engine environment (Req 3.2, 3.11) and
  /// records its PID for the orphan backstop.
  Future<void> _spawn(int port, Directory tempDir) async {
    final command = _resolveCommand();

    final environment = <String, String>{
      kQpicPortEnv: port.toString(),
      kQpicTempDirEnv: tempDir.path,
    };
    // Forward an explicit Tesseract path only when one is configured, leaving
    // the engine's default lookup order intact otherwise (Req 1.6).
    final tesseractCmd = _environment[kTesseractCmdEnv];
    if (tesseractCmd != null && tesseractCmd.isNotEmpty) {
      environment[kTesseractCmdEnv] = tesseractCmd;
    }

    final process = await _startProcess(
      command.executable,
      command.args,
      workingDirectory: command.workingDirectory,
      environment: environment,
    );
    _process = process;
    _captureOutput(process);
    _writePidFile(tempDir, process.pid);
  }

  /// Streams the process's stdout/stderr into buffers for diagnostics. The
  /// captured stderr is surfaced in [SidecarStartException] / the failure UI.
  /// Buffers are cleared first so each (re)launch reports only its own output.
  void _captureOutput(Process process) {
    _stdoutBuffer.clear();
    _stderrBuffer.clear();
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .listen(_stdoutBuffer.write, onError: (_) {});
    final stderrDone = Completer<void>();
    _stderrDone = stderrDone.future;
    _stderrSub = process.stderr.transform(utf8.decoder).listen(
          _stderrBuffer.write,
          onError: (_) {},
          onDone: () {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
          cancelOnError: false,
        );
  }

  Future<void> _cancelOutputCapture() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
  }

  /// Waits for the engine to become ready, exit early, or time out (Req 3.3).
  ///
  /// Polls `GET /api/health` every [_healthPollInterval] until it reports
  /// `status == "ok"` or [_startupTimeout] elapses, while also watching the
  /// process `exitCode`: a sidecar that dies during startup (commonly a stolen
  /// port → bind failure) is reported promptly so the retry logic can react.
  Future<_StartupOutcome> _awaitStartupOutcome(Uri candidateBaseUrl) async {
    final client = _createApiClient(candidateBaseUrl);
    final deadline = _clock().add(_startupTimeout);

    // Track an early exit without blocking the poll loop.
    var exited = false;
    final proc = _process;
    unawaited(proc?.exitCode.then((_) {
      exited = true;
    }));

    while (_clock().isBefore(deadline)) {
      if (exited) {
        return await _classifyExit();
      }
      if (await _isHealthy(client)) {
        return _StartupOutcome.ready;
      }
      if (exited) {
        return await _classifyExit();
      }
      await _sleep(_healthPollInterval);
    }

    // Final checks so a sidecar that became ready (or died) exactly at the
    // deadline is not misclassified.
    if (exited) {
      return await _classifyExit();
    }
    if (await _isHealthy(client)) {
      return _StartupOutcome.ready;
    }
    return _StartupOutcome.timeout;
  }

  /// Classifies an early process exit during startup. A port-conflict (the
  /// engine could not bind because the port was stolen between selection and
  /// bind) is retryable (Req 3.8); anything else is a hard startup failure.
  /// Waits for stderr to finish draining first so the bind-error heuristic sees
  /// the complete output.
  Future<_StartupOutcome> _classifyExit() async {
    await _stderrDone;
    return _looksLikePortConflict(capturedStderr)
        ? _StartupOutcome.portConflict
        : _StartupOutcome.processExited;
  }

  /// Heuristic for an "address already in use" bind failure across OSes
  /// (uvicorn/asyncio surface these on stderr): macOS `[Errno 48]`, Linux
  /// `[Errno 98]`, Windows `WinError 10048`.
  static bool _looksLikePortConflict(String stderr) {
    final s = stderr.toLowerCase();
    return s.contains('address already in use') ||
        s.contains('only one usage of each socket address') ||
        s.contains('error while attempting to bind') ||
        s.contains('errno 48') ||
        s.contains('errno 98') ||
        s.contains('10048');
  }

  String _failureMessage(_StartupOutcome outcome, {required int attempts}) {
    switch (outcome) {
      case _StartupOutcome.timeout:
        return 'The Qpic engine did not become ready within '
            '${_startupTimeout.inSeconds}s.';
      case _StartupOutcome.portConflict:
        return 'The Qpic engine could not bind a free localhost port after '
            '$attempts attempt(s).';
      case _StartupOutcome.processExited:
        return 'The Qpic engine exited during startup before becoming ready.';
      case _StartupOutcome.ready:
        return 'The Qpic engine started.'; // not a failure; defensive only.
    }
  }

  /// Watches the live process for an unsolicited exit after readiness and
  /// transitions to [SidecarStatus.engineStopped] so the UI disables itself
  /// (Req 3.10). An intentional [stop] (which sets [_stopping]) is ignored.
  void _watchForUnexpectedExit() {
    final proc = _process;
    if (proc == null) return;
    unawaited(proc.exitCode.then((_) {
      if (_stopping || _disposed) return;
      if (_status == SidecarStatus.ready) {
        _emit(SidecarStatus.engineStopped);
      }
    }));
  }

  /// Best-effort termination of the current attempt's process (used between
  /// port-conflict retries and on hard startup failure).
  Future<void> _killCurrentProcess() async {
    final proc = _process;
    if (proc == null) return;
    _tryKill(proc, ProcessSignal.sigkill);
    _process = null;
  }

  void _tryKill(Process proc, ProcessSignal signal) {
    try {
      proc.kill(signal);
    } catch (_) {
      // Process may already be gone; nothing to do.
    }
  }

  /// Returns `true` if [proc] exits within [timeout], `false` otherwise. Uses
  /// the injectable [_sleep] so the grace period is deterministic in tests.
  Future<bool> _waitForExit(Process proc, Duration timeout) {
    final completer = Completer<bool>();
    proc.exitCode.then((_) {
      if (!completer.isCompleted) completer.complete(true);
    });
    _sleep(timeout).then((_) {
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future;
  }

  /// A single health probe. Treats any error (connection refused while the
  /// engine is still booting, non-200, malformed body) as "not ready yet".
  Future<bool> _isHealthy(ApiClient client) async {
    try {
      final health = await client.health();
      return health.status == 'ok';
    } catch (_) {
      return false;
    }
  }

  Uri _baseUrlForPort(int port) => Uri.parse('http://127.0.0.1:$port');

  // --- Orphan backstop: PID file -------------------------------------------

  File _pidFile(Directory tempDir) =>
      File(p.join(tempDir.path, kSidecarPidFileName));

  /// Records the live sidecar PID so a stale child can be reaped on next launch.
  /// Best-effort: silently skipped if the temp dir is unavailable.
  void _writePidFile(Directory tempDir, int pid) {
    try {
      if (!tempDir.existsSync()) return;
      _pidFile(tempDir).writeAsStringSync('$pid');
    } catch (_) {
      // Diagnostics-only; never block startup on a PID-file write.
    }
  }

  /// Kills (kill-tree) and clears any sidecar PID a previous crashed run left
  /// behind, preventing orphan accumulation (Req 3.7 backstop).
  Future<void> _reapStalePidFile(Directory tempDir) async {
    try {
      final file = _pidFile(tempDir);
      if (!file.existsSync()) return;
      final pid = int.tryParse(file.readAsStringSync().trim());
      if (pid != null && pid > 0) {
        await _killTree(pid);
      }
      file.deleteSync();
    } catch (_) {
      // Best-effort reap; a missing/garbage PID file is not an error.
    }
  }

  void _deletePidFile() {
    final dir = _tempDir;
    if (dir == null) return;
    try {
      final file = _pidFile(dir);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  void _emit(SidecarStatus next) {
    _status = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  // ---------------------------------------------------------------------------
  // Default collaborators.
  // ---------------------------------------------------------------------------

  /// Picks a free localhost port by binding to `127.0.0.1:0`, reading the
  /// OS-assigned ephemeral port (always 1024–65535), then closing the socket so
  /// the sidecar can claim it (Req 3.1).
  static Future<int> _selectFreePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Default [ProcessStarter] delegating to [Process.start]. The parent
  /// environment is inherited (`includeParentEnvironment: true`) and the
  /// supplied [environment] entries are merged on top.
  static Future<Process> _defaultStartProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
  }

  /// Default [ProcessTreeKiller]: `taskkill /F /T /PID` on Windows (kill-tree,
  /// Req 24.3), `SIGKILL` on POSIX. Best-effort — a missing process is ignored.
  static ProcessTreeKiller _defaultProcessTreeKiller(bool isWindows) {
    return (int pid) async {
      try {
        if (isWindows) {
          await Process.run('taskkill', <String>['/F', '/T', '/PID', '$pid']);
        } else {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      } catch (_) {
        // Process already gone, or insufficient permissions; nothing to do.
      }
    };
  }
}

/// The terminal outcome of a single startup attempt's health/exit race.
enum _StartupOutcome {
  /// The engine reported healthy within the timeout.
  ready,

  /// The engine exited because the chosen port was unavailable (retryable).
  portConflict,

  /// The engine exited during startup for a non-recoverable reason.
  processExited,

  /// The engine never became ready within the 30 s startup timeout.
  timeout,
}

/// Resolves a runnable [SidecarCommand]. Defaults to [resolveSidecarCommand]
/// from `paths.dart`; injectable for tests.
typedef SidecarCommandResolver = SidecarCommand Function();

/// Production [SidecarLifecycleBinder] wiring app-exit teardown (Req 24.3).
///
/// Registers an [AppLifecycleListener] for `AppLifecycleState.detached` and a
/// [WindowListener] with `window_manager`, enabling its close intercept
/// (`setPreventClose(true)`) so a user closing the window first shuts the engine
/// down and then destroys the window. Both paths funnel into the same `onExit`
/// (the manager's [SidecarManager.stop]).
class _FlutterLifecycleBinder implements SidecarLifecycleBinder {
  AppLifecycleListener? _appListener;
  _ShutdownWindowListener? _windowListener;

  @override
  Future<void> bind(Future<void> Function() onExit) async {
    _appListener = AppLifecycleListener(
      onDetach: () => unawaited(onExit()),
    );

    final listener = _ShutdownWindowListener(onExit);
    _windowListener = listener;
    windowManager.addListener(listener);
    // Intercept the native close so we can terminate the sidecar before the
    // window (and thus the parent process) goes away (Req 3.7).
    await windowManager.setPreventClose(true);
  }

  @override
  Future<void> unbind() async {
    _appListener?.dispose();
    _appListener = null;

    final listener = _windowListener;
    if (listener != null) {
      windowManager.removeListener(listener);
      _windowListener = null;
      await windowManager.setPreventClose(false);
    }
  }
}

/// Bridges `window_manager`'s close intercept to the sidecar shutdown: shut the
/// engine down, then destroy the window so the app actually exits.
class _ShutdownWindowListener with WindowListener {
  _ShutdownWindowListener(this._onClose);

  final Future<void> Function() _onClose;

  @override
  void onWindowClose() {
    unawaited(() async {
      await _onClose();
      await windowManager.destroy();
    }());
  }
}
