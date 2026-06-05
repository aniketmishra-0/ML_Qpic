// End-to-end test for the Rename Batch streamed session flow against a REAL,
// running sidecar (task 15.3 — Requirements 12.4, 12.5).
//
// Where `rename_session_flow_test.dart` proves the ordering / field-mapping of
// the session flow deterministically with a routing Dio adapter (no network),
// THIS test closes the loop against the actual Python engine: it boots the
// headless sidecar, drives the unchanged `RenameController.rename()` over real
// localhost HTTP, and asserts the whole chain end-to-end —
//
//   `POST /api/rename/session`            (create)
//     → `POST /api/rename/session/{id}/files`     (chunked upload)
//     → `POST /api/rename/session/{id}/finalize`  (pack the ZIP)
//     → `GET  /api/rename/session/{id}/download`   (streamed to disk)
//     → `DELETE /api/rename/session/{id}`          (release, Req 12.5)
//
// Verification is observable, not mocked:
//   * the engine writes a real ZIP to the chosen path (Req 12.4),
//   * the ZIP carries the client-planned output names (the `names` array the
//     controller ships on finalize is honored by the engine), and
//   * a follow-up `GET …/download` returns 404 — proving the session was
//     released by the trailing DELETE (Req 12.5).
// Finally the sidecar is terminated and confirmed to exit cleanly.
//
// Only two seams are substituted, and neither touches the engine contract:
//   * the native Save-As dialog is resolved to a temp path (no UI), and
//   * the streamed downloader records the download URL *and then performs the
//     real Dio stream to disk*, so the transfer is genuine HTTP.
//
// Launching the sidecar mirrors the design's dev fallback (`python -m
// packaging.sidecar`). As the Python integration test documents, the PyPI
// `packaging` distribution shadows the repo's namespace `packaging/` dir, so
// `-m packaging.sidecar` resolves to the wrong package; we therefore launch the
// identical entry point by file path (`packaging/sidecar.py`), which inserts the
// resource dir onto `sys.path` itself and imports the unchanged `app.main:app`.
//
// If no Python interpreter with the engine's dependencies can be started in
// this environment, the test SELF-SKIPS with a clear reason — the deterministic
// `rename_session_flow_test.dart` already provides full, hermetic coverage of
// the create → files → finalize → download → delete ordering and session
// release, so CI without a Python engine still gates the behavior.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup;
import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/core/download_service.dart';
import 'package:qpic_desktop/features/rename/rename_controller.dart';

/// A 1x1 red PNG (valid image bytes the engine can re-encode), base64-encoded.
const String _redPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

/// A 1x1 blue PNG, base64-encoded.
const String _bluePngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC';

/// A handle to a started sidecar: the live [ApiClient], the child [Process],
/// and the temp dir handed to it as `QPIC_TEMP_DIR`.
class _LiveSidecar {
  _LiveSidecar(this.process, this.apiClient, this.tempDir, this.baseUrl);

  final Process process;
  final ApiClient apiClient;
  final Directory tempDir;
  final Uri baseUrl;
}

