// ApiClient request-construction tests — Task 4.4.
//
// ============================================================================
//  Property 1: "API contract immutability"  (Validates: Requirements 1.3)
// ============================================================================
//
// The Flutter app is a pure HTTP client of the UNCHANGED FastAPI engine. Every
// request the ApiClient builds MUST match the engine's declared contract
// exactly — the same HTTP method, the same path, the same query-parameter
// names, the same multipart/form field names, and the same JSON body field
// names — with NO field added, dropped, or renamed (Req 1.3).
//
// The "expected" sets below are transcribed VERBATIM from the engine routers
// (the source of truth) so this test doubles as a cross-reference against them:
//   * `app/routers/crop.py`   — crop_pdf, analyze_pdf, prepare_manual, snap_box,
//                               finalize_crop, download_zip
//   * `app/routers/rename.py` — rename_preview, pdf_to_images_endpoint,
//                               create_rename_session, upload_rename_files,
//                               finalize_rename_session, download_rename_session,
//                               delete_rename_session
//   * `app/routers/tools.py`  — compress_endpoint, compress_download,
//                               preflight_endpoint, preflight_fix_page_sizes,
//                               preflight_download, edit_open, edit_state,
//                               edit_page_preview, edit_apply, edit_ocr,
//                               edit_download
// and the request body schemas in `app/models/schemas.py` (SnapRequest,
// FinalizeRequest/FinalizeItem/QuestionSegment, EditApplyRequest/EditOpModel/
// OperationModel). All routers are mounted under the `/api` prefix by
// `app/main.py`.
//
// HOW THIS REALIZES PROPERTY 1 (property-based testing note):
// There is no QuickCheck/Hypothesis-style package in this project's pubspec
// (see the matching note in `dto_roundtrip_test.dart`). As that file does for
// Property 2, we realize Property 1 with a *seeded pseudo-random generator*
// (`math.Random(seed)`) that drives each endpoint with many randomized-but-
// valid argument combinations. The universal invariant asserted for EVERY
// generated input is:
//
//     the field-name set of the request the ApiClient builds (path template +
//     query names + form/multipart names + JSON body names) is INVARIANT to
//     the argument *values*, and equals the engine's declared contract — never
//     adding, dropping, or renaming a field.
//
// Because the contract must hold across all generated inputs (e.g. optional
// query params present vs. omitted, varied prefixes/flags/ids), this is a
// property test in substance: the seeded loop is the generator and the
// assertions are the property. Fixed seeds keep any failure reproducible.
//
// No real network is used: a capturing Dio interceptor records the outgoing
// RequestOptions and short-circuits with a canned engine-shaped response, so
// `options.data` is still the original FormData / JSON map at capture time.

import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qpic_desktop/core/api_client.dart';
import 'package:qpic_desktop/models/crop.dart';
import 'package:qpic_desktop/models/tools.dart';

/// Randomized cases generated per endpoint. Large enough to exercise the
/// argument space (nullable present/absent, varied values) while staying fast.
const int _iterations = 150;

const String _baseUrl = 'http://127.0.0.1:54321';

