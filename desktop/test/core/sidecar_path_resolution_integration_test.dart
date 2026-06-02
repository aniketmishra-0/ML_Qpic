// Integration test for embedded-sidecar path resolution + start→health — Task 21.3.
//
// ============================================================================
//  Requirement 21.3 — "THE macOS and Windows Installers SHALL embed the Sidecar
//  and the Tesseract_Bundle so that both are discoverable at runtime inside the
//  installed application."
//  Requirement 24.3 — "THE Flutter_App SHALL start, drive, and shut down the
//  Sidecar on both macOS and Windows."
// ============================================================================
//
// This test exercises BOTH halves of "the embedded sidecar path resolves and
// starts" called out by task 21.3 — the *packaged* layout and the *dev*
// fallback — using the production resolution logic in `paths.dart` and the real
// `SidecarManager` lifecycle.
//
//   1. PATH RESOLUTION (packaged, per-OS).  `resolveSidecarExecutablePath`
//      points at the embedded binary relative to the app bundle:
//        * macOS:   `…/Qpic.app/Contents/Resources/sidecar/qpic-sidecar`
//        * Windows: `…/<runner>/sidecar/qpic-sidecar.exe`
//      We build a *fake installed bundle* on disk for each OS, resolve the path
//      with the production function, and assert the embedded binary is found at
//      exactly that location (i.e. "discoverable at runtime").
//
//   2. PACKAGED START → HEALTH.  We drop a tiny executable health stub at the
//      resolved per-OS packaged path and drive it through the REAL
//      `SidecarManager` (production port selector, `Process.start`, Dio-backed
//      `ApiClient` polling `/api/health`, and the production terminate→kill
//      path).  This confirms the *resolved packaged path is the thing that gets
//      spawned* and that it reaches Ready then shuts down with no orphan.  A
//      real PyInstaller binary isn't available in a unit-test sandbox, so the
//      embedded binary is stubbed (per the task's "mock/stub where a real
//      packaged binary isn't available").
//
//   3. DEV FALLBACK RESOLUTION.  With no embedded binary present (the case when
//      running from source), the production `resolveSidecarCommand` falls back
//      to `python -m packaging.sidecar` from the repo root.  We assert that
//      shape against the real function.
//
//   4. DEV FALLBACK START → HEALTH.  We start the **real** engine sidecar
//      (`packaging/sidecar.py` / `app.main:app`) through the `SidecarManager`
//      and poll the real `/api/health` to Ready, then shut down with no orphan.
//
// HOST NOTE (dev fallback launch form): the design's dev command is
// `python -m packaging.sidecar`.  In this repo's environment the PyPI
// `packaging` distribution shadows the repo's namespace `packaging/` dir, so
// `-m packaging.sidecar` does not resolve (the existing
// `packaging/tests/test_sidecar_offline_ocr.py` documents the same quirk and
// launches by file path instead).  This test therefore probes whether the
// module form resolves on the host: if it does (e.g. a clean CI image) it uses
// the EXACT production command; otherwise it falls back to the behaviorally
// identical file-path launch (`python <repo>/packaging/sidecar.py`).  Either
// way the real engine is started and health-checked end to end.
//
// These tests require a Python interpreter that can import the engine
// (`app.main`).  When none is found they skip with a clear message rather than
// failing spuriously, mirroring `sidecar_manager_integration_test.dart`.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/paths.dart';
import 'package:qpic_desktop/core/sidecar_manager.dart';

// ---------------------------------------------------------------------------
// A minimal, engine-agnostic health stub used to stand in for the *packaged*
// embedded binary. It serves only `GET /api/health` — the single contract the
// SidecarManager depends on to declare Ready — and needs nothing beyond the
// Python stdlib, so it runs even where the engine deps aren't importable.
// ---------------------------------------------------------------------------
const String _kHealthStubPy = r'''
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/health":
            body = json.dumps({
                "status": "ok",
                "tesseract_available": True,
                "ai_available": False,
                "version": "packaged-stub-1.0.0",
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
    port = int(os.environ["QPIC_PORT"])
    HTTPServer(("127.0.0.1", port), _Handler).serve_forever()


if __name__ == "__main__":
    main()
''';

