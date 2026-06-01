// Unit tests for SidecarManager core lifecycle — Task 5.1.
//
// These cover the happy-path startup sequence (Req 3.1–3.4) and the basic
// 30 s-timeout failure throw, using the manager's injectable seams (port
// selector, process starter, api-client factory, clock, sleeper) so no real
// process is spawned and no real time elapses.
//
// The failure/retry/shutdown/unexpected-exit behaviors (Req 3.5–3.10) are
// task 5.2 and are intentionally NOT asserted here beyond the basic timeout.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/paths.dart';
import 'package:qpic_desktop/core/sidecar_manager.dart';

/// A fake [Process] with controllable stdout/stderr and exit code. Records
/// whether it was killed so the [SidecarManager.stop] stub can be verified.
class _FakeProcess implements Process {
  _FakeProcess({
    String stdoutData = '',
    String stderrData = '',
  })  : _stdout = Stream<List<int>>.value(utf8.encode(stdoutData)),
        _stderr = Stream<List<int>>.value(utf8.encode(stderrData));

  final Stream<List<int>> _stdout;
  final Stream<List<int>> _stderr;
  final Completer<int> _exit = Completer<int>();

  bool killed = false;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }

  @override
  IOSink get stdin => throw UnimplementedError();
}

/// A Dio adapter that returns health JSON. [readyAfterCalls] controls how many
/// probes return "starting" before the engine reports "ok"; once ready it keeps
/// returning ok. When [readyAfterCalls] is negative the engine never gets ready
/// (always returns a connection error) to exercise the timeout path.
class _HealthAdapter implements HttpClientAdapter {
  _HealthAdapter({required this.readyAfterCalls});