/// Walks up from [start] looking for `packaging/sidecar.py`, returning the repo
/// root that holds it (mirrors `paths.devRepoRoot`). Falls back to the parent of
/// the `desktop/` package when no marker is found.
Directory _repoRoot() {
  final override = Platform.environment['QPIC_REPO_ROOT'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  var dir = Directory.current.absolute;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/packaging/sidecar.py').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.parent;
}

/// Candidate Python interpreters, most-specific first: an explicit override,
/// then the repo virtualenv, then the platform default on PATH.
List<String> _pythonCandidates(Directory repoRoot) {
  final candidates = <String>[];
  final override = Platform.environment['QPIC_PYTHON'];
  if (override != null && override.isNotEmpty) candidates.add(override);
  if (Platform.isWindows) {
    candidates
      ..add('${repoRoot.path}\\.venv\\Scripts\\python.exe')
      ..add('python');
  } else {
    candidates
      ..add('${repoRoot.path}/.venv/bin/python')
      ..add('python3')
      ..add('python');
  }
  return candidates;
}

/// Grabs a free localhost port the same way the SidecarManager does: bind to
/// `127.0.0.1:0`, read the assigned port, then release it.
Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// Attempts to boot the headless sidecar with [python] and poll `/api/health`
/// to ready within [budget]. Returns a [_LiveSidecar] on success, or `null`
/// (after cleaning up) when the interpreter can't bring the engine up — e.g.
/// the engine's dependencies aren't installed for that interpreter.
Future<_LiveSidecar?> _tryStart(
  String python,
  Directory repoRoot, {
  Duration budget = const Duration(seconds: 30),
}) async {
  final sidecar = File('${repoRoot.path}/packaging/sidecar.py');
  if (!sidecar.existsSync()) return null;

  final port = await _freePort();
  final tempDir = Directory.systemTemp.createTempSync('qpic-rename-live');

  Process proc;
  try {
    proc = await Process.start(
      python,
      <String>[sidecar.path],
      workingDirectory: repoRoot.path,
      environment: <String, String>{
        'QPIC_PORT': '$port',
        'QPIC_TEMP_DIR': tempDir.path,
        // Offline posture: no AI key, so nothing reaches out off-box.
        'ANTHROPIC_API_KEY': '',
        'OPENROUTER_API_KEY': '',
      },
    );
  } catch (_) {
    // Interpreter not found / not executable.
    _safeDelete(tempDir);
    return null;
  }

  // Drain stderr so a failed boot is diagnosable and the pipe never blocks.
  final stderrBuf = StringBuffer();
  proc.stderr.transform(utf8.decoder).listen(stderrBuf.write);
  unawaited(proc.stdout.drain<void>());

  final baseUrl = Uri.parse('http://127.0.0.1:$port');
  final apiClient = ApiClient(baseUrl);

  final deadline = DateTime.now().add(budget);
  var exited = false;
  unawaited(proc.exitCode.then((_) => exited = true));

  while (DateTime.now().isBefore(deadline)) {
    if (exited) break; // process died early; stop polling.
    try {
      final health = await apiClient.health();
      if (health.status == 'ok') {
        return _LiveSidecar(proc, apiClient, tempDir, baseUrl);
      }
    } catch (_) {
      // Not up yet — keep polling.
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  // Never became healthy: tear the attempt down and signal "skip".
  proc.kill(ProcessSignal.sigkill);
  await proc.exitCode
      .timeout(const Duration(seconds: 5), onTimeout: () => -1);
  _safeDelete(tempDir);
  return null;
}

/// Tries each candidate interpreter until one boots a healthy sidecar.
Future<_LiveSidecar?> _startSidecar() async {
  final repoRoot = _repoRoot();
  for (final python in _pythonCandidates(repoRoot)) {
    final live = await _tryStart(python, repoRoot);
    if (live != null) return live;
  }
  return null;
}

void _safeDelete(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {
    // Best effort — the OS reaps the system temp dir anyway.
  }
}

/// Reason surfaced when the live sidecar can't be booted in this environment.
/// The deterministic `rename_session_flow_test.dart` already covers the
/// ordering + session release hermetically, so skipping here loses no coverage.
const String _skipReason =
    'No Python engine could be started for a live sidecar; the deterministic '
    'rename_session_flow_test.dart covers the create→files→finalize→download→'
    'delete ordering and session release hermetically.';

void main() {
  _LiveSidecar? sidecar;

  setUpAll(() async {
    sidecar = await _startSidecar();
  });

  tearDownAll(() async {
    final live = sidecar;
    if (live == null) return;
    // Confirm a clean shutdown: SIGTERM, then escalate only if it lingers.
    live.process.kill(ProcessSignal.sigterm);
    final code = await live.process.exitCode
        .timeout(const Duration(seconds: 5), onTimeout: () {
      live.process.kill(ProcessSignal.sigkill);
      return -1;
    });
    expect(code, isNot(-1),
        reason: 'sidecar did not exit within the grace period');
    _safeDelete(live.tempDir);
  });

  group('Rename Batch session flow against a live sidecar (Req 12.4, 12.5)',
      () {
    test(
      'create → files → finalize → download (real ZIP) → delete releases '
      'the session',
      () async {
        final live = sidecar;
        if (live == null) {
          markTestSkipped(_skipReason);
          return;
        }

        // Capture the streamed download URL while still performing the REAL
        // Dio stream to disk, so the transfer is genuine HTTP end-to-end.
        Uri? streamedUri;
        final outDir = Directory.systemTemp.createTempSync('qpic-rename-out');
        addTearDown(() => _safeDelete(outDir));
        final savePath = '${outDir.path}/renamed_images.zip';

        final downloadService = DownloadService(
          live.apiClient,
          saveLocationResolver: ({
            required String suggestedName,
            required List<XTypeGroup> acceptedTypeGroups,
          }) async =>
              FileSaveLocation(savePath),
          downloader: (uri, path,
              {CancelToken? cancelToken,
              ProgressCallback? onReceiveProgress}) async {
            streamedUri = uri;
            await live.apiClient.dio.downloadUri(
              uri,
              path,
              cancelToken: cancelToken,
              onReceiveProgress: onReceiveProgress,
              deleteOnError: true,
            );
          },
        );

        final controller = RenameController()
          ..bindEngine(
            apiClient: live.apiClient,
            downloadService: downloadService,
          );
        addTearDown(controller.dispose);

        controller
          ..pattern = 'Q#'
          ..start = 5
          ..padding = 3
          ..downloadExcel = false
          ..outputFormat = RenameOutputFormat.png
          ..addItems(<RenameItem>[
            RenameItem(
              name: 'first.png',
              sizeBytes: 1,
              fileBytes: base64Decode(_redPngB64),
            ),
            RenameItem(
              name: 'second.png',
              sizeBytes: 1,
              fileBytes: base64Decode(_bluePngB64),
            ),
          ]);

        // The client-planned stems the controller will ship to finalize.
        final plannedStems = controller.planStems();
        expect(plannedStems, <String>['Q005', 'Q006']);

        // Run the full streamed session flow against the real engine.
        final result = await controller.rename();

        // The engine produced a ZIP that was streamed to the chosen path.
        expect(result, isNotNull);
        expect(result!.isSaved, isTrue);
        expect(result.path, savePath);
        expect(controller.errorText, isNull);

        final zip = File(savePath);
        expect(zip.existsSync(), isTrue);
        final bytes = await zip.readAsBytes();
        expect(bytes.length, greaterThan(0));
        // ZIP local-file-header magic ("PK\x03\x04").
        expect(bytes.sublist(0, 4), <int>[0x50, 0x4B, 0x03, 0x04]);

        // The `names` array the controller sent on finalize was honored: the
        // engine stored each entry under the planned stem + .png. ZIP entry
        // names live verbatim in the (uncompressed) local file headers, so a
        // byte-scan confirms them without an archive dependency.
        final text = latin1.decode(bytes);
        expect(text, contains('Q005.png'));
        expect(text, contains('Q006.png'));

        // The download went through the session's download endpoint.
        expect(streamedUri, isNotNull);
        expect(streamedUri!.path, matches(r'/api/rename/session/.+/download$'));

        // Req 12.5: the trailing DELETE released the session — a fresh GET of
        // the same download URL must now 404 (the staged dir is gone).
        await expectLater(
          live.apiClient.getBytes(streamedUri!.path),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 404)),
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'a forced jpg export renames and re-encodes through the live session',
      () async {
        final live = sidecar;
        if (live == null) {
          markTestSkipped(_skipReason);
          return;
        }

        final outDir = Directory.systemTemp.createTempSync('qpic-rename-jpg');
        addTearDown(() => _safeDelete(outDir));
        final savePath = '${outDir.path}/renamed_images.zip';

        final downloadService = DownloadService(
          live.apiClient,
          saveLocationResolver: ({
            required String suggestedName,
            required List<XTypeGroup> acceptedTypeGroups,
          }) async =>
              FileSaveLocation(savePath),
        );

        final controller = RenameController()
          ..bindEngine(
            apiClient: live.apiClient,
            downloadService: downloadService,
          );
        addTearDown(controller.dispose);

        controller
          ..pattern = 'photo-#'
          ..start = 1
          ..padding = 0
          ..downloadExcel = false
          ..outputFormat = RenameOutputFormat.jpg
          ..jpgQuality = 80
          ..addItems(<RenameItem>[
            RenameItem(
              name: 'only.png',
              sizeBytes: 1,
              fileBytes: base64Decode(_redPngB64),
            ),
          ]);

        final result = await controller.rename();

        expect(result, isNotNull);
        expect(result!.isSaved, isTrue);
        expect(controller.errorText, isNull);

        final bytes = await File(savePath).readAsBytes();
        expect(bytes.sublist(0, 4), <int>[0x50, 0x4B, 0x03, 0x04]);
        // Forced jpg export: the entry is the planned stem with a .jpg ext.
        expect(latin1.decode(bytes), contains('photo-1.jpg'));
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  });
}