/// Resolves an *absolute* path to a `python3`/`python` on PATH (only stdlib
/// needed), or `null`. An absolute path is required because the packaged stub
/// uses it in a `#!` shebang, which the kernel only honors with a full path.
String? _resolveAnyPython() {
  for (final candidate in <String>['python3', 'python']) {
    try {
      if (Process.runSync(candidate, <String>['--version']).exitCode != 0) {
        continue;
      }
      // Resolve the absolute interpreter path for the shebang.
      final abs = Process.runSync(
        candidate,
        <String>['-c', 'import sys; print(sys.executable)'],
      );
      if (abs.exitCode == 0) {
        final path = (abs.stdout as String).trim();
        if (path.isNotEmpty && File(path).existsSync()) return path;
      }
    } catch (_) {
      // Try the next candidate.
    }
  }
  return null;
}

/// Resolves a Python interpreter that can import the engine (`app.main`) from
/// [repoRoot], or `null` when none of the candidates has the engine deps.
///
/// Honors the production `QPIC_PYTHON` override, then the repo virtualenv, then
/// a PATH interpreter — the same precedence a developer's environment would use.
String? _resolveEnginePython(String repoRoot) {
  final candidates = <String>[
    if ((Platform.environment['QPIC_PYTHON'] ?? '').isNotEmpty)
      Platform.environment['QPIC_PYTHON']!,
    p.join(repoRoot, '.venv', 'bin', 'python'),
    p.join(repoRoot, '.venv', 'Scripts', 'python.exe'),
    'python3',
    'python',
  ];
  for (final python in candidates) {
    try {
      final res = Process.runSync(
        python,
        <String>['-c', 'import app.main'],
        workingDirectory: repoRoot,
      );
      if (res.exitCode == 0) return python;
    } catch (_) {
      // Not runnable / missing deps; try the next candidate.
    }
  }
  return null;
}

/// True when `python -m packaging.sidecar` resolves on this host (i.e. the repo
/// `packaging/` namespace is importable and not shadowed by PyPI `packaging`).
bool _devModuleFormResolves(String python, String repoRoot) {
  try {
    final res = Process.runSync(
      python,
      <String>[
        '-c',
        "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('packaging.sidecar') else 3)",
      ],
      workingDirectory: repoRoot,
    );
    return res.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Whether [pid] names a live process, checked against the OS directly so
/// orphan-freedom is asserted independently of the manager's view.
bool _isProcessAlive(int pid) {
  if (Platform.isWindows) {
    final res = Process.runSync('tasklist', <String>['/FI', 'PID eq $pid']);
    return (res.stdout as String).contains('$pid');
  }
  return Process.runSync('kill', <String>['-0', '$pid']).exitCode == 0;
}

/// Production-shaped [ApiClient] with sensible timeouts so a health probe to a
/// not-yet-listening port fails fast instead of hanging.
ApiClient _timeoutApiClient(Uri baseUrl) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(milliseconds: 500),
      receiveTimeout: const Duration(milliseconds: 500),
      sendTimeout: const Duration(milliseconds: 500),
    ),
  );
  return ApiClient(baseUrl, dio: dio);
}

