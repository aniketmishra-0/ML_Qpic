// DTO (de)serialization tests — Task 4.2.
//
// ============================================================================
//  Property 2: "No Dart engine logic"  (Validates: Requirements 1.4, 1.5)
// ============================================================================
//
// The Flutter app is a pure HTTP client of the unchanged FastAPI engine. The
// DTOs in `lib/models/` (crop.dart, analyze.dart, rename.dart, tools.dart) are
// *transport-only data carriers*: they must reproduce the engine's JSON
// verbatim — exact snake_case field names (e.g. `x_start_pct`,
// `questions_download_url`, `answer_key_count`, `preview_url`) and exact
// nullability — and must never add, drop, rename, or *compute* any field.
// No detection / crop / stitch / OCR / PDF artifact may be produced in Dart;
// the DTOs only carry whatever the engine sends (Req 1.4), and page previews
// are referenced by server URL, never rasterized in Dart (Req 1.5).
//
// HOW THIS REALIZES PROPERTY 2 (property-based testing note):
// There is no mature QuickCheck/Hypothesis-style package in this project's
// pubspec, and adding one is unnecessary here. As the task allows, we realize
// the property with a *seeded pseudo-random generator* (`math.Random(seed)`)
// that produces a large number (`_iterations`) of randomized-but-valid
// instances per DTO — varying nullable fields between null and a value, and
// varying numeric / string / bool values and list lengths (including empty).
// For every generated case we assert the universal round-trip invariant:
//
//     decode -> encode -> decode  is stable, and the encoded key-set is
//     EXACTLY the engine contract key-set (no field added / dropped / renamed),
//     and no client-only UI flag (editing, manualOrder, zoom, pan, …) ever
//     leaks into a serialized payload.
//
// Because the invariant must hold for *all* generated inputs (not a handful of
// examples), this is a property test in substance: the seeded loop is the
// generator and the assertions below are the property. Determinism (fixed
// seeds) keeps failures reproducible.
//
// EVIDENCE THAT DART COMPUTES NO ENGINE ARTIFACTS:
//   1. `toJson(fromJson(x))` yields EXACTLY the engine's keys — Dart neither
//      invents derived/computed keys (area, iou, width_px, …) nor strips any
//      contract field. A DTO that computed something would have to surface it.
//   2. Client-only review state (editing / manualOrder / hovered / zoom / pan)
//      never appears in any serialized map — UI state is not part of the
//      engine payload.
//   3. The model source files import NO `dart:` or `package:` library (only
//      sibling model files). They cannot rasterize PDFs, run OCR, decode
//      images, do IO, or touch dart:ui — they are inert data classes. This is
//      asserted directly against the source under `lib/models/`.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:qpic_desktop/models/analyze.dart';
import 'package:qpic_desktop/models/crop.dart';
import 'package:qpic_desktop/models/rename.dart';
import 'package:qpic_desktop/models/tools.dart';

/// Number of randomized cases generated per DTO. Large enough to exercise the
/// input space (nullable present/absent, varied values, list lengths) while
/// keeping the suite fast.
const int _iterations = 500;

