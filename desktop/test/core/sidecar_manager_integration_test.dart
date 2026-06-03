// Integration test for the SidecarManager lifecycle — Task 5.3.
//
// ============================================================================
//  Property 10: "No orphan process"  (Validates: Requirements 3.7)
// ============================================================================
//
// Requirement 3.7: "WHEN the Flutter_App exits, THE Sidecar_Manager SHALL leave
// no orphaned Sidecar process running."
//
// Unlike the task-5.1/5.2 unit suites (which drive the manager through *fake*
// processes), this integration test exercises the manager against a REAL OS
// child process and the manager's REAL collaborators:
//
//   * a genuine localhost port selected by the production `ServerSocket` seam,
//   * a genuine `Process.start` spawning a tiny Python HTTP **sidecar stub**
//     that serves `GET /api/health` exactly like the engine,
//   * the production Dio-backed `ApiClient` polling that real endpoint,
//   * the production POSIX terminate → force-kill path and `taskkill`-style
//     process-tree killer.
//
// Because a real process is used, orphan-freedom is asserted *directly* via the
// OS: after `stop()` the child's `exitCode` must complete (Dart reaps the child
// once it is gone) and the PID must no longer be alive (`kill -0`). There is no
// fake that could mask a surviving process.
//
// Approach note (real vs. fake): the task asks to "prefer a real/dev sidecar
// process if feasible … otherwise use a controllable fake". A real process IS
// feasible here, so the orphan-freedom and lifecycle scenarios run against a
// real Python HTTP stub. The stub is intentionally tiny and engine-agnostic —
// it only implements the `/api/health` contract the manager depends on — so the
// test stays fast and hermetic while still validating the real spawn/health/
// kill machinery end-to-end. The one scenario that cannot be made deterministic
// with a real bind race (the *port-conflict retry*) holds a real listening
// socket on the first selected port to force a genuine `EADDRINUSE`, then lets
// the manager re-select and succeed — so even the retry path uses real sockets.
//
// HOW THIS REALIZES PROPERTY 10 (property-based testing note):
// ----------------------------------------------------------------------------
// This project has no QuickCheck/Hypothesis-style package in its pubspec; as
// the rest of the suite documents (see `dto_roundtrip_test.dart`,
// `canvas_geometry_test.dart`, etc.), the convention is to realize a property
// with a *seeded pseudo-random generator* (`math.Random(seed)`) that drives the
// system under test across many randomized-but-valid inputs and asserts the
// universal invariant on every iteration. Here the invariant is:
//
//     for ANY started sidecar, after the app exits (`stop()` /
//     lifecycle-detached / window-close), NO sidecar child process started by
//     this manager remains alive.
//
// We sample the input space (how the app exits, whether the child ignores the
// graceful SIGTERM and must be force-killed, randomized health-ready delay and
// per-launch temp dirs) with a seeded RNG and assert orphan-freedom on each
// draw. Real timing (a real process + real health poll) makes these genuine
// end-to-end runs, so iteration counts are kept modest.
//
// These tests require `python3` on PATH. When it is absent (rare CI images)
// they are skipped with a clear message rather than failing spuriously.

import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/paths.dart';
import 'package:qpic_desktop/core/sidecar_manager.dart';

// ---------------------------------------------------------------------------
// Real sidecar stub: a minimal Python HTTP server implementing GET /api/health.
// ---------------------------------------------------------------------------

/// Python source for a tiny stand-in sidecar. It mirrors only the contract the
/// [SidecarManager] depends on:
///   * reads `QPIC_PORT` from the environment and binds `127.0.0.1:{port}`,
///   * answers `GET /api/health` with `{"status":"ok", ...}` after an optional
///     startup delay (`QPIC_READY_DELAY_MS`, to model a slow boot),
///   * optionally *ignores* `SIGTERM` (`QPIC_IGNORE_SIGTERM=1`) so the manager
///     must escalate to a force-kill — exercising the 5 s grace → force path
///     against a real, stubborn process.
///
/// It deliberately contains no engine logic; it exists only to be a real OS
/// process the manager can spawn, health-check, and tear down.
const String _kSidecarStubPy = r'''
import json
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/health":
            body = json.dumps({
                "status": "ok",
                "tesseract_available": True,
                "ai_available": False,
                "version": "stub-1.0.0",
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


def main():
    if os.environ.get("QPIC_IGNORE_SIGTERM") == "1":
        # Model a process that does not exit on graceful termination, forcing
        # the manager to escalate to a force-kill of the process tree.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)

    delay_ms = int(os.environ.get("QPIC_READY_DELAY_MS", "0"))
    if delay_ms > 0:
        time.sleep(delay_ms / 1000.0)

    port = int(os.environ["QPIC_PORT"])
    server = HTTPServer(("127.0.0.1", port), _Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
''';

