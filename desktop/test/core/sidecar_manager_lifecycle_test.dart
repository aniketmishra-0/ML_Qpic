// Unit tests for SidecarManager failure / retry / shutdown / unexpected-exit
// handling — Task 5.2 (Req 3.5, 3.6, 3.7, 3.8, 3.9, 3.10, 24.3).
//
// These drive the manager through its injectable seams (port selector, process
// starter, api-client factory, process-tree killer, lifecycle binder, clock,
// sleeper) so no real process is spawned and no real time elapses. The
// end-to-end orphan-freedom check against a real/dev sidecar is task 5.3.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/paths.dart';
import 'package:qpic_desktop/core/sidecar_manager.dart';

/// A [Process] fake whose exit is driven by the test. Records the signals it
/// receives so graceful-vs-force-kill ordering can be asserted. stderr is a
/// closed stream so the manager's stderr-drain completes deterministically.
class _ControllableProcess implements Process {
  _ControllableProcess({
    this.pid = 4242,
    String stderrData = '',
    this.exitOnSigterm = false,
  }) : _stderr = Stream<List<int>>.value(utf8.encode(stderrData));

  final Stream<List<int>> _stderr;

  /// When true, a `SIGTERM` completes the exit (a well-behaved process).
  final bool exitOnSigterm;

  final Completer<int> _exit = Completer<int>();

  /// Signals received via [kill], in order.
  final List<ProcessSignal> signals = <ProcessSignal>[];

  @override
  final int pid;

  /// Simulates the process exiting on its own (e.g. an unexpected crash).
  void completeExit([int code = 0]) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (signal == ProcessSignal.sigterm && exitOnSigterm) {
      completeExit(0);
    }
    if (signal == ProcessSignal.sigkill) {
      completeExit(-1);
    }
    return true;
  }

  @override
  IOSink get stdin => throw UnimplementedError();
}

/// A Dio adapter that reports the engine healthy only for requests targeting
/// [readyPort]; every other port "refuses" the connection, modelling a sidecar
/// that never bound (a stolen port). Lets a multi-attempt retry test express
/// "the third port is the one that succeeds".
class _PortHealthAdapter implements HttpClientAdapter {
  _PortHealthAdapter({required this.readyPort});