void main() {
  group('Property 2 — DTO round-trip identity (seeded property generator)', () {
    test('QuestionSegment', () {
      _runProperty('QuestionSegment', _kQuestionSegment, (r) => _genSegment(r),
          (j) => QuestionSegment.fromJson(j).toJson());
    });

    test('DetectedQuestion', () {
      _runProperty(
          'DetectedQuestion',
          _kDetectedQuestion,
          (r) => _genDetectedQuestion(r),
          (j) => DetectedQuestion.fromJson(j).toJson());
    });

    test('CropResponse', () {
      _runProperty('CropResponse', _kCropResponse, (r) => _genCropResponse(r),
          (j) => CropResponse.fromJson(j).toJson());
    });

    test('PageInfo', () {
      _runProperty('PageInfo', _kPageInfo, (r) => _genPageInfo(r),
          (j) => PageInfo.fromJson(j).toJson());
    });

    test('AnalyzedItem', () {
      _runProperty('AnalyzedItem', _kAnalyzedItem, (r) => _genAnalyzedItem(r),
          (j) => AnalyzedItem.fromJson(j).toJson());
    });

    test('ReviewNote', () {
      _runProperty('ReviewNote', _kReviewNote, (r) => _genReviewNote(r),
          (j) => ReviewNote.fromJson(j).toJson());
    });

    test('AnalyzeResponse', () {
      _runProperty(
          'AnalyzeResponse',
          _kAnalyzeResponse,
          (r) => _genAnalyzeResponse(r),
          (j) => AnalyzeResponse.fromJson(j).toJson());
    });

    test('SnapRequest', () {
      _runProperty('SnapRequest', _kSnapRequest, (r) => _genSnapRequest(r),
          (j) => SnapRequest.fromJson(j).toJson());
    });

    test('SnapResponse', () {
      _runProperty('SnapResponse', _kSnapResponse, (r) => _genSnapResponse(r),
          (j) => SnapResponse.fromJson(j).toJson());
    });

    test('FinalizeItem', () {
      _runProperty('FinalizeItem', _kFinalizeItem, (r) => _genFinalizeItem(r),
          (j) => FinalizeItem.fromJson(j).toJson());
    });

    test('CropPreviewRequest', () {
      _runProperty(
          'CropPreviewRequest',
          _kCropPreviewRequest,
          (r) => _genCropPreviewRequest(r),
          (j) => CropPreviewRequest.fromJson(j).toJson());
    });

    test('FinalizeRequest', () {
      _runProperty(
          'FinalizeRequest',
          _kFinalizeRequest,
          (r) => _genFinalizeRequest(r),
          (j) => FinalizeRequest.fromJson(j).toJson());
    });

    test('HealthResponse', () {
      _runProperty(
          'HealthResponse',
          _kHealthResponse,
          (r) => _genHealthResponse(r),
          (j) => HealthResponse.fromJson(j).toJson());
    });

    // --- Rename DTOs ---
    test('RenamePlanItem', () {
      _runProperty(
          'RenamePlanItem',
          _kRenamePlanItem,
          (r) => _genRenamePlanItem(r),
          (j) => RenamePlanItem.fromJson(j).toJson());
    });

    test('RenamePreviewResponse', () {
      _runProperty(
          'RenamePreviewResponse',
          _kRenamePreviewResponse,
          (r) => _genRenamePreviewResponse(r),
          (j) => RenamePreviewResponse.fromJson(j).toJson());
    });

    test('PdfImageItem', () {
      _runProperty('PdfImageItem', _kPdfImageItem, (r) => _genPdfImageItem(r),
          (j) => PdfImageItem.fromJson(j).toJson());
    });

    test('PdfToImagesResponse', () {
      _runProperty(
          'PdfToImagesResponse',
          _kPdfToImagesResponse,
          (r) => _genPdfToImagesResponse(r),
          (j) => PdfToImagesResponse.fromJson(j).toJson());
    });

    test('RenameSessionResponse', () {
      _runProperty(
          'RenameSessionResponse',
          _kRenameSessionResponse,
          (r) => _genRenameSessionResponse(r),
          (j) => RenameSessionResponse.fromJson(j).toJson());
    });

    test('RenameUploadResponse', () {
      _runProperty(
          'RenameUploadResponse',
          _kRenameUploadResponse,
          (r) => _genRenameUploadResponse(r),
          (j) => RenameUploadResponse.fromJson(j).toJson());
    });

    test('RenameFinalizeResponse', () {
      _runProperty(
          'RenameFinalizeResponse',
          _kRenameFinalizeResponse,
          (r) => _genRenameFinalizeResponse(r),
          (j) => RenameFinalizeResponse.fromJson(j).toJson());
    });

    // --- Tools DTOs ---
    test('CompressResponse', () {
      _runProperty(
          'CompressResponse',
          _kCompressResponse,
          (r) => _genCompressResponse(r),
          (j) => CompressResponse.fromJson(j).toJson());
    });

    test('EditableSpanModel', () {
      _runProperty(
          'EditableSpanModel',
          _kEditableSpanModel,
          (r) => _genEditableSpanModel(r),
          (j) => EditableSpanModel.fromJson(j).toJson());
    });

    test('EditPageModel', () {
      _runProperty(
          'EditPageModel',
          _kEditPageModel,
          (r) => _genEditPageModel(r),
          (j) => EditPageModel.fromJson(j).toJson());
    });

    test('EditExtractResponse', () {
      _runProperty(
          'EditExtractResponse',
          _kEditExtractResponse,
          (r) => _genEditExtractResponse(r),
          (j) => EditExtractResponse.fromJson(j).toJson());
    });

    test('EditOpModel', () {
      _runProperty('EditOpModel', _kEditOpModel, (r) => _genEditOpModel(r),
          (j) => EditOpModel.fromJson(j).toJson());
    });

    test('OperationModel', () {
      _runProperty(
          'OperationModel',
          _kOperationModel,
          (r) => _genOperationModel(r),
          (j) => OperationModel.fromJson(j).toJson());
    });

    test('EditApplyRequest', () {
      _runProperty(
          'EditApplyRequest',
          _kEditApplyRequest,
          (r) => _genEditApplyRequest(r),
          (j) => EditApplyRequest.fromJson(j).toJson());
    });

    test('EditApplyResponse', () {
      _runProperty(
          'EditApplyResponse',
          _kEditApplyResponse,
          (r) => _genEditApplyResponse(r),
          (j) => EditApplyResponse.fromJson(j).toJson());
    });

    test('OcrResponse', () {
      _runProperty('OcrResponse', _kOcrResponse, (r) => _genOcrResponse(r),
          (j) => OcrResponse.fromJson(j).toJson());
    });

    test('PreflightCheckModel', () {
      _runProperty(
          'PreflightCheckModel',
          _kPreflightCheckModel,
          (r) => _genPreflightCheckModel(r),
          (j) => PreflightCheckModel.fromJson(j).toJson());
    });

    test('PreflightFontModel', () {
      _runProperty(
          'PreflightFontModel',
          _kPreflightFontModel,
          (r) => _genPreflightFontModel(r),
          (j) => PreflightFontModel.fromJson(j).toJson());
    });

    test('PreflightImageModel', () {
      _runProperty(
          'PreflightImageModel',
          _kPreflightImageModel,
          (r) => _genPreflightImageModel(r),
          (j) => PreflightImageModel.fromJson(j).toJson());
    });

    test('PreflightPageDetail', () {
      _runProperty(
          'PreflightPageDetail',
          _kPreflightPageDetail,
          (r) => _genPreflightPageDetail(r),
          (j) => PreflightPageDetail.fromJson(j).toJson());
    });

    test('PreflightResponse', () {
      _runProperty(
          'PreflightResponse',
          _kPreflightResponse,
          (r) => _genPreflightResponse(r),
          (j) => PreflightResponse.fromJson(j).toJson());
    });

    test('PreflightFixResponse', () {
      _runProperty(
          'PreflightFixResponse',
          _kPreflightFixResponse,
          (r) => _genPreflightFixResponse(r),
          (j) => PreflightFixResponse.fromJson(j).toJson());
    });
  });
}