/// Resolves a usable `python3` (or `python`) executable, or `null` when none is
/// on PATH (so the suite can skip rather than fail).
String? _resolvePython() {
  for (final candidate in <String>['python3', 'python']) {
    try {
      final res = Process.runSync(candidate, <String>['--version']);
      if (res.exitCode == 0) return candidate;
    } catch (_) {
      // Try the next candidate.
    }
  }
  return null;
}

/// True if [pid] names a live process (POSIX `kill -0`). Used to assert
/// orphan-freedom directly against the OS, independent of the manager's view.
bool _isProcessAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', <String>['/FI', 'PID eq $pid']);
    return (res.stdout as String).contains('$pid');
  }
  // `kill -0` sends no signal but performs the existence/permission check.
  final res = Process.runSync('kill', <String>['-0', '$pid']);
  return res.exitCode == 0;
}

/// A production-shaped [ApiClient] factory whose underlying real Dio carries
/// sensible connect/receive timeouts. This is the realistic posture for a
/// health probe: a port that accepts a TCP connection but never answers (e.g.
/// a foreign listener squatting the port during a conflict) must make the
/// probe FAIL FAST rather than hang, so the manager can observe the sidecar's
/// own early bind-failure exit and retry. The HTTP layer is entirely real.
ApiClient _timeoutApiClient(Uri baseUrl) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(milliseconds: 400),
      receiveTimeout: const Duration(milliseconds: 400),
      sendTimeout: const Duration(milliseconds: 400),
    ),
  );
  return ApiClient(baseUrl, dio: dio);
}