  final int readyPort;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.port == readyPort) {
      final body = jsonEncode(<String, dynamic>{
        'status': 'ok',
        'tesseract_available': true,
        'ai_available': false,
        'version': '1.0.0',
      });
      return ResponseBody.fromString(
        body,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    }
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _portHealthClient(Uri baseUrl, _PortHealthAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return ApiClient(baseUrl, dio: dio);
}

/// A recording [SidecarLifecycleBinder] so the app-exit wiring can be verified
/// without a real window / Flutter binding.
class _FakeBinder implements SidecarLifecycleBinder {
  Future<void> Function()? onExit;
  int bindCount = 0;
  int unbindCount = 0;

  @override
  Future<void> bind(Future<void> Function() onExit) async {
    this.onExit = onExit;
    bindCount++;
  }

  @override
  Future<void> unbind() async {
    unbindCount++;
  }
}

/// Common deterministic time controls: instant sleeps that also advance a fake
/// clock so any deadline loop is guaranteed to terminate.
({Clock clock, Sleeper sleep}) _fakeTime() {
  var now = DateTime(2024, 1, 1);
  return (
    clock: () => now,
    sleep: (Duration d) async {
      now = now.add(d);
    },
  );
}

void main() {
  group('port-conflict retry (Req 3.8, 3.9)', () {
    test('retries on a stolen port and succeeds within 3 attempts', () async {
      const readyPort = 50002;
      final ports = <int>[50000, 50001, readyPort];
      var portIndex = 0;
      final spawned = <_ControllableProcess>[];
      final adapter = _PortHealthAdapter(readyPort: readyPort);
      final time = _fakeTime();

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory.systemTemp.createTempSync('qpic'),
        selectPort: () async => ports[portIndex++],
        startProcess: (e, a, {workingDirectory, environment}) async {
          final port = int.parse(environment![kQpicPortEnv]!);
          final isReady = port == readyPort;
          final proc = _ControllableProcess(
            pid: 7000 + port,
            stderrData: isReady
                ? ''
                : 'ERROR: [Errno 48] error while attempting to bind on '
                    'address: Address already in use',
          );
          // A non-ready attempt models a bind race: the engine exits early.
          if (!isReady) proc.completeExit(1);
          spawned.add(proc);
          return proc;
        },
        createApiClient: (baseUrl) => _portHealthClient(baseUrl, adapter),
        environment: const <String, String>{},
        clock: time.clock,
        sleep: time.sleep,
      );

      final statuses = <SidecarStatus>[];
      final sub = manager.status.listen(statuses.add);

      final baseUrl = await manager.start();
      await pumpEventQueue();
      await sub.cancel();

      // Third port wins; Base_URL points at it (Req 3.8).
      expect(baseUrl, Uri.parse('http://127.0.0.1:$readyPort'));
      expect(manager.currentStatus, SidecarStatus.ready);
      expect(spawned.length, 3);
      // Re-selected a port for each retry (Req 3.8).
      expect(portIndex, 3);
      // Each failed attempt re-entered selectingPort.
      expect(
        statuses.where((s) => s == SidecarStatus.selectingPort).length,
        3,
      );

      await manager.dispose();
    });

    test('fails after exhausting 3 retries on persistent conflict (Req 3.9)',
        () async {
      var portIndex = 0;
      final spawned = <_ControllableProcess>[];
      // No port is ever ready -> every attempt sees a bind error and exits.
      final adapter = _PortHealthAdapter(readyPort: -1);
      final time = _fakeTime();

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory.systemTemp.createTempSync('qpic'),
        selectPort: () async => 50000 + portIndex++,
        startProcess: (e, a, {workingDirectory, environment}) async {
          final proc = _ControllableProcess(
            pid: 8000 + spawned.length,
            stderrData: 'ERROR: [Errno 48] Address already in use',
          );
          proc.completeExit(1);
          spawned.add(proc);
          return proc;
        },
        createApiClient: (baseUrl) => _portHealthClient(baseUrl, adapter),
        environment: const <String, String>{},
        clock: time.clock,
        sleep: time.sleep,
      );

      await expectLater(
        manager.start(),
        throwsA(
          isA<SidecarStartException>()
              .having((e) => e.message, 'message', contains('localhost port'))
              .having((e) => e.stderr, 'stderr', contains('Address already')),
        ),
      );

      // 1 initial + 3 retries = 4 launch attempts (Req 3.8 max 3 retries).
      expect(spawned.length, 4);
      expect(portIndex, 4);
      expect(manager.currentStatus, SidecarStatus.failed);

      await manager.dispose();
    });
  });

  group('clean shutdown (Req 3.6, 3.7)', () {
    test('graceful SIGTERM exit within grace period skips force-kill',
        () async {
      const port = 51000;
      final adapter = _PortHealthAdapter(readyPort: port);
      final time = _fakeTime();
      final killedTrees = <int>[];
      late _ControllableProcess proc;

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory.systemTemp.createTempSync('qpic'),
        selectPort: () async => port,
        startProcess: (e, a, {workingDirectory, environment}) async =>
            proc = _ControllableProcess(pid: 9100, exitOnSigterm: true),
        createApiClient: (baseUrl) => _portHealthClient(baseUrl, adapter),
        environment: const <String, String>{},
        isWindows: false,
        killProcessTree: (pid) async => killedTrees.add(pid),
        clock: time.clock,
        sleep: time.sleep,
      );

      await manager.start();
      await manager.stop();

      // Graceful terminate requested (Req 3.6); never escalated to force-kill.
      expect(proc.signals, contains(ProcessSignal.sigterm));
      expect(proc.signals, isNot(contains(ProcessSignal.sigkill)));
      expect(killedTrees, isEmpty);
      expect(manager.currentStatus, SidecarStatus.stopped);

      await manager.dispose();
    });

    test('force-kills the process tree when SIGTERM is ignored (Req 3.7)',
        () async {
      const port = 51001;
      final adapter = _PortHealthAdapter(readyPort: port);
      final time = _fakeTime();
      final killedTrees = <int>[];
      late _ControllableProcess proc;

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory.systemTemp.createTempSync('qpic'),
        selectPort: () async => port,
        startProcess: (e, a, {workingDirectory, environment}) async =>
            // exitOnSigterm:false -> graceful term is ignored.
            proc = _ControllableProcess(pid: 9200, exitOnSigterm: false),
        createApiClient: (baseUrl) => _portHealthClient(baseUrl, adapter),
        environment: const <String, String>{},
        isWindows: false,
        killProcessTree: (pid) async => killedTrees.add(pid),
        clock: time.clock,
        sleep: time.sleep,
      );

      await manager.start();
      await manager.stop();

      // SIGTERM first, then the process tree is force-killed (Req 3.6, 3.7).
      expect(proc.signals.first, ProcessSignal.sigterm);
      expect(killedTrees, <int>[9200]);
      expect(proc.signals, contains(ProcessSignal.sigkill));
      expect(manager.currentStatus, SidecarStatus.stopped);

      await manager.dispose();
    });
  });

  group('unexpected exit after ready (Req 3.10)', () {
    test('transitions to engineStopped when the engine dies after ready',
        () async {
      const port = 52000;
      final adapter = _PortHealthAdapter(readyPort: port);
      final time = _fakeTime();
      late _ControllableProcess proc;

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory.systemTemp.createTempSync('qpic'),
        selectPort: () async => port,
        startProcess: (e, a, {workingDirectory, environment}) async =>
            proc = _ControllableProcess(pid: 9300),
        createApiClient: (baseUrl) => _portHealthClient(baseUrl, adapter),
        environment: const <String, String>{},
        clock: time.clock,
        sleep: time.sleep,
      );

      final statuses = <SidecarStatus>[];
      final sub = manager.status.listen(statuses.add);

      await manager.start();
      expect(manager.currentStatus, SidecarStatus.ready);

      // Engine crashes on its own.
      proc.completeExit(1);
      await pumpEventQueue();
      await sub.cancel();

      expect(manager.currentStatus, SidecarStatus.engineStopped);
      expect(statuses, contains(SidecarStatus.engineStopped));

      await manager.dispose();
    });

    test('intentional stop does NOT emit engineStopped', () async {
      const port = 52001;
      final adapter = _PortHealthAdapter(readyPort: port);
      final time = _fakeTime();

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => Directory.systemTemp.createTempSync('qpic'),
        selectPort: () async => port,
        startProcess: (e, a, {workingDirectory, environment}) async =>
            _ControllableProcess(pid: 9400, exitOnSigterm: true),
        createApiClient: (baseUrl) => _portHealthClient(baseUrl, adapter),
        environment: const <String, String>{},
        isWindows: false,
        clock: time.clock,
        sleep: time.sleep,
      );

      final statuses = <SidecarStatus>[];
      final sub = manager.status.listen(statuses.add);

      await manager.start();
      await manager.stop();
      await pumpEventQueue();
      await sub.cancel();

      expect(manager.currentStatus, SidecarStatus.stopped);
      expect(statuses, isNot(contains(SidecarStatus.engineStopped)));

      await manager.dispose();
    });
  });

  group('orphan backstop: stale PID reap', () {
    test('kills and clears a stale sidecar PID on next launch', () async {
      final tempDir = Directory.systemTemp.createTempSync('qpic-pid');
      final pidFile = File(p.join(tempDir.path, kSidecarPidFileName));
      pidFile.writeAsStringSync('99999');

      final killedTrees = <int>[];
      final time = _fakeTime();

      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        resolveTempDir: () async => tempDir,
        selectPort: () async => 53000,
        startProcess: (e, a, {workingDirectory, environment}) async {
          // Exit immediately with a non-bind error so start fails fast after
          // the reap has already run.
          final proc = _ControllableProcess(
            pid: 7777,
            stderrData: 'Traceback: missing resource',
          );
          proc.completeExit(2);
          return proc;
        },
        createApiClient: (baseUrl) =>
            _portHealthClient(baseUrl, _PortHealthAdapter(readyPort: -1)),
        environment: const <String, String>{},
        isWindows: false,
        killProcessTree: (pid) async => killedTrees.add(pid),
        clock: time.clock,
        sleep: time.sleep,
      );

      await expectLater(manager.start(), throwsA(isA<SidecarStartException>()));

      // The stale child from a prior crash was reaped (Req 3.7 backstop).
      expect(killedTrees, contains(99999));
      // The live attempt re-recorded its own PID into the file.
      expect(pidFile.existsSync(), isTrue);
      expect(pidFile.readAsStringSync().trim(), '7777');

      await manager.dispose();
      tempDir.deleteSync(recursive: true);
    });
  });

  group('app-exit wiring (Req 24.3)', () {
    test('installLifecycleHandlers binds once and routes exit to stop',
        () async {
      final binder = _FakeBinder();
      final manager = SidecarManager(
        resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
        lifecycleBinder: binder,
      );

      await manager.installLifecycleHandlers();
      await manager.installLifecycleHandlers(); // idempotent
      expect(binder.bindCount, 1);
      expect(binder.onExit, isNotNull);

      // The bound exit handler drives a clean shutdown (Req 3.6, 3.7).
      await binder.onExit!();
      expect(manager.currentStatus, SidecarStatus.stopped);

      await manager.dispose();
      expect(binder.unbindCount, 1);
    });
  });
}
