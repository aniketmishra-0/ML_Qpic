// Unit tests for SidecarBootstrap — the orchestration wrapper that gives the
// UI a single, stable lifecycle stream across engine (re)starts (task 6.2
// support).
//
// These drive real SidecarManager instances through their injectable seams
// (port selector, process starter, api-client factory, clock, sleeper) so no
// real process is spawned and no real time elapses. They assert:
//
//  * the bootstrap re-emits the current manager's SidecarStatus transitions on
//    its stable stream and reaches ready (Req 3.4);
//  * capturedStderr passes through from the active manager (Req 3.5/3.9);
//  * restart() builds a fresh manager so a previously failed startup can
//    recover (Req 3.9/3.10).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/paths.dart';
import 'package:qpic_desktop/core/sidecar_bootstrap.dart';
import 'package:qpic_desktop/core/sidecar_manager.dart';

class _FakeProcess implements Process {
  _FakeProcess({String stderrData = ''})
      : _stderr = Stream<List<int>>.value(utf8.encode(stderrData));

  final Stream<List<int>> _stderr;
  final Completer<int> _exit = Completer<int>();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }

  @override
  IOSink get stdin => throw UnimplementedError();
}

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
  final dio = Dio()..httpClientAdapter = adapter;
  return ApiClient(baseUrl, dio: dio);
}

/// Builds a manager that becomes ready, with injected seams.
SidecarManager _readyManager() {
  final adapter = _HealthAdapter(readyAfterCalls: 0);
  return SidecarManager(
    resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
    resolveTempDir: () async => Directory('/tmp/qpic/temp'),
    selectPort: () async => 50500,
    startProcess: (e, a, {workingDirectory, environment}) async =>
        _FakeProcess(stderrData: 'boot log'),
    createApiClient: (baseUrl) => _healthClient(baseUrl, adapter),
    environment: const <String, String>{},
    sleep: (_) async {},
  );
}

/// Builds a manager that always fails health and times out, with a captured
/// stderr line for diagnostics.
SidecarManager _failingManager() {
  var now = DateTime(2024, 1, 1);
  return SidecarManager(
    resolveCommand: () => const SidecarCommand(executable: 'sidecar'),
    resolveTempDir: () async => Directory('/tmp/qpic/temp'),
    selectPort: () async => 50600,
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
}

void main() {
  group('SidecarBootstrap', () {
    test('re-emits manager transitions and reaches ready', () async {
      final bootstrap = SidecarBootstrap(createManager: _readyManager);
      final statuses = <SidecarStatus>[];
      final sub = bootstrap.status.listen(statuses.add);

      await bootstrap.start();
      await pumpEventQueue();

      expect(bootstrap.currentStatus, SidecarStatus.ready);
      expect(statuses, contains(SidecarStatus.ready));
      expect(statuses.first, SidecarStatus.selectingPort);
      // Base_URL exposed once ready.
      expect(bootstrap.baseUrl, isNotNull);

      await sub.cancel();
      await bootstrap.dispose();
    });

    test('start() swallows the timeout exception and surfaces failed + stderr',
        () async {
      final bootstrap = SidecarBootstrap(createManager: _failingManager);
      final statuses = <SidecarStatus>[];
      final sub = bootstrap.status.listen(statuses.add);

      // Does not throw despite the underlying SidecarStartException.
      await bootstrap.start();
      await pumpEventQueue();

      expect(bootstrap.currentStatus, SidecarStatus.failed);
      expect(statuses, contains(SidecarStatus.failed));
      expect(bootstrap.capturedStderr, contains('Traceback: boom'));
      expect(bootstrap.baseUrl, isNull);

      await sub.cancel();
      await bootstrap.dispose();
    });

    test('restart() builds a fresh manager so a failed start can recover',
        () async {
      var built = 0;
      // First manager fails, second one succeeds.
      SidecarManager factory() {
        built++;
        return built == 1 ? _failingManager() : _readyManager();
      }

      final bootstrap = SidecarBootstrap(createManager: factory);
      final statuses = <SidecarStatus>[];
      final sub = bootstrap.status.listen(statuses.add);

      await bootstrap.start();
      await pumpEventQueue();
      expect(bootstrap.currentStatus, SidecarStatus.failed);

      await bootstrap.restart();
      await pumpEventQueue();
      expect(built, 2);
      expect(bootstrap.currentStatus, SidecarStatus.ready);
      expect(statuses, contains(SidecarStatus.ready));

      await sub.cancel();
      await bootstrap.dispose();
    });
  });
}