void main() {
  final python = _resolvePython();
  final pythonMissing = python == null;
  final skipReason = pythonMissing
      ? 'python3/python not found on PATH; real-sidecar integration test '
          'requires a Python interpreter to run the stub sidecar.'
      : null;

  // Each test gets its own temp dir holding the stub script + the manager's
  // PID file; tracked here so we can clean them all up afterwards.
  final tempDirs = <Directory>[];

  Directory newWorkDir() {
    final dir = Directory.systemTemp.createTempSync('qpic-sidecar-itest');
    tempDirs.add(dir);
    return dir;
  }

  /// Writes the stub script into [workDir] and returns a [SidecarCommandResolver]
  /// that launches it with the given Python interpreter.
  SidecarCommand Function() stubCommand(Directory workDir) {
    final script = File(p.join(workDir.path, 'sidecar_stub.py'))
      ..writeAsStringSync(_kSidecarStubPy);
    return () => SidecarCommand(
          executable: python!,
          args: <String>[script.path],
        );
  }

  /// Builds a manager wired to launch the REAL Python stub via the production
  /// port selector, process starter, api-client factory and process-tree
  /// killer. Only [environment] extras and the optional toggles are varied.
  ///
  /// [ignoreSigterm] makes the child ignore graceful termination so the
  /// force-kill path is exercised. [readyDelayMs] models a slow boot.
  ({SidecarManager manager, Directory workDir, List<int> spawnedPids})
      realManager({
    bool ignoreSigterm = false,
    int readyDelayMs = 0,
  }) {
    final workDir = newWorkDir();
    final spawnedPids = <int>[];
    final extraEnv = <String, String>{
      if (ignoreSigterm) 'QPIC_IGNORE_SIGTERM': '1',
      if (readyDelayMs > 0) 'QPIC_READY_DELAY_MS': '$readyDelayMs',
    };

    final manager = SidecarManager(
      resolveCommand: stubCommand(workDir),
      resolveTempDir: () async => workDir,
      // Production port selector (binds 127.0.0.1:0) — real free port.
      // Production process starter — real Process.start — but we record PIDs
      // so the test can assert orphan-freedom against the OS directly.
      startProcess: (
        executable,
        args, {
        workingDirectory,
        environment,
      }) async {
        final proc = await Process.start(
          executable,
          args,
          workingDirectory: workingDirectory,
          // Merge the per-scenario toggles on top of the manager's env.
          environment: <String, String>{...?environment, ...extraEnv},
        );
        spawnedPids.add(proc.pid);
        return proc;
      },
      // Production-shaped ApiClient (real Dio, with sensible timeouts) polling
      // the real /api/health endpoint.
      createApiClient: _timeoutApiClient,
      environment: const <String, String>{},
      isWindows: false,
      // A short grace period keeps the force-kill test fast while still
      // exercising the terminate → wait → force-kill escalation.
      shutdownGracePeriod: const Duration(milliseconds: 500),
    );

    return (manager: manager, workDir: workDir, spawnedPids: spawnedPids);
  }

  tearDownAll(() {
    for (final dir in tempDirs) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  });

  group('Property 10 — No orphan process (real sidecar, Req 3.7)', () {
    test(
      'start -> health -> shutdown leaves no surviving sidecar process',
      () async {
        final env = realManager();
        final manager = env.manager;

        final baseUrl = await manager.start();
        expect(manager.currentStatus, SidecarStatus.ready);
        // The real engine stub is reachable on the published Base_URL.
        expect(baseUrl.host, '127.0.0.1');

        final pid = env.spawnedPids.single;
        expect(_isProcessAlive(pid), isTrue,
            reason: 'sidecar should be alive once Ready');

        await manager.stop();
        expect(manager.currentStatus, SidecarStatus.stopped);

        // Property 10: after the app exits, the real child is gone (Req 3.7).
        expect(_isProcessAlive(pid), isFalse,
            reason: 'no orphaned sidecar process may survive shutdown');

        await manager.dispose();
      },
      skip: skipReason,
    );

    test(
      'force-kills a SIGTERM-ignoring sidecar so no orphan survives (Req 3.6, 3.7)',
      () async {
        // A real, stubborn child that ignores graceful termination: the manager
        // must escalate to a force-kill of the process tree.
        final env = realManager(ignoreSigterm: true);
        final manager = env.manager;

        await manager.start();
        final pid = env.spawnedPids.single;
        expect(_isProcessAlive(pid), isTrue);

        await manager.stop();

        // Even though SIGTERM was ignored, the force-kill leaves no orphan.
        expect(_isProcessAlive(pid), isFalse,
            reason: 'force-kill must reap a process that ignores SIGTERM');
        expect(manager.currentStatus, SidecarStatus.stopped);

        await manager.dispose();
      },
      skip: skipReason,
    );

    test(
      'orphan-freedom holds across randomized exit paths (seeded property)',
      () async {
        // **Validates: Requirements 3.7**
        //
        // Seeded property generator (project convention — see file header):
        // sample the input space of "how the app exits" and child behavior, and
        // assert the universal invariant (no surviving child) on every draw.
        final seed = 'Property10-no-orphan'.hashCode & 0x7fffffff;
        final rng = math.Random(seed);
        const iterations = 6;

        for (var i = 0; i < iterations; i++) {
          // Randomized-but-valid inputs:
          //   exitVia     — stop() vs the bound lifecycle exit handler.
          //   ignoreTerm  — whether the child ignores graceful SIGTERM.
          //   readyDelay  — a slow boot (0–150 ms) before health goes ok.
          final exitViaLifecycle = rng.nextBool();
          final ignoreTerm = rng.nextBool();
          final readyDelay = rng.nextInt(4) * 50; // 0,50,100,150 ms

          final binder = _CapturingBinder();
          final env = realManager(
            ignoreSigterm: ignoreTerm,
            readyDelayMs: readyDelay,
          );
          // Swap in a capturing lifecycle binder so we can drive the
          // window-close / app-detached exit path through the manager.
          final manager = SidecarManager(
            resolveCommand: stubCommand(env.workDir),
            resolveTempDir: () async => env.workDir,
            startProcess: (e, a, {workingDirectory, environment}) async {
              final proc = await Process.start(
                e,
                a,
                workingDirectory: workingDirectory,
                environment: <String, String>{
                  ...?environment,
                  if (ignoreTerm) 'QPIC_IGNORE_SIGTERM': '1',
                  if (readyDelay > 0) 'QPIC_READY_DELAY_MS': '$readyDelay',
                },
              );
              env.spawnedPids.add(proc.pid);
              return proc;
            },
            createApiClient: _timeoutApiClient,
            environment: const <String, String>{},
            isWindows: false,
            shutdownGracePeriod: const Duration(milliseconds: 500),
            lifecycleBinder: binder,
          );

          await manager.start();
          expect(manager.currentStatus, SidecarStatus.ready,
              reason: 'iteration $i (delay=$readyDelay) should reach Ready');
          final pid = env.spawnedPids.last;
          expect(_isProcessAlive(pid), isTrue);

          if (exitViaLifecycle) {
            // Exit through the same path the window-close / detached signal
            // uses in production.
            await manager.installLifecycleHandlers();
            await binder.onExit!();
          } else {
            await manager.stop();
          }

          // Universal invariant: no orphaned sidecar from this manager.
          expect(
            _isProcessAlive(pid),
            isFalse,
            reason: 'iteration $i (exitViaLifecycle=$exitViaLifecycle, '
                'ignoreTerm=$ignoreTerm, readyDelay=$readyDelay) left an '
                'orphaned sidecar (Req 3.7)',
          );
          expect(manager.currentStatus, SidecarStatus.stopped);

          await manager.dispose();
        }
      },
      skip: skipReason,
    );
  });

  group('Port-conflict retry against real sockets (Req 3.8)', () {
    test(
      'a held port forces a genuine EADDRINUSE, then the manager retries and '
      'reaches Ready on a free port',
      () async {
        // Hold a REAL listening socket on the first port the manager selects so
        // the stub sidecar genuinely fails to bind (EADDRINUSE), forcing a
        // retry. Subsequent selections are free, so the next launch succeeds.
        final blocker =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final blockedPort = blocker.port;

        final workDir = newWorkDir();
        final spawnedPids = <int>[];
        var selection = 0;

        final manager = SidecarManager(
          resolveCommand: stubCommand(workDir),
          resolveTempDir: () async => workDir,
          // First selection returns the actively-held port (guaranteed bind
          // failure); later selections pick a genuinely free port.
          selectPort: () async {
            if (selection++ == 0) return blockedPort;
            final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
            final port = s.port;
            await s.close();
            return port;
          },
          startProcess: (e, a, {workingDirectory, environment}) async {
            final proc = await Process.start(
              e,
              a,
              workingDirectory: workingDirectory,
              environment: environment,
            );
            spawnedPids.add(proc.pid);
            return proc;
          },
          createApiClient: _timeoutApiClient,
          environment: const <String, String>{},
          isWindows: false,
          shutdownGracePeriod: const Duration(milliseconds: 500),
        );

        try {
          final baseUrl = await manager.start();

          // Retried onto a different, free port (Req 3.8).
          expect(manager.currentStatus, SidecarStatus.ready);
          expect(baseUrl.port, isNot(blockedPort));
          expect(selection, greaterThanOrEqualTo(2),
              reason: 'a second port had to be selected after the conflict');

          // No orphan from the failed first attempt: only the successful
          // launch should still be alive, and it tears down cleanly.
          await manager.stop();
          for (final pid in spawnedPids) {
            expect(_isProcessAlive(pid), isFalse,
                reason: 'neither the conflicted nor the successful launch may '
                    'leave an orphan (Req 3.7)');
          }
        } finally {
          await blocker.close();
          await manager.dispose();
        }
      },
      skip: skipReason,
    );
  });

  group('Unexpected exit after Ready -> EngineStopped (Req 3.10)', () {
    test(
      'killing the real sidecar after Ready transitions to engineStopped',
      () async {
        final env = realManager();
        final manager = env.manager;

        final statuses = <SidecarStatus>[];
        final sub = manager.status.listen(statuses.add);

        await manager.start();
        expect(manager.currentStatus, SidecarStatus.ready);
        final pid = env.spawnedPids.single;

        // Simulate an unexpected crash: kill the real process out from under
        // the manager (no stop() call), then wait for the exit-code watcher to
        // observe it.
        Process.killPid(pid, ProcessSignal.sigkill);

        // Wait (real time) for the manager's exitCode watcher to fire.
        final stopped = await _waitForStatus(
          manager,
          SidecarStatus.engineStopped,
          const Duration(seconds: 5),
        );

        await pumpEventQueue();
        await sub.cancel();

        expect(stopped, isTrue,
            reason:
                'an unexpected exit after Ready must surface engineStopped');
        expect(manager.currentStatus, SidecarStatus.engineStopped);
        expect(statuses, contains(SidecarStatus.engineStopped));

        // The crashed child is, by definition, not an orphan: confirm it's gone.
        expect(_isProcessAlive(pid), isFalse);

        await manager.dispose();
      },
      skip: skipReason,
    );
  });
}

/// A [SidecarLifecycleBinder] that records the manager's exit callback so a test
/// can drive the app-exit (window-close / detached) path deterministically.
class _CapturingBinder implements SidecarLifecycleBinder {
  Future<void> Function()? onExit;

  @override
  Future<void> bind(Future<void> Function() onExit) async {
    this.onExit = onExit;
  }

  @override
  Future<void> unbind() async {
    onExit = null;
  }
}

/// Polls [manager.currentStatus] until it reaches [target] or [timeout] elapses.
/// Returns whether the target status was observed. Uses real time because the
/// process exit is a real OS event.
Future<bool> _waitForStatus(
  SidecarManager manager,
  SidecarStatus target,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (manager.currentStatus == target) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return manager.currentStatus == target;
}