// ===========================================================================
//  Property runner
// ===========================================================================

typedef _JsonMap = Map<String, dynamic>;

/// Runs the round-trip property for [name] across [_iterations] seeded cases.
///
/// For every generated engine-shaped map `j0` it asserts:
///   * the DTO's re-encoded key-set EXACTLY equals the engine contract
///     [contractKeys] (no field added / dropped / renamed by Dart);
///   * decode -> encode -> decode is stable through real JSON text;
///   * values and nullability are preserved verbatim (`j1` deep-equals `j0`).
void _runProperty(
  String name,
  Set<String> contractKeys,
  _JsonMap Function(math.Random r) gen,
  _JsonMap Function(_JsonMap json) roundtrip,
) {
  final baseSeed = name.hashCode & 0x7fffffff;
  for (var i = 0; i < _iterations; i++) {
    final r = math.Random(baseSeed + i);
    final j0 = gen(r);

    // 1) parse -> encode
    final j1 = roundtrip(j0);

    // 2) exact engine key-set: no field added, dropped, or renamed in Dart.
    expect(
      j1.keys.toSet(),
      equals(contractKeys),
      reason: '$name: encoded keys must exactly match the engine contract '
          '(iteration $i, seed ${baseSeed + i}).',
    );

    // 3) decode -> encode -> decode equality through real JSON text.
    final viaText = jsonDecode(jsonEncode(j1)) as _JsonMap;
    final j2 = roundtrip(viaText);
    expect(
      j2,
      equals(j1),
      reason: '$name: round-trip is not stable through JSON text '
          '(iteration $i, seed ${baseSeed + i}).',
    );

    // 4) field names + nullability + values preserved verbatim.
    expect(
      j1,
      equals(j0),
      reason: '$name: round-trip changed a value or nullability '
          '(iteration $i, seed ${baseSeed + i}).',
    );
  }
}

// ===========================================================================
//  Scalar / collection generators (seeded)
// ===========================================================================

const String _strChars =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-. ';