  final int readyAfterCalls;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final n = calls++;
    if (readyAfterCalls < 0) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'connection refused',
      );
    }
    final ready = n >= readyAfterCalls;
    final body = jsonEncode(<String, dynamic>{
      'status': ready ? 'ok' : 'starting',
      'tesseract_available': true,
      'ai_available': false,
      'version': '1.0.0',
    });
    return ResponseBody.fromString(
      body,
      ready ? 200 : 503,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _healthClient(Uri baseUrl, _HealthAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return ApiClient(baseUrl, dio: dio);
}

void main() {
  group('SidecarManager.start (happy path)', () {
    test('selects a free port, spawns, waits for health, publishes Base_URL',
        () async {
      _FakeProcess? spawned;
      String? spawnedExecutable;
      List<String>? spawnedArgs;
      Map<String, String>? spawnedEnv;
      String? spawnedCwd;

      final adapter = _HealthAdapter(readyAfterCalls: 2);

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(
          executable: '/path/to/qpic-sidecar',
        ),
        resolveTempDir: () async => Directory('/tmp/qpic/temp'),
        selectPort: () async => 50123,
        startProcess: (
          executable,
          args, {
          workingDirectory,
          environment,
        }) async {
          spawnedExecutable = executable;
          spawnedArgs = args;
          spawnedEnv = environment;
          spawnedCwd = workingDirectory;
          return spawned = _FakeProcess(stderrData: 'boot log');
        },
        createApiClient: (baseUrl) => _healthClient(baseUrl, adapter),
        environment: const <String, String>{},
        // Make polling instant.
        sleep: (_) async {},
      );

      final statuses = <SidecarStatus>[];
      final sub = manager.status.listen(statuses.add);

      final baseUrl = await manager.start();
      // The status stream is a broadcast stream that delivers events
      // asynchronously; flush pending microtasks so the final `ready` event
      // reaches the listener before we cancel.
      await pumpEventQueue();
      await sub.cancel();

      // Req 3.4: Base_URL is http://127.0.0.1:{port}.
      expect(baseUrl, Uri.parse('http://127.0.0.1:50123'));
      expect(manager.baseUrl, baseUrl);
      expect(manager.port, 50123);
      expect(manager.currentStatus, SidecarStatus.ready);

      // Req 3.2: spawned the resolved command.
      expect(spawnedExecutable, '/path/to/qpic-sidecar');
      expect(spawnedArgs, isEmpty);
      expect(spawnedCwd, isNull);
      expect(spawned, isNotNull);

      // Req 3.1/3.11: port + temp dir passed via environment.
      expect(spawnedEnv?[kQpicPortEnv], '50123');
      expect(spawnedEnv?[kQpicTempDirEnv], '/tmp/qpic/temp');
      // No TESSERACT_CMD when unset.
      expect(spawnedEnv?.containsKey(kTesseractCmdEnv), isFalse);

      // State machine order (Req 3.3 implies waitingHealth before ready).
      expect(statuses, [
        SidecarStatus.selectingPort,
        SidecarStatus.starting,
        SidecarStatus.waitingHealth,
        SidecarStatus.ready,
      ]);

      // stderr captured for diagnostics (extension point for 5.2).
      expect(manager.capturedStderr, 'boot log');

      await manager.dispose();
    });

    test('forwards TESSERACT_CMD only when set', () async {
      Map<String, String>? env;
      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory('/tmp/qpic/temp'),
        selectPort: () async => 51000,
        startProcess: (e, a, {workingDirectory, environment}) async {
          env = environment;
          return _FakeProcess();
        },
        createApiClient: (baseUrl) =>
            _healthClient(baseUrl, _HealthAdapter(readyAfterCalls: 0)),
        environment: const <String, String>{
          'TESSERACT_CMD': '/opt/tesseract/bin/tesseract',
        },
        sleep: (_) async {},
      );

      await manager.start();
      expect(env?[kTesseractCmdEnv], '/opt/tesseract/bin/tesseract');
      await manager.dispose();
    });
  });

  group('SidecarManager.start (timeout failure)', () {
    test('throws SidecarStartException with captured stderr after 30s',
        () async {
      // Deterministic clock: jumps forward by the poll interval each read so the
      // 30 s deadline is crossed without real waiting.
      var now = DateTime(2024, 1, 1);
      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory('/tmp/qpic/temp'),
        selectPort: () async => 52000,
        startProcess: (e, a, {workingDirectory, environment}) async =>
            _FakeProcess(stderrData: 'Traceback: boom'),
        createApiClient: (baseUrl) =>
            _healthClient(baseUrl, _HealthAdapter(readyAfterCalls: -1)),
        environment: const <String, String>{},
        clock: () => now,
        sleep: (d) async {
          now = now.add(d);
        },
      );

      await expectLater(
        manager.start(),
        throwsA(
          isA<SidecarStartException>()
              .having((e) => e.stderr, 'stderr', contains('Traceback: boom')),
        ),
      );
      expect(manager.currentStatus, SidecarStatus.failed);

      await manager.dispose();
    });
  });

  group('SidecarManager.baseUrl before ready', () {
    test('throws StateError until ready', () {
      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
      );
      expect(() => manager.baseUrl, throwsStateError);
    });
  });

  group('selectFreePort default (real socket)', () {
    test('returns an ephemeral port in the 1024-65535 range', () async {
      // Exercises the production port selector via a manager that fails fast on
      // health so we only observe the selected port (Req 3.1 range).
      var now = DateTime(2024, 1, 1);
      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory('/tmp/qpic/temp'),
        // selectPort uses the default real-socket implementation.
        startProcess: (e, a, {workingDirectory, environment}) async =>
            _FakeProcess(),
        createApiClient: (baseUrl) =>
            _healthClient(baseUrl, _HealthAdapter(readyAfterCalls: -1)),
        environment: const <String, String>{},
        clock: () => now,
        sleep: (d) async {
          now = now.add(d);
        },
      );

      try {
        await manager.start();
      } on SidecarStartException {
        // expected — we only care about the selected port.
      }
      expect(manager.port, isNotNull);
      expect(manager.port, greaterThanOrEqualTo(1024));
      expect(manager.port, lessThanOrEqualTo(65535));

      await manager.dispose();
    });
  });
}