void main() {
  // ==========================================================================
  //  Health
  // ==========================================================================

  test('GET /api/health — no query, no body', () async {
    await _forEach((cap, client, r) async {
      await client.health();
      final o = cap.require();
      expect(o.method, 'GET');
      expect(o.path, '/api/health');
      expect(o.queryParameters.keys, isEmpty);
      expect(o.data, isNull);
    });
  });

  // ==========================================================================
  //  Auto Crop / Smart analyze / Manual Crop / Snap / Finalize
  // ==========================================================================

  test('POST /api/crop — exact query + multipart `file`', () async {
    await _forEach((cap, client, r) async {
      final qPages = _maybeStr(r);
      final aPages = _maybeStr(r);
      await client.crop(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
        dpi: _i(r, 72, 600),
        padding: _i(r, 0, 200),
        markerStyle: _pick(r, const ['auto', 'q', 'numbered']),
        hasQuestions: r.nextBool(),
        questionPages: qPages,
        hasAnswers: r.nextBool(),
        answerPages: aPages,
        questionPrefix: _word(r),
        solutionPrefix: _word(r),
        startNumber: _i(r, 1, 100000),
        imageFormat: _pick(r, const ['png', 'jpg']),
        jpgQuality: _i(r, 1, 100),
        useAi: r.nextBool(),
        answerSheet: r.nextBool(),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/crop');
      _expectQuery(
        o,
        required: _cropRequiredQuery,
        optional: _cropOptionalQuery,
        present: <String, bool>{
          'question_pages': qPages != null,
          'answer_pages': aPages != null,
        },
      );
      _expectMultipart(o, const {'file'});
      _expectNoFormFields(o);
    });
  });

  test('POST /api/analyze — exact query + multipart `file`', () async {
    await _forEach((cap, client, r) async {
      final qPages = _maybeStr(r);
      final aPages = _maybeStr(r);
      await client.analyze(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
        dpi: _i(r, 72, 600),
        markerStyle: _pick(r, const ['auto', 'q', 'numbered']),
        hasQuestions: r.nextBool(),
        questionPages: qPages,
        hasAnswers: r.nextBool(),
        answerPages: aPages,
        useAi: r.nextBool(),
        answerSheet: r.nextBool(),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/analyze');
      _expectQuery(
        o,
        required: _analyzeRequiredQuery,
        optional: _analyzeOptionalQuery,
        present: <String, bool>{
          'question_pages': qPages != null,
          'answer_pages': aPages != null,
        },
      );
      _expectMultipart(o, const {'file'});
      _expectNoFormFields(o);
    });
  });

  test('POST /api/prepare-manual — query `dpi` + multipart `file`', () async {
    await _forEach((cap, client, r) async {
      await client.prepareManual(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
        dpi: _i(r, 72, 600),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/prepare-manual');
      expect(o.queryParameters.keys.toSet(), const {'dpi'});
      _expectMultipart(o, const {'file'});
      _expectNoFormFields(o);
    });
  });

  test('POST /api/snap — exact JSON body keys (SnapRequest)', () async {
    await _forEach((cap, client, r) async {
      await client.snap(
        SnapRequest(
          jobId: _word(r),
          page: _i(r, 1, 50),
          xStartPct: _d(r),
          xEndPct: _d(r),
          yStartPct: _d(r),
          yEndPct: _d(r),
        ),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/snap');
      expect(_bodyKeys(o), _snapBodyKeys);
    });
  });

  test('POST /api/finalize — exact JSON body keys (FinalizeRequest)', () async {
    await _forEach((cap, client, r) async {
      final items = List<FinalizeItem>.generate(
        r.nextInt(3) + 1,
        (_) => FinalizeItem(
          qNum: _word(r),
          isSolution: r.nextBool(),
          source: _pick(r, const ['auto', 'manual']),
          segments: List<QuestionSegment>.generate(
            r.nextInt(2) + 1,
            (_) => QuestionSegment(
              page: _i(r, 1, 50),
              yStartPct: _d(r),
              yEndPct: _d(r),
              xStartPct: _d(r),
              xEndPct: _d(r),
            ),
          ),
        ),
      );
      await client.finalize(
        FinalizeRequest(
          jobId: _word(r),
          items: items,
          dpi: _i(r, 72, 600),
          padding: _i(r, 0, 200),
          questionPrefix: _word(r),
          solutionPrefix: _word(r),
          startNumber: _i(r, 1, 100000),
          imageFormat: _pick(r, const ['png', 'jpg', 'jpeg']),
          jpgQuality: _i(r, 1, 100),
          answerSheet: r.nextBool(),
        ),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/finalize');
      expect(_bodyKeys(o), _finalizeBodyKeys);

      // Nested item + segment field names are part of the contract too.
      final body = o.data as Map<String, dynamic>;
      final bodyItems = (body['items'] as List<dynamic>).cast<Map<String, dynamic>>();
      for (final it in bodyItems) {
        expect(it.keys.toSet(), _finalizeItemKeys);
        final segs = (it['segments'] as List<dynamic>).cast<Map<String, dynamic>>();
        for (final s in segs) {
          expect(s.keys.toSet(), _segmentKeys);
        }
      }
    });
  });

  test('GET /api/crop/download/{job_id} — path + exact query keys', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0xC0FFEE);
    for (var i = 0; i < _iterations; i++) {
      final jobId = _word(r);
      final uri = client.cropDownloadUri(
        jobId,
        kind: _pick(r, const ['combined', 'questions', 'solutions']),
        questionPrefix: _word(r),
        solutionPrefix: _word(r),
      );
      expect(uri.path, '/api/crop/download/$jobId');
      expect(uri.queryParameters.keys.toSet(),
          const {'kind', 'question_prefix', 'solution_prefix'});
    }
  });

  test('GET /api/analyze/{job_id}/page/{page_no} — preview path', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0xA11);
    for (var i = 0; i < _iterations; i++) {
      final jobId = _word(r);
      final pageNo = _i(r, 1, 9999);
      final uri = client.analyzePagePreviewUri(jobId, pageNo);
      expect(uri.path, '/api/analyze/$jobId/page/$pageNo');
      expect(uri.queryParameters.keys, isEmpty);
    }
  });

  // ==========================================================================
  //  Rename Batch
  // ==========================================================================

  test('POST /api/rename/preview — form `names[],pattern,start,padding`',
      () async {
    await _forEach((cap, client, r) async {
      final names =
          List<String>.generate(r.nextInt(4) + 1, (_) => '${_word(r)}.png');
      await client.renamePreview(
        names: names,
        pattern: _word(r),
        start: _i(r, 0, 1000000),
        padding: _i(r, 0, 12),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/rename/preview');
      // `names` is sent once per entry (repeated form field) — the set of
      // distinct field NAMES is what the contract pins down.
      _expectFormFields(o, const {'names', 'pattern', 'start', 'padding'});
      _expectNoMultipart(o);
      // Every `names` value must be carried (no entry dropped).
      final nameFields =
          (o.data as FormData).fields.where((e) => e.key == 'names').length;
      expect(nameFields, names.length);
    });
  });

  test('POST /api/rename/pdf-to-images — multipart `file`', () async {
    await _forEach((cap, client, r) async {
      await client.renamePdfToImages(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/rename/pdf-to-images');
      _expectMultipart(o, const {'file'});
      _expectNoFormFields(o);
    });
  });

  test('POST /api/rename/session — no body', () async {
    await _forEach((cap, client, r) async {
      await client.createRenameSession();
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/rename/session');
      expect(o.queryParameters.keys, isEmpty);
      expect(o.data, isNull);
    });
  });

  test('POST /api/rename/session/{id}/files — multipart `files`', () async {
    await _forEach((cap, client, r) async {
      final sessionId = _word(r);
      final files = List<ApiUploadFile>.generate(
        r.nextInt(3) + 1,
        (_) => ApiUploadFile(bytes: _bytes(r), filename: '${_word(r)}.png'),
      );
      await client.uploadRenameFiles(sessionId: sessionId, files: files);
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/rename/session/$sessionId/files');
      _expectMultipart(o, const {'files'});
      _expectNoFormFields(o);
      // Each file is carried under the same `files` field (none dropped).
      final fileFields =
          (o.data as FormData).files.where((e) => e.key == 'files').length;
      expect(fileFields, files.length);
    });
  });

  test('POST /api/rename/session/{id}/finalize — exact form fields', () async {
    await _forEach((cap, client, r) async {
      final sessionId = _word(r);
      final names = r.nextBool()
          ? List<String>.generate(r.nextInt(3) + 1, (_) => _word(r))
          : null;
      await client.finalizeRenameSession(
        sessionId: sessionId,
        pattern: _word(r),
        start: _i(r, 0, 1000000),
        padding: _i(r, 0, 12),
        names: names,
        outputFormat: _pick(r, const ['original', 'png', 'jpg', 'jpeg', 'webp']),
        jpgQuality: _i(r, 1, 100),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/rename/session/$sessionId/finalize');
      _expectFormFieldSet(
        o,
        required: _renameFinalizeRequiredForm,
        optional: _renameFinalizeOptionalForm,
        present: <String, bool>{'names': names != null},
      );
      _expectNoMultipart(o);
    });
  });

  test('GET /api/rename/session/{id}/download — path', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0xD0E);
    for (var i = 0; i < _iterations; i++) {
      final id = _word(r);
      final uri = client.renameSessionDownloadUri(id);
      expect(uri.path, '/api/rename/session/$id/download');
      expect(uri.queryParameters.keys, isEmpty);
    }
  });

  test('DELETE /api/rename/session/{id} — path', () async {
    await _forEach((cap, client, r) async {
      final id = _word(r);
      await client.deleteRenameSession(id);
      final o = cap.require();
      expect(o.method, 'DELETE');
      expect(o.path, '/api/rename/session/$id');
      expect(o.queryParameters.keys, isEmpty);
    });
  });

  // ==========================================================================
  //  Tools — Compress
  // ==========================================================================

  test('POST /api/tools/compress — form `level`(+`target_mb`?) + `file`',
      () async {
    await _forEach((cap, client, r) async {
      final targetMb = r.nextBool() ? _d(r, maxv: 50) + 0.5 : null;
      await client.compress(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
        level: _pick(r, const ['light', 'balanced', 'strong', 'extreme']),
        targetMb: targetMb,
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/tools/compress');
      _expectFormFieldSet(
        o,
        required: const {'level'},
        optional: const {'target_mb'},
        present: <String, bool>{'target_mb': targetMb != null},
      );
      _expectMultipart(o, const {'file'});
    });
  });

  test('GET /api/tools/compress/download/{job_id} — path', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0xC4);
    for (var i = 0; i < _iterations; i++) {
      final id = _word(r);
      final uri = client.compressDownloadUri(id);
      expect(uri.path, '/api/tools/compress/download/$id');
      expect(uri.queryParameters.keys, isEmpty);
    }
  });

  // ==========================================================================
  //  Tools — Preflight
  // ==========================================================================

  test('POST /api/tools/preflight — multipart `file`', () async {
    await _forEach((cap, client, r) async {
      await client.preflight(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/tools/preflight');
      _expectMultipart(o, const {'file'});
      _expectNoFormFields(o);
    });
  });

  test('POST /api/tools/preflight/fix-page-sizes — form + `file`', () async {
    await _forEach((cap, client, r) async {
      await client.preflightFixPageSizes(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
        target: _pick(r, const ['auto', 'max', 'a4', 'letter', 'custom:210x297']),
        fillMode: _pick(r, const ['fit', 'stretch']),
        skipPages: _pick(r, const ['', '2,5', '10-12']),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/tools/preflight/fix-page-sizes');
      _expectFormFields(o, const {'target', 'fill_mode', 'skip_pages'});
      _expectMultipart(o, const {'file'});
    });
  });

  test('GET /api/tools/preflight/download/{job_id} — path', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0x9F1);
    for (var i = 0; i < _iterations; i++) {
      final id = _word(r);
      final uri = client.preflightDownloadUri(id);
      expect(uri.path, '/api/tools/preflight/download/$id');
      expect(uri.queryParameters.keys, isEmpty);
    }
  });

  // ==========================================================================
  //  Tools — Edit + OCR
  // ==========================================================================

  test('POST /api/tools/edit/open — multipart `file`', () async {
    await _forEach((cap, client, r) async {
      await client.editOpen(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/tools/edit/open');
      _expectMultipart(o, const {'file'});
      _expectNoFormFields(o);
    });
  });

  test('GET /api/tools/edit/{job_id}/state — path', () async {
    await _forEach((cap, client, r) async {
      final id = _word(r);
      await client.editState(id);
      final o = cap.require();
      expect(o.method, 'GET');
      expect(o.path, '/api/tools/edit/$id/state');
      expect(o.queryParameters.keys, isEmpty);
    });
  });

  test('GET /api/tools/edit/{job_id}/page/{page_no} — preview path', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0xED17);
    for (var i = 0; i < _iterations; i++) {
      final id = _word(r);
      final pageNo = _i(r, 1, 9999);
      final uri = client.editPagePreviewUri(id, pageNo);
      expect(uri.path, '/api/tools/edit/$id/page/$pageNo');
      expect(uri.queryParameters.keys, isEmpty);
    }
  });

  test('POST /api/tools/edit/apply — exact JSON body keys (EditApplyRequest)',
      () async {
    await _forEach((cap, client, r) async {
      final edits = List<EditOpModel>.generate(
        r.nextInt(3),
        (_) => EditOpModel(
          page: _i(r, 1, 50),
          bbox: _bbox(r),
          newText: _word(r),
          font: _maybeStr(r),
          size: r.nextBool() ? _d(r, maxv: 72) : null,
          color: r.nextBool() ? _i(r, 0, 16777215) : null,
        ),
      );
      final ops = List<OperationModel>.generate(
        r.nextInt(3),
        (_) => OperationModel(
          type: _pick(r, const ['edit_text', 'add_text', 'erase']),
          page: _i(r, 1, 50),
          bbox: _bbox(r),
          text: _word(r),
        ),
      );
      await client.editApply(
        EditApplyRequest(jobId: _word(r), edits: edits, operations: ops),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/tools/edit/apply');
      expect(_bodyKeys(o), _editApplyBodyKeys);

      final body = o.data as Map<String, dynamic>;
      for (final e in (body['edits'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        expect(e.keys.toSet(), _editOpKeys);
      }
      for (final op in (body['operations'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        expect(op.keys.toSet(), _operationKeys);
      }
    });
  });

  test('POST /api/tools/edit/ocr — form `languages,dpi` + `file`', () async {
    await _forEach((cap, client, r) async {
      await client.editOcr(
        fileBytes: _bytes(r),
        filename: '${_word(r)}.pdf',
        languages: _pick(r, const ['', 'eng', 'eng+hin', 'osd']),
        dpi: _i(r, 150, 600),
      );
      final o = cap.require();
      expect(o.method, 'POST');
      expect(o.path, '/api/tools/edit/ocr');
      _expectFormFields(o, const {'languages', 'dpi'});
      _expectMultipart(o, const {'file'});
    });
  });

  test('GET /api/tools/edit/download/{job_id} — path', () {
    final client = ApiClient(Uri.parse(_baseUrl));
    final r = math.Random(0xED0D);
    for (var i = 0; i < _iterations; i++) {
      final id = _word(r);
      final uri = client.editDownloadUri(id);
      expect(uri.path, '/api/tools/edit/download/$id');
      expect(uri.queryParameters.keys, isEmpty);
    }
  });
}

// ===========================================================================
//  Engine contract field-name sets (transcribed from the routers / schemas)
// ===========================================================================

// POST /api/crop — crop_pdf query params (app/routers/crop.py).
const Set<String> _cropRequiredQuery = {
  'dpi',
  'padding',
  'marker_style',
  'has_questions',
  'has_answers',
  'question_prefix',
  'solution_prefix',
  'start_number',
  'image_format',
  'jpg_quality',
  'use_ai',
  'answer_sheet',
};
const Set<String> _cropOptionalQuery = {'question_pages', 'answer_pages'};

// POST /api/analyze — analyze_pdf query params (app/routers/crop.py).
const Set<String> _analyzeRequiredQuery = {
  'dpi',
  'marker_style',
  'has_questions',
  'has_answers',
  'use_ai',
  'answer_sheet',
};
const Set<String> _analyzeOptionalQuery = {'question_pages', 'answer_pages'};

// SnapRequest (app/models/schemas.py).
const Set<String> _snapBodyKeys = {
  'job_id',
  'page',
  'x_start_pct',
  'x_end_pct',
  'y_start_pct',
  'y_end_pct',
};

// FinalizeRequest / FinalizeItem / QuestionSegment (app/models/schemas.py).
const Set<String> _finalizeBodyKeys = {
  'job_id',
  'items',
  'dpi',
  'padding',
  'question_prefix',
  'solution_prefix',
  'start_number',
  'image_format',
  'jpg_quality',
  'answer_sheet',
};
const Set<String> _finalizeItemKeys = {
  'q_num',
  'is_solution',
  'segments',
  'source',
};
const Set<String> _segmentKeys = {
  'page',
  'y_start_pct',
  'y_end_pct',
  'x_start_pct',
  'x_end_pct',
};

// POST /api/rename/session/{id}/finalize — finalize_rename_session form fields.
const Set<String> _renameFinalizeRequiredForm = {
  'pattern',
  'start',
  'padding',
  'output_format',
  'jpg_quality',
};
const Set<String> _renameFinalizeOptionalForm = {'names'};

// EditApplyRequest / EditOpModel / OperationModel (app/models/schemas.py).
const Set<String> _editApplyBodyKeys = {'job_id', 'edits', 'operations'};
const Set<String> _editOpKeys = {
  'page',
  'bbox',
  'new_text',
  'font',
  'size',
  'color',
};
const Set<String> _operationKeys = {
  'type',
  'page',
  'bbox',
  'text',
  'font',
  'size',
  'color',
  'bold',
  'italic',
  'align',
  'image_b64',
  'url',
  'fill',
};

// ===========================================================================
//  Capturing harness
// ===========================================================================

/// Records the last outgoing request and short-circuits with a canned response.
class _Capture {
  RequestOptions? last;

  RequestOptions require() {
    final o = last;
    expect(o, isNotNull, reason: 'no request was captured');
    return o!;
  }
}

/// Captures the raw [RequestOptions] (so `data` is still the FormData / JSON
/// map) and resolves with a generic engine-shaped body so the ApiClient's
/// `fromJson` parse succeeds without any real network call.
class _CapturingInterceptor extends Interceptor {
  _CapturingInterceptor(this.capture);

  final _Capture capture;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    capture.last = options;
    handler.resolve(
      Response<dynamic>(
        requestOptions: options,
        statusCode: 200,
        data: _megaResponse,
      ),
    );
  }
}

/// A superset of every response DTO's fields. `fromJson` reads only the keys it
/// needs and ignores the rest, so this one body satisfies every endpoint.
/// Lists/maps are empty so no nested object needs to be well-formed.
final Map<String, dynamic> _megaResponse = <String, dynamic>{
  // HealthResponse
  'status': 'ok',
  'tesseract_available': true,
  'ai_available': false,
  'version': '2.0.0',
  // CropResponse / common
  'job_id': 'job',
  'total_questions': 0,
  'stitched_questions': 0,
  'method_used': 'text',
  'download_url': '/api/x',
  // AnalyzeResponse
  'total_pages': 0,
  'pages': <dynamic>[],
  'items': <dynamic>[],
  'notes': <dynamic>[],
  'needs_review': false,
  // SnapResponse
  'x_start_pct': 0.0,
  'x_end_pct': 0.0,
  'y_start_pct': 0.0,
  'y_end_pct': 0.0,
  // Rename
  'count': 0,
  'images': <dynamic>[],
  'session_id': 'sess',
  'received': 0,
  'total': 0,
  // Compress
  'original_size': 0,
  'compressed_size': 0,
  'ratio': 0.0,
  'level': 'balanced',
  // Preflight
  'verdict': 'pass',
  'page_count': 0,
  'page_sizes': <dynamic>[],
  'file_size': 0,
  'is_encrypted': false,
  'has_text_layer': false,
  'checks': <dynamic>[],
  'fonts': <dynamic>[],
  'metadata': <String, dynamic>{},
  // PreflightFixResponse
  'target_label': 'A4',
  'target_width': 0.0,
  'target_height': 0.0,
  'pages_total': 0,
  'pages_changed': 0,
  'note': '',
  // EditExtractResponse
  'has_text': false,
  'spans': <dynamic>[],
  // EditApplyResponse
  'edits_applied': 0,
  // OcrResponse
  'pages_ocred': 0,
  'languages': 'eng',
};

/// Builds a fresh client wired to a capturing interceptor, then runs [body]
/// across [_iterations] seeded cases. Each iteration gets its own client +
/// capture so a stale request can never leak between cases.
Future<void> _forEach(
  Future<void> Function(_Capture cap, ApiClient client, math.Random r) body,
) async {
  for (var i = 0; i < _iterations; i++) {
    final cap = _Capture();
    final dio = Dio()..interceptors.add(_CapturingInterceptor(cap));
    final client = ApiClient(Uri.parse(_baseUrl), dio: dio);
    await body(cap, client, math.Random(0x5EED + i));
  }
}

// ===========================================================================
//  Request-shape assertions
// ===========================================================================

Set<String> _bodyKeys(RequestOptions o) =>
    (o.data as Map<String, dynamic>).keys.toSet();

/// Asserts the query carries every [required] name, no name outside
/// [required] ∪ [optional], and each [present] optional name iff its arg
/// was supplied — i.e. nothing added, dropped, or renamed.
void _expectQuery(
  RequestOptions o, {
  required Set<String> required,
  Set<String> optional = const <String>{},
  Map<String, bool> present = const <String, bool>{},
}) {
  final keys = o.queryParameters.keys.toSet();
  expect(keys.containsAll(required), isTrue,
      reason: 'dropped required query keys: ${required.difference(keys)}');
  final allowed = <String>{...required, ...optional};
  expect(allowed.containsAll(keys), isTrue,
      reason: 'added/renamed query keys: ${keys.difference(allowed)}');
  present.forEach((name, isPresent) {
    expect(keys.contains(name), isPresent,
        reason: 'optional query `$name` presence mismatch');
  });
}

FormData _form(RequestOptions o) {
  expect(o.data, isA<FormData>(),
      reason: 'expected a multipart/form body, got ${o.data.runtimeType}');
  return o.data as FormData;
}

void _expectFormFields(RequestOptions o, Set<String> expected) {
  expect(_form(o).fields.map((e) => e.key).toSet(), expected);
}

/// Like [_expectFormFields] but tolerant of optional fields, mirroring
/// [_expectQuery]'s subset/superset checks.
void _expectFormFieldSet(
  RequestOptions o, {
  required Set<String> required,
  Set<String> optional = const <String>{},
  Map<String, bool> present = const <String, bool>{},
}) {
  final keys = _form(o).fields.map((e) => e.key).toSet();
  expect(keys.containsAll(required), isTrue,
      reason: 'dropped required form fields: ${required.difference(keys)}');
  final allowed = <String>{...required, ...optional};
  expect(allowed.containsAll(keys), isTrue,
      reason: 'added/renamed form fields: ${keys.difference(allowed)}');
  present.forEach((name, isPresent) {
    expect(keys.contains(name), isPresent,
        reason: 'optional form field `$name` presence mismatch');
  });
}

void _expectMultipart(RequestOptions o, Set<String> expected) {
  expect(_form(o).files.map((e) => e.key).toSet(), expected);
}

void _expectNoFormFields(RequestOptions o) {
  expect(_form(o).fields, isEmpty,
      reason: 'unexpected form fields: '
          '${_form(o).fields.map((e) => e.key).toList()}');
}

void _expectNoMultipart(RequestOptions o) {
  expect(_form(o).files, isEmpty,
      reason: 'unexpected multipart files: '
          '${_form(o).files.map((e) => e.key).toList()}');
}

// ===========================================================================
//  Seeded value generators
// ===========================================================================

const String _wordChars =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

String _word(math.Random r) {
  final len = 1 + r.nextInt(10);
  return List.generate(len, (_) => _wordChars[r.nextInt(_wordChars.length)])
      .join();
}

int _i(math.Random r, int min, int max) => min + r.nextInt(max - min + 1);

double _d(math.Random r, {double maxv = 100.0}) =>
    r.nextInt((maxv * 100).round() + 1) / 100.0;

List<int> _bytes(math.Random r) =>
    List<int>.generate(1 + r.nextInt(16), (_) => r.nextInt(256));

List<double> _bbox(math.Random r) =>
    [_d(r, maxv: 600), _d(r, maxv: 900), _d(r, maxv: 600), _d(r, maxv: 900)];

String? _maybeStr(math.Random r) => r.nextBool() ? _word(r) : null;

T _pick<T>(math.Random r, List<T> xs) => xs[r.nextInt(xs.length)];