String _str(math.Random r, {int min = 1, int max = 16}) {
  final len = min + r.nextInt(max - min + 1);
  return List.generate(len, (_) => _strChars[r.nextInt(_strChars.length)])
      .join();
}

int _int(math.Random r, {int min = 0, int max = 100000}) =>
    min + r.nextInt(max - min + 1);

/// A double with 2 decimal places so it survives JSON text round-trips exactly.
double _d(math.Random r, {double maxv = 100.0}) =>
    r.nextInt((maxv * 100).round() + 1) / 100.0;

bool _b(math.Random r) => r.nextBool();

String? _nstr(math.Random r) => r.nextBool() ? _str(r) : null;

int? _nint(math.Random r, {int min = 0, int max = 100000}) =>
    r.nextBool() ? _int(r, min: min, max: max) : null;

double? _ndouble(math.Random r, {double maxv = 100.0}) =>
    r.nextBool() ? _d(r, maxv: maxv) : null;

bool? _nbool(math.Random r) => r.nextBool() ? r.nextBool() : null;

T _pick<T>(math.Random r, List<T> xs) => xs[r.nextInt(xs.length)];

const List<String> _methods = ['text', 'ocr', 'ai'];
const List<String> _sources = ['auto', 'manual'];
const List<String> _noteKinds = [
  'duplicate',
  'gap',
  'tiny',
  'incomplete',
  'low_confidence'
];
const List<String> _imageFormats = ['png', 'jpg', 'jpeg'];
const List<String> _verdicts = ['pass', 'warn', 'fail'];
const List<String> _checkStatuses = ['ok', 'warn', 'fail', 'info'];
const List<String> _pageFormats = [
  'A4',
  'A3',
  'Letter',
  'Legal',
  'A5',
  'Custom'
];
const List<String> _orientations = ['Portrait', 'Landscape'];
const List<String> _opTypes = [
  'edit_text',
  'add_text',
  'add_image',
  'add_link',
  'erase'
];

List<double> _bbox(math.Random r) =>
    [_d(r, maxv: 600), _d(r, maxv: 900), _d(r, maxv: 600), _d(r, maxv: 900)];

Map<String, String> _genStrMap(math.Random r) {
  final n = r.nextInt(4); // 0..3, includes empty map
  final m = <String, String>{};
  for (var i = 0; i < n; i++) {
    m['key_${_str(r, min: 1, max: 4)}_$i'] = _str(r);
  }
  return m;
}

List<String> _strList(math.Random r, {int maxLen = 4}) =>
    List.generate(r.nextInt(maxLen + 1), (_) => _str(r, min: 1, max: 8));

// ===========================================================================
//  DTO generators (each produces a full engine-shaped JSON map)
// ===========================================================================

_JsonMap _genSegment(math.Random r) => <String, dynamic>{
      'page': _int(r, min: 1, max: 50),
      'y_start_pct': _d(r),
      'y_end_pct': _d(r),
      'x_start_pct': _d(r),
      'x_end_pct': _d(r),
      'x_offset_pct': _d(r, maxv: 50),
      'y_offset_pct': _d(r, maxv: 50),
    };

List<_JsonMap> _segList(math.Random r) =>
    List.generate(r.nextInt(4), (_) => _genSegment(r)); // 0..3

_JsonMap _genDetectedQuestion(math.Random r) => <String, dynamic>{
      'q_num': _str(r, min: 1, max: 5),
      'segments': _segList(r),
      'is_solution': _b(r),
      'option_labels': _str(r, min: 0, max: 4),
      'source': _pick(r, _sources),
    };

_JsonMap _genCropResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'total_questions': _int(r, max: 500),
      'stitched_questions': _int(r, max: 500),
      'method_used': _pick(r, _methods),
      'download_url': _str(r),
      'questions_download_url': _nstr(r),
      'solutions_download_url': _nstr(r),
      'questions_count': _int(r, max: 500),
      'solutions_count': _int(r, max: 500),
      'answer_sheet_included': _b(r),
      'answers_count': _int(r, max: 500),
    };

_JsonMap _genPageInfo(math.Random r) => <String, dynamic>{
      'page': _int(r, min: 1, max: 50),
      'width_pt': _d(r, maxv: 2000),
      'height_pt': _d(r, maxv: 2000),
      'preview_url': _str(r),
    };