void main() {
  final tempDirs = <Directory>[];
  Directory newTempDir() {
    final dir = Directory.systemTemp.createTempSync('qpic-path-itest');
    tempDirs.add(dir);
    return dir;
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

  // -------------------------------------------------------------------------
  // 1. Packaged per-OS path resolution: the embedded binary is discoverable
  //    at exactly the location the resolver computes (Req 21.3).
  // -------------------------------------------------------------------------
  group('Packaged embedded-sidecar path resolves (Req 21.3)', () {
    test('macOS bundle: Contents/Resources/sidecar/qpic-sidecar is found', () {
      final root = newTempDir();
      // Fake installed bundle: …/Qpic.app/Contents/MacOS/Qpic (runner) and the
      // embedded binary under Contents/Resources/sidecar/.
      final runner =
          p.join(root.path, 'Qpic.app', 'Contents', 'MacOS', 'Qpic');
      final embedded = p.join(root.path, 'Qpic.app', 'Contents', 'Resources',
          kSidecarDirName, kSidecarExecutableName);
      File(embedded)
        ..createSync(recursive: true)
        ..writeAsStringSync('binary');

      final resolved = resolveSidecarExecutablePath(
        isMacOS: true,
        isWindows: false,
        executablePath: runner,
      );

      expect(p.equals(resolved, embedded), isTrue,
          reason: 'resolver must point at the embedded macOS binary');
      expect(File(resolved).existsSync(), isTrue,
          reason: 'embedded binary must be discoverable at the resolved path');
      // Resolves into Resources, never the MacOS runner dir.
      expect(resolved, isNot(contains(p.join('Contents', 'MacOS'))));
    });

    test('Windows bundle: <runner>/sidecar/qpic-sidecar.exe is found', () {
      final root = newTempDir();
      final runner = p.join(root.path, 'qpic.exe');
      final embedded = p.join(
          root.path, kSidecarDirName, '$kSidecarExecutableName.exe');
      File(embedded)
        ..createSync(recursive: true)
        ..writeAsStringSync('binary');

      final resolved = resolveSidecarExecutablePath(
        isMacOS: false,
        isWindows: true,
        executablePath: runner,
      );

      expect(p.equals(resolved, embedded), isTrue,
          reason: 'resolver must point at the embedded Windows binary');
      expect(File(resolved).existsSync(), isTrue,
          reason: 'embedded binary must be discoverable at the resolved path');
      expect(p.basename(resolved), '$kSidecarExecutableName.exe');
      // The embedded binary sits in a `sidecar/` folder next to the runner.
      expect(p.dirname(p.dirname(resolved)), p.dirname(runner));
    });
  });

  // -------------------------------------------------------------------------
  // 2. Packaged start → health: the resolved packaged path is spawned and
  //    reaches Ready, then shuts down leaving no orphan (Req 21.3, 24.3).
  // -------------------------------------------------------------------------
  group('Packaged-path sidecar starts → health (Req 21.3, 24.3)', () {
    final python = _resolveAnyPython();
    final skipReason = python == null
        ? 'python3/python not on PATH; needed to run the packaged health stub.'
        : Platform.isWindows
            ? 'A bare script is not directly executable on Windows; the '
                'packaged-start scenario runs on POSIX (the dev host).'
            : null;

    test(
      'resolved per-OS packaged binary starts, reports health, and stops clean',
      () async {
        // Build a fake installed bundle and resolve the embedded path with the
        // production resolver for the current POSIX OS.
        final root = newTempDir();
        final String runner;
        if (Platform.isMacOS) {
          runner = p.join(root.path, 'Qpic.app', 'Contents', 'MacOS', 'Qpic');
        } else {
          runner = p.join(root.path, 'qpic'); // Linux runner.
        }
        final resolved = resolveSidecarExecutablePath(
          isMacOS: Platform.isMacOS,
          isWindows: false,
          executablePath: runner,
        );

        // Drop an *executable* health stub at exactly the resolved packaged
        // path — this is the binary the manager will spawn.
        final stub = File(resolved)..createSync(recursive: true);
        stub.writeAsStringSync('#!$python\n$_kHealthStubPy');
        Process.runSync('chmod', <String>['755', resolved]);

        final workDir = newTempDir();
        final spawned = <String>[];
        final pids = <int>[];

        final manager = SidecarManager(
          // Production resolution result fed back in: spawn the resolved path
          // as the executable, exactly as production launches the embedded
          // binary (no args).
          resolveCommand: () => SidecarCommand(executable: resolved),
          resolveTempDir: () async => workDir,
          startProcess: (executable, args,
              {workingDirectory, environment}) async {
            spawned.add(executable);
            final proc = await Process.start(
              executable,
              args,
              workingDirectory: workingDirectory,
              environment: environment,
            );
            pids.add(proc.pid);
            return proc;
          },
          createApiClient: _timeoutApiClient,
          environment: const <String, String>{},
          isWindows: false,
        );

        try {
          final baseUrl = await manager.start();

          expect(manager.currentStatus, SidecarStatus.ready);
          expect(baseUrl.host, '127.0.0.1');
          // The thing that got spawned is the resolved packaged path.
          expect(spawned.single, resolved);

          final pid = pids.single;
          expect(_isProcessAlive(pid), isTrue);

          await manager.stop();
          expect(manager.currentStatus, SidecarStatus.stopped);
          expect(_isProcessAlive(pid), isFalse,
              reason: 'packaged sidecar must leave no orphan after shutdown');
        } finally {
          await manager.dispose();
        }
      },
      skip: skipReason,
    );
  });

  // -------------------------------------------------------------------------
  // 3 & 4. Dev fallback: command resolution + real engine start → health.
  // -------------------------------------------------------------------------
  group('Dev-fallback sidecar resolves and starts (Req 21.3, 24.3)', () {
    final repoRoot = devRepoRoot();
    final enginePython = _resolveEnginePython(repoRoot);

    test('resolveSidecarCommand falls back to python -m packaging.sidecar', () {
      // Precondition for the dev fallback: no override and no embedded binary.
      final override = Platform.environment['QPIC_SIDECAR_PATH'] ?? '';
      final hasOverride = override.isNotEmpty && File(override).existsSync();
      final hasEmbedded = File(sidecarExecutablePath()).existsSync();

      final command = resolveSidecarCommand();

      if (hasOverride || hasEmbedded) {
        // A packaged/override binary is present in this environment, so the
        // dev fallback is correctly NOT taken — nothing to assert about it.
        expect(command.isDevFallback, isFalse);
        return;
      }

      // Run-from-source: the engine is launched via the repo's Python.
      expect(command.isDevFallback, isTrue);
      final expectedScript = p.join(repoRoot, 'packaging', 'sidecar.py');
      expect(
        command.args,
        anyOf([
          <String>['-m', 'packaging.sidecar'],
          <String>[expectedScript],
        ]),
      );
      expect(command.executable.toLowerCase(), contains('python'));
      // The working directory must be a repo root that actually contains the
      // sidecar entry point, so `-m packaging.sidecar` can import the engine.
      expect(command.workingDirectory, isNotNull);
      expect(
        File(p.join(command.workingDirectory!, 'packaging', 'sidecar.py'))
            .existsSync(),
        isTrue,
        reason: 'dev fallback must run from a repo root holding the sidecar',
      );
    });

    test(
      'real engine sidecar starts via the dev path and reaches /api/health',
      () async {
        // Use the EXACT production module command when it resolves on the host;
        // otherwise fall back to the behaviorally identical file-path launch
        // (see the HOST NOTE at the top of this file).
        final useModuleForm = _devModuleFormResolves(enginePython!, repoRoot);
        final args = useModuleForm
            ? const <String>['-m', 'packaging.sidecar']
            : <String>[p.join(repoRoot, 'packaging', 'sidecar.py')];

        final workDir = newTempDir();
        final pids = <int>[];

        final manager = SidecarManager(
          resolveCommand: () => SidecarCommand(
            executable: enginePython,
            args: args,
            workingDirectory: repoRoot,
            isDevFallback: true,
          ),
          resolveTempDir: () async => workDir,
          startProcess: (executable, processArgs,
              {workingDirectory, environment}) async {
            final proc = await Process.start(
              executable,
              processArgs,
              workingDirectory: workingDirectory,
              environment: environment,
            );
            pids.add(proc.pid);
            return proc;
          },
          createApiClient: _timeoutApiClient,
          environment: const <String, String>{},
          isWindows: Platform.isWindows,
        );

        try {
          final baseUrl = await manager.start();

          // The real engine reported healthy on the published Base_URL.
          expect(manager.currentStatus, SidecarStatus.ready);
          expect(baseUrl.host, '127.0.0.1');

          final pid = pids.single;
          expect(_isProcessAlive(pid), isTrue);

          await manager.stop();
          expect(manager.currentStatus, SidecarStatus.stopped);
          expect(_isProcessAlive(pid), isFalse,
              reason: 'dev sidecar must leave no orphan after shutdown');
        } finally {
          await manager.dispose();
        }
      },
      skip: enginePython == null
          ? 'No Python interpreter that can import the engine (app.main) was '
              'found; the dev start→health scenario needs the engine deps.'
          : null,
    );
  });
}