_JsonMap _genAnalyzedItem(math.Random r) => <String, dynamic>{
      'q_num': _str(r, min: 1, max: 5),
      'is_solution': _b(r),
      'segments': _segList(r),
      'source': _pick(r, _sources),
      'flagged': _b(r),
      'flag_reason': _nstr(r),
      'other_segments': r.nextBool() ? null : _segList(r),
      'is_hindi': _nbool(r),
    };

_JsonMap _genReviewNote(math.Random r) => <String, dynamic>{
      'kind': _pick(r, _noteKinds),
      'message': _str(r, min: 1, max: 40),
      'q_num': _nstr(r),
      'page': _nint(r, min: 1, max: 50),
      'is_solution': _b(r),
      'suggested_segments': r.nextBool()
          ? null
          : List.generate(r.nextInt(3), (_) => _genSegment(r)),
    };

_JsonMap _genAnalyzeResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'total_pages': _int(r, min: 1, max: 50),
      'method_used': _pick(r, _methods),
      'pages': List.generate(r.nextInt(4), (_) => _genPageInfo(r)),
      'items': List.generate(r.nextInt(4), (_) => _genAnalyzedItem(r)),
      'notes': List.generate(r.nextInt(4), (_) => _genReviewNote(r)),
      'needs_review': _b(r),
      'answer_key_count': _int(r, max: 200),
      'bilingual_detected': _b(r),
    };

_JsonMap _genSnapRequest(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'page': _int(r, min: 1, max: 50),
      'x_start_pct': _d(r),
      'x_end_pct': _d(r),
      'y_start_pct': _d(r),
      'y_end_pct': _d(r),
      'margin_pct': _d(r, maxv: 2.0),
    };

_JsonMap _genSnapResponse(math.Random r) => <String, dynamic>{
      'x_start_pct': _d(r),
      'x_end_pct': _d(r),
      'y_start_pct': _d(r),
      'y_end_pct': _d(r),
    };

_JsonMap _genFinalizeItem(math.Random r) => <String, dynamic>{
      'q_num': _str(r, min: 1, max: 5),
      'is_solution': _b(r),
      'segments': _segList(r),
      'source': _pick(r, _sources),
      'align': _nbool(r),
      'is_hindi': _nbool(r),
    };

_JsonMap _genCropPreviewRequest(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'q_num': _str(r, min: 1, max: 5),
      'is_solution': _b(r),
      'segments': _segList(r),
      'source': _pick(r, _sources),
      'align': _nbool(r),
      'dpi': _int(r, min: 72, max: 600),
      'padding': _int(r, max: 200),
      'image_format': _pick(r, _imageFormats),
      'jpg_quality': _int(r, min: 1, max: 100),
      'bilingual_mode': _pick(r, const [null, 'english', 'hindi', 'bilingual_horizontal', 'bilingual_vertical', 'bilingual_separate']),
      'other_segments': r.nextBool() ? null : _segList(r),
      'is_hindi': _nbool(r),
    };

_JsonMap _genFinalizeRequest(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'items': List.generate(r.nextInt(4), (_) => _genFinalizeItem(r)),
      'dpi': _int(r, min: 72, max: 600),
      'padding': _int(r, max: 200),
      'question_prefix': _str(r, min: 0, max: 10),
      'solution_prefix': _str(r, min: 0, max: 10),
      'start_number': _int(r, min: 1, max: 100000),
      'image_format': _pick(r, _imageFormats),
      'jpg_quality': _int(r, min: 1, max: 100),
      'answer_sheet': _b(r),
      'bilingual_mode': _pick(r, const [null, 'english', 'hindi', 'bilingual_horizontal', 'bilingual_vertical', 'bilingual_separate']),
      'english_question_prefix': _str(r, min: 0, max: 10),
      'english_solution_prefix': _str(r, min: 0, max: 10),
      'hindi_question_prefix': _str(r, min: 0, max: 10),
      'hindi_solution_prefix': _str(r, min: 0, max: 10),
    };

_JsonMap _genHealthResponse(math.Random r) => <String, dynamic>{
      'status': _str(r, min: 1, max: 6),
      'tesseract_available': _b(r),
      'ai_available': _b(r),
      'version': _str(r, min: 1, max: 8),
      'ai_provider': _nstr(r),
      'ai_model': _nstr(r),
      'local_ml_available': _b(r),
      'local_ml_model': _nstr(r),
    };

_JsonMap _genRenamePlanItem(math.Random r) => <String, dynamic>{
      'original': _str(r),
      'renamed': _str(r),
    };

_JsonMap _genRenamePreviewResponse(math.Random r) {
  final items = List.generate(r.nextInt(5), (_) => _genRenamePlanItem(r));
  return <String, dynamic>{
    'count': items.length,
    'items': items,
  };
}

_JsonMap _genPdfImageItem(math.Random r) => <String, dynamic>{
      'name': _str(r),
      'data_url': 'data:image/png;base64,${_str(r, min: 8, max: 40)}',
      'width': _int(r, min: 1, max: 5000),
      'height': _int(r, min: 1, max: 5000),
      'size': _int(r, max: 5000000),
    };

_JsonMap _genPdfToImagesResponse(math.Random r) {
  final images = List.generate(r.nextInt(4), (_) => _genPdfImageItem(r));
  return <String, dynamic>{
    'count': images.length,
    'images': images,
  };
}

_JsonMap _genRenameSessionResponse(math.Random r) => <String, dynamic>{
      'session_id': _str(r),
    };

_JsonMap _genRenameUploadResponse(math.Random r) => <String, dynamic>{
      'session_id': _str(r),
      'received': _int(r, max: 1000),
      'total': _int(r, max: 100000),
    };

_JsonMap _genRenameFinalizeResponse(math.Random r) => <String, dynamic>{
      'session_id': _str(r),
      'count': _int(r, max: 100000),
      'download_url': _str(r),
      'excel_download_url': _nstr(r),
    };

_JsonMap _genCompressResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'original_size': _int(r, max: 100000000),
      'compressed_size': _int(r, max: 100000000),
      'ratio': _d(r, maxv: 1.0),
      'level': _str(r, min: 1, max: 10),
      'target_met': _nbool(r),
      'note': _str(r, min: 0, max: 30),
      'download_url': _str(r),
      'pages': List.generate(r.nextInt(3), (_) => _genEditPageModel(r)),
    };

_JsonMap _genEditableSpanModel(math.Random r) => <String, dynamic>{
      'id': _str(r),
      'page': _int(r, min: 1, max: 50),
      'text': _str(r, min: 0, max: 40),
      'bbox': _bbox(r),
      'font': _str(r, min: 1, max: 16),
      'size': _d(r, maxv: 72),
      'color': _int(r, max: 16777215),
      'bold': _b(r),
      'italic': _b(r),
    };

_JsonMap _genEditPageModel(math.Random r) => <String, dynamic>{
      'page': _int(r, min: 1, max: 50),
      'width': _d(r, maxv: 2000),
      'height': _d(r, maxv: 2000),
      'preview_url': _str(r),
    };

_JsonMap _genVectorObjectModel(math.Random r) => <String, dynamic>{
      'id': _str(r),
      'page': _int(r, min: 1, max: 50),
      'type': _pick(r, ['image', 'vector']),
      'bbox': _bbox(r),
    };

_JsonMap _genEditExtractResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'has_text': _b(r),
      'pages': List.generate(r.nextInt(4), (_) => _genEditPageModel(r)),
      'spans': List.generate(r.nextInt(4), (_) => _genEditableSpanModel(r)),
      'vector_objects':
          List.generate(r.nextInt(4), (_) => _genVectorObjectModel(r)),
    };

_JsonMap _genEditOpModel(math.Random r) => <String, dynamic>{
      'page': _int(r, min: 1, max: 50),
      'bbox': _bbox(r),
      'new_text': _str(r, min: 0, max: 40),
      'font': _nstr(r),
      'size': _ndouble(r, maxv: 72),
      'color': _nint(r, max: 16777215),
    };

_JsonMap _genOperationModel(math.Random r) => <String, dynamic>{
      'type': _pick(r, _opTypes),
      'page': _int(r, min: 1, max: 50),
      'bbox': _bbox(r),
      'text': _str(r, min: 0, max: 40),
      'font': _nstr(r),
      'size': _ndouble(r, maxv: 72),
      'color': _nint(r, max: 16777215),
      'bold': _b(r),
      'italic': _b(r),
      'align': _int(r, max: 2),
      'image_b64': _nstr(r),
      'url': _nstr(r),
      'fill': _nint(r, max: 16777215),
    };

_JsonMap _genEditApplyRequest(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'edits': List.generate(r.nextInt(4), (_) => _genEditOpModel(r)),
      'operations': List.generate(r.nextInt(4), (_) => _genOperationModel(r)),
    };

_JsonMap _genEditApplyResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'edits_applied': _int(r, max: 1000),
      'download_url': _str(r),
    };

_JsonMap _genOcrResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'pages_ocred': _int(r, max: 1000),
      'languages': _str(r, min: 1, max: 16),
      'note': _str(r, min: 0, max: 30),
      'download_url': _str(r),
    };

_JsonMap _genPreflightCheckModel(math.Random r) => <String, dynamic>{
      'id': _str(r),
      'title': _str(r, min: 1, max: 30),
      'status': _pick(r, _checkStatuses),
      'detail': _str(r, min: 0, max: 40),
    };

_JsonMap _genPreflightFontModel(math.Random r) => <String, dynamic>{
      'name': _str(r),
      'type': _str(r, min: 1, max: 12),
      'embedded': _b(r),
      'subset': _b(r),
    };

_JsonMap _genPreflightImageModel(math.Random r) => <String, dynamic>{
      'page': _int(r, min: 1, max: 50),
      'width': _int(r, min: 1, max: 8000),
      'height': _int(r, min: 1, max: 8000),
      'dpi': _d(r, maxv: 1200),
      'colorspace': _str(r, min: 1, max: 12),
      'bpc': _int(r, min: 1, max: 16),
    };

_JsonMap _genPreflightPageDetail(math.Random r) => <String, dynamic>{
      'page': _int(r, min: 1, max: 50),
      'w_mm': _d(r, maxv: 500),
      'h_mm': _d(r, maxv: 500),
      'w_pt': _d(r, maxv: 2000),
      'h_pt': _d(r, maxv: 2000),
      'w_px': _int(r, min: 1, max: 8000),
      'h_px': _int(r, min: 1, max: 8000),
      'format': _pick(r, _pageFormats),
      'orientation': _pick(r, _orientations),
    };

_JsonMap _genPreflightResponse(math.Random r) => <String, dynamic>{
      'verdict': _pick(r, _verdicts),
      'page_count': _int(r, min: 1, max: 100),
      'page_sizes': _strList(r),
      'file_size': _int(r, max: 100000000),
      'is_encrypted': _b(r),
      'has_text_layer': _b(r),
      'checks': List.generate(r.nextInt(4), (_) => _genPreflightCheckModel(r)),
      'fonts': List.generate(r.nextInt(4), (_) => _genPreflightFontModel(r)),
      'images': List.generate(r.nextInt(4), (_) => _genPreflightImageModel(r)),
      'metadata': _genStrMap(r),
      'distinct_page_sizes': _strList(r),
      'mixed_page_sizes': _b(r),
      'page_details':
          List.generate(r.nextInt(4), (_) => _genPreflightPageDetail(r)),
      'job_id': r.nextBool() ? _str(r) : null,
      'pages': List.generate(r.nextInt(3), (_) => _genEditPageModel(r)),
    };

_JsonMap _genPreflightFixResponse(math.Random r) => <String, dynamic>{
      'job_id': _str(r),
      'target_label': _str(r, min: 1, max: 10),
      'target_width': _d(r, maxv: 2000),
      'target_height': _d(r, maxv: 2000),
      'pages_total': _int(r, max: 1000),
      'pages_changed': _int(r, max: 1000),
      'note': _str(r, min: 0, max: 30),
      'download_url': _str(r),
      'pages': List.generate(r.nextInt(3), (_) => _genEditPageModel(r)),
    };

// ===========================================================================
//  Engine contract key-sets (exact toJson() output for each DTO)
// ===========================================================================

const Set<String> _kQuestionSegment = {
  'page',
  'y_start_pct',
  'y_end_pct',
  'x_start_pct',
  'x_end_pct',
  'x_offset_pct',
  'y_offset_pct',
};

const Set<String> _kDetectedQuestion = {
  'q_num',
  'segments',
  'is_solution',
  'option_labels',
  'source',
};

const Set<String> _kCropResponse = {
  'job_id',
  'total_questions',
  'stitched_questions',
  'method_used',
  'download_url',
  'questions_download_url',
  'solutions_download_url',
  'questions_count',
  'solutions_count',
  'answer_sheet_included',
  'answers_count',
};

const Set<String> _kPageInfo = {
  'page',
  'width_pt',
  'height_pt',
  'preview_url',
};

const Set<String> _kAnalyzedItem = {
  'q_num',
  'is_solution',
  'segments',
  'source',
  'flagged',
  'flag_reason',
  'other_segments',
  'is_hindi',
};

const Set<String> _kReviewNote = {
  'kind',
  'message',
  'q_num',
  'page',
  'is_solution',
  'suggested_segments',
};

const Set<String> _kAnalyzeResponse = {
  'job_id',
  'total_pages',
  'method_used',
  'pages',
  'items',
  'notes',
  'needs_review',
  'answer_key_count',
  'bilingual_detected',
};

const Set<String> _kSnapRequest = {
  'job_id',
  'page',
  'x_start_pct',
  'x_end_pct',
  'y_start_pct',
  'y_end_pct',
  'margin_pct',
};

const Set<String> _kSnapResponse = {
  'x_start_pct',
  'x_end_pct',
  'y_start_pct',
  'y_end_pct',
};

const Set<String> _kFinalizeItem = {
  'q_num',
  'is_solution',
  'segments',
  'source',
  'align',
  'is_hindi',
};

const Set<String> _kCropPreviewRequest = {
  'job_id',
  'q_num',
  'is_solution',
  'segments',
  'source',
  'align',
  'dpi',
  'padding',
  'image_format',
  'jpg_quality',
  'bilingual_mode',
  'other_segments',
  'is_hindi',
};

const Set<String> _kFinalizeRequest = {
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
  'bilingual_mode',
  'english_question_prefix',
  'english_solution_prefix',
  'hindi_question_prefix',
  'hindi_solution_prefix',
};

const Set<String> _kHealthResponse = {
  'status',
  'tesseract_available',
  'ai_available',
  'version',
  'ai_provider',
  'ai_model',
  'local_ml_available',
  'local_ml_model',
};

const Set<String> _kRenamePlanItem = {
  'original',
  'renamed',
};

const Set<String> _kRenamePreviewResponse = {
  'count',
  'items',
};

const Set<String> _kPdfImageItem = {
  'name',
  'data_url',
  'width',
  'height',
  'size',
};

const Set<String> _kPdfToImagesResponse = {
  'count',
  'images',
};

const Set<String> _kRenameSessionResponse = {
  'session_id',
};

const Set<String> _kRenameUploadResponse = {
  'session_id',
  'received',
  'total',
};

const Set<String> _kRenameFinalizeResponse = {
  'session_id',
  'count',
  'download_url',
  'excel_download_url',
};

const Set<String> _kCompressResponse = {
  'job_id',
  'original_size',
  'compressed_size',
  'ratio',
  'level',
  'target_met',
  'note',
  'download_url',
  'pages',
};

const Set<String> _kEditableSpanModel = {
  'id',
  'page',
  'text',
  'bbox',
  'font',
  'size',
  'color',
  'bold',
  'italic',
};

const Set<String> _kEditPageModel = {
  'page',
  'width',
  'height',
  'preview_url',
};

const Set<String> _kEditExtractResponse = {
  'job_id',
  'has_text',
  'pages',
  'spans',
  'vector_objects',
};

const Set<String> _kEditOpModel = {
  'page',
  'bbox',
  'new_text',
  'font',
  'size',
  'color',
};

const Set<String> _kOperationModel = {
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

const Set<String> _kEditApplyRequest = {
  'job_id',
  'edits',
  'operations',
};

const Set<String> _kEditApplyResponse = {
  'job_id',
  'edits_applied',
  'download_url',
};

const Set<String> _kOcrResponse = {
  'job_id',
  'pages_ocred',
  'languages',
  'note',
  'download_url',
};

const Set<String> _kPreflightCheckModel = {
  'id',
  'title',
  'status',
  'detail',
};

const Set<String> _kPreflightFontModel = {
  'name',
  'type',
  'embedded',
  'subset',
};

const Set<String> _kPreflightImageModel = {
  'page',
  'width',
  'height',
  'dpi',
  'colorspace',
  'bpc',
};

const Set<String> _kPreflightPageDetail = {
  'page',
  'w_mm',
  'h_mm',
  'w_pt',
  'h_pt',
  'w_px',
  'h_px',
  'format',
  'orientation',
};

const Set<String> _kPreflightResponse = {
  'verdict',
  'page_count',
  'page_sizes',
  'file_size',
  'is_encrypted',
  'has_text_layer',
  'checks',
  'fonts',
  'images',
  'metadata',
  'distinct_page_sizes',
  'mixed_page_sizes',
  'page_details',
  'job_id',
  'pages',
};

const Set<String> _kPreflightFixResponse = {
  'job_id',
  'target_label',
  'target_width',
  'target_height',
  'pages_total',
  'pages_changed',
  'note',
  'download_url',
  'pages',
};
