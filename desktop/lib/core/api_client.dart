// HTTP client for the Qpic FastAPI engine (Requirements 1.1, 1.3).
//
// `ApiClient` is a thin [Dio] wrapper bound to the sidecar's Base_URL
// (`http://127.0.0.1:{port}`). It mirrors the engine's endpoints EXACTLY — no
// path, query-parameter, form-field, or multipart-field name is added,
// dropped, renamed, or reshaped. Every endpoint, parameter and field below is
// taken verbatim from the routers in `app/routers/{crop,rename,tools}.py`,
// which are mounted under the `/api` prefix by `app/main.py`.
//
// There is ZERO engine logic in Dart: this client only issues HTTP requests
// and parses the JSON the engine returns into the transport DTOs in
// `lib/models/`. All detection, OCR, crop/stitch, PDF-tool and answer-key work
// stays in the Python engine and is reached over localhost HTTP.
//
// Binary / download endpoints are not buffered here. Instead the client exposes
// the joined absolute URL (see the `*Uri` builders and [resolveUri]) plus a
// streaming [getBytes] helper, so the DownloadService (task 7.1) and the review
// canvas (`Image.network`) can fetch bytes / stream to disk themselves.

import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/analyze.dart';
import '../models/crop.dart';
import '../models/rename.dart';
import '../models/tools.dart';

/// A typed error surfaced from the engine.
///
/// The Qpic engine reports every error as a JSON body `{"detail": "..."}` with
/// a 4xx/5xx status code (FastAPI `HTTPException`, plus the catch-all handler in
/// `app/main.py`). [ApiClient] converts any such response into an
/// [ApiException] that carries the HTTP [statusCode] and the engine's [detail]
/// string **verbatim**, so feature code can show the engine's own message to
/// the user without reshaping it.
class ApiException implements Exception {
  const ApiException(this.statusCode, this.detail);

  /// The HTTP status code returned by the engine (e.g. 400, 404, 422, 500).
  /// `0` when the failure happened before a response was received (timeout,
  /// connection refused, cancellation).
  final int statusCode;

  /// The engine's `detail` message, surfaced exactly as the engine sent it.
  final String detail;

  @override
  String toString() => 'ApiException($statusCode): $detail';
}

/// One file to upload as a multipart part (raw bytes + filename).
///
/// The engine validates uploads either by `content_type` (crop/analyze/tools)
/// or by filename extension (rename), so callers provide the bytes, the
/// original filename, and — for PDF flows — the `application/pdf` content type.
class ApiUploadFile {
  const ApiUploadFile({
    required this.bytes,
    required this.filename,
    this.contentType,
  });

  final List<int> bytes;
  final String filename;
  final DioMediaType? contentType;
}

/// Thin Dio wrapper that talks to the Qpic engine over its Base_URL.
class ApiClient {
  /// Creates a client bound to [baseUrl] (the sidecar root, e.g.
  /// `http://127.0.0.1:54321`). A custom [dio] may be injected for testing;
  /// otherwise a default instance is created and configured.
  ApiClient(this.baseUrl, {Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.baseUrl = baseUrl.toString();
  }

  /// Convenience constructor accepting the Base_URL as a string.
  factory ApiClient.fromBaseUrl(String baseUrl, {Dio? dio}) =>
      ApiClient(Uri.parse(baseUrl), dio: dio);

  /// The sidecar root URL (`http://127.0.0.1:{port}`).
  final Uri baseUrl;

  final Dio _dio;

  /// The underlying Dio instance (exposed for the DownloadService to reuse the
  /// same connection settings when streaming downloads).
  Dio get dio => _dio;

  /// Every router is mounted under this prefix by `app/main.py`.
  static const String _api = '/api';

  /// Content type for PDF uploads (crop/analyze/prepare-manual/tools flows).
  static DioMediaType get _pdfMediaType => DioMediaType('application', 'pdf');

  // ===========================================================================
  //  Health
  // ===========================================================================

  /// `GET /api/health` — engine readiness, Tesseract and AI availability.
  Future<HealthResponse> health() {
    return _guard(() async {
      final res = await _dio.get<Map<String, dynamic>>('$_api/health');
      return HealthResponse.fromJson(res.data!);
    });
  }

  // ===========================================================================
  //  Auto Crop / Smart analyze / Manual Crop / Snap / Finalize
  // ===========================================================================

  /// `POST /api/crop` — full pipeline straight to a downloadable ZIP.
  ///
  /// Query params and the multipart `file` field map 1:1 to `crop_pdf` in
  /// `app/routers/crop.py`. `questionPages` / `answerPages` are omitted from the
  /// query when null (the engine treats them as not supplied).
  Future<CropResponse> crop({
    required List<int> fileBytes,
    required String filename,
    int dpi = 200,
    int padding = 20,
    String markerStyle = 'auto',
    bool hasQuestions = true,
    String? questionPages,
    bool hasAnswers = true,
    String? answerPages,
    String? skipPages,
    String questionPrefix = 'Q',
    String solutionPrefix = 'S',
    int startNumber = 1,
    String imageFormat = 'png',
    int jpgQuality = 90,
    bool useAi = false,
    bool useGoogleOcr = false,
    bool answerSheet = true,
    String layoutColumns = 'auto',
    bool binarize = false,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    bool deskew = false,
    String? customRegex,
    double? confidence,
  }) {
    return _guard(() async {
      final query = <String, dynamic>{
        'dpi': dpi,
        'padding': padding,
        'marker_style': markerStyle,
        'has_questions': hasQuestions,
        'has_answers': hasAnswers,
        'question_prefix': questionPrefix,
        'solution_prefix': solutionPrefix,
        'start_number': startNumber,
        'image_format': imageFormat,
        'jpg_quality': jpgQuality,
        'use_ai': useAi,
        'use_google_ocr': useGoogleOcr,
        'answer_sheet': answerSheet,
        'layout_columns': layoutColumns,
        'binarize': binarize,
        'contrast': contrast,
        'brightness': brightness,
        'watermark_threshold': watermarkThreshold,
        'deskew': deskew,
      };
      if (questionPages != null) query['question_pages'] = questionPages;
      if (answerPages != null) query['answer_pages'] = answerPages;
      if (skipPages != null) query['skip_pages'] = skipPages;
      if (customRegex != null && customRegex.isNotEmpty) {
        query['custom_regex'] = customRegex;
      }
      if (confidence != null) {
        query['confidence'] = confidence;
      }

      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/crop',
        queryParameters: query,
        data: form,
      );
      return CropResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/analyze` — smart detection that returns items + notes + page
  /// previews for the review canvas. Mirrors `analyze_pdf`.
  Future<AnalyzeResponse> analyze({
    required List<int> fileBytes,
    required String filename,
    int dpi = 200,
    String markerStyle = 'auto',
    bool hasQuestions = true,
    String? questionPages,
    bool hasAnswers = true,
    String? answerPages,
    String? skipPages,
    bool useAi = false,
    bool useGoogleOcr = false,
    bool answerSheet = true,
    String layoutColumns = 'auto',
    bool binarize = false,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    bool deskew = false,
    String? customRegex,
    double? confidence,
  }) {
    return _guard(() async {
      final query = <String, dynamic>{
        'dpi': dpi,
        'marker_style': markerStyle,
        'has_questions': hasQuestions,
        'has_answers': hasAnswers,
        'use_ai': useAi,
        'use_google_ocr': useGoogleOcr,
        'answer_sheet': answerSheet,
        'layout_columns': layoutColumns,
        'binarize': binarize,
        'contrast': contrast,
        'brightness': brightness,
        'watermark_threshold': watermarkThreshold,
        'deskew': deskew,
      };
      if (questionPages != null) query['question_pages'] = questionPages;
      if (answerPages != null) query['answer_pages'] = answerPages;
      if (skipPages != null) query['skip_pages'] = skipPages;
      if (customRegex != null && customRegex.isNotEmpty) {
        query['custom_regex'] = customRegex;
      }
      if (confidence != null) {
        query['confidence'] = confidence;
      }

      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/analyze',
        queryParameters: query,
        data: form,
      );
      return AnalyzeResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/prepare-manual` — open a PDF for fully-manual cropping (no
  /// detection). Query `dpi` + multipart `file`. Mirrors `prepare_manual`.
  Future<AnalyzeResponse> prepareManual({
    required List<int> fileBytes,
    required String filename,
    int dpi = 200,
    bool binarize = false,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    bool deskew = false,
  }) {
    return _guard(() async {
      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/prepare-manual',
        queryParameters: <String, dynamic>{
          'dpi': dpi,
          'binarize': binarize,
          'contrast': contrast,
          'brightness': brightness,
          'watermark_threshold': watermarkThreshold,
          'deskew': deskew,
        },
        data: form,
      );
      return AnalyzeResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/crop/{job_id}/auto-detect` — run auto-detection on a page or all pages of the cached document.
  Future<List<AnalyzedItem>> autoDetect({
    required String jobId,
    int? page,
    bool useAi = false,
    bool useGoogleOcr = false,
    String markerStyle = 'auto',
    String layoutColumns = 'auto',
    bool binarize = false,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    bool deskew = false,
    String? customRegex,
    double? confidence,
  }) {
    return _guard(() async {
      final query = <String, dynamic>{
        'use_ai': useAi,
        'use_google_ocr': useGoogleOcr,
        'marker_style': markerStyle,
        'layout_columns': layoutColumns,
        'binarize': binarize,
        'contrast': contrast,
        'brightness': brightness,
        'watermark_threshold': watermarkThreshold,
        'deskew': deskew,
      };
      if (page != null) query['page'] = page;
      if (customRegex != null && customRegex.isNotEmpty) {
        query['custom_regex'] = customRegex;
      }
      if (confidence != null) {
        query['confidence'] = confidence;
      }

      final res = await _dio.post<List<dynamic>>(
        '$_api/crop/$jobId/auto-detect',
        queryParameters: query,
      );
      return res.data!
          .map((e) => AnalyzedItem.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  /// `POST /api/snap` — tighten a roughly drawn box to its content. JSON body
  /// is the [SnapRequest]; the engine echoes the box back when it cannot snap.
  Future<SnapResponse> snap(SnapRequest request) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/snap',
        data: request.toJson(),
      );
      return SnapResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/finalize` — crop a reviewed item list into the ZIP. JSON body
  /// is the [FinalizeRequest]. Mirrors `finalize_crop`.
  Future<CropResponse> finalize(FinalizeRequest request) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/finalize',
        data: request.toJson(),
      );
      return CropResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/crop/preview` — render ONE reviewed item as a standalone preview
  /// image (PNG/JPG bytes), reusing the same crop/stitch pipeline the finalized
  /// download runs. JSON body is the [CropPreviewRequest]. Mirrors
  /// `crop_preview`; returns the raw image bytes for `Image.memory`.
  Future<List<int>> cropPreview(CropPreviewRequest request) {
    return _guard(() async {
      final res = await _dio.post<dynamic>(
        '$_api/crop/preview',
        data: request.toJson(),
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      if (data is List<int>) return data;
      if (data is List) return data.cast<int>();
      return const <int>[];
    });
  }

  // ===========================================================================
  //  Rename Batch
  // ===========================================================================

  /// `POST /api/rename/preview` — live before/after list, no image bytes.
  ///
  /// `names` is sent as repeated form fields (FastAPI `list[str] = Form(...)`),
  /// alongside `pattern`, `start`, `padding`. Mirrors `rename_preview`.
  Future<RenamePreviewResponse> renamePreview({
    required List<String> names,
    String pattern = '#',
    int start = 1,
    int padding = 0,
  }) {
    return _guard(() async {
      final form = FormData();
      for (final name in names) {
        form.fields.add(MapEntry('names', name));
      }
      form.fields
        ..add(MapEntry('pattern', pattern))
        ..add(MapEntry('start', start.toString()))
        ..add(MapEntry('padding', padding.toString()));

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/rename/preview',
        data: form,
      );
      return RenamePreviewResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/rename/pdf-to-images` — rasterise a PDF to one PNG per page.
  /// Multipart `file`. Mirrors `pdf_to_images_endpoint`.
  Future<PdfToImagesResponse> renamePdfToImages({
    required List<int> fileBytes,
    required String filename,
    int? dpi,
  }) {
    return _guard(() async {
      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );
      if (dpi != null) {
        form.fields.add(MapEntry('dpi', dpi.toString()));
      }

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/rename/pdf-to-images',
        data: form,
      );
      return PdfToImagesResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/rename/pdf-to-session` — fast parallel PDF rendering to
  /// per-page JPEG files. Returns metadata with per-page download URLs.
  Future<PdfToSessionResponse> renamePdfToSession({
    required List<int> fileBytes,
    required String filename,
    int? dpi,
    int? quality,
  }) {
    return _guard(() async {
      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );
      if (dpi != null) {
        form.fields.add(MapEntry('dpi', dpi.toString()));
      }
      if (quality != null) {
        form.fields.add(MapEntry('quality', quality.toString()));
      }

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/rename/pdf-to-session',
        data: form,
      );
      return PdfToSessionResponse.fromJson(res.data!);
    });
  }

  /// `DELETE /api/rename/pdf-session/{id}` — clean up a PDF session.
  Future<void> deletePdfSession(String jobId) {
    return _guard(() async {
      await _dio.delete<dynamic>('$_api/rename/pdf-session/$jobId');
    });
  }

  /// `POST /api/rename/pdf-session/{jobId}/finalize` — fast direct finalize
  /// for PDF pages already on disk.
  Future<RenameFinalizeResponse> finalizePdfSession({
    required String jobId,
    required List<String> originals,
    required List<String> names,
    String? outputFormat,
    int? jpgQuality,
  }) {
    return _guard(() async {
      final payload = <String, dynamic>{
        'items': List<Map<String, String>>.generate(
          originals.length,
          (i) => {
            'original': originals[i],
            'new_stem': names[i],
          },
        ),
        if (outputFormat != null) 'output_format': outputFormat,
        if (jpgQuality != null) 'jpg_quality': jpgQuality,
      };
      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/rename/pdf-session/$jobId/finalize',
        data: payload,
      );
      return RenameFinalizeResponse.fromJson(res.data!);
    });
  }

  /// Build the absolute URL for a PDF page image from the relative page_url.
  String pdfPageImageUrl(String relativePageUrl) =>
      '${baseUrl.origin}$relativePageUrl';

  /// `POST /api/rename/session` — open a streamed rename session.
  Future<RenameSessionResponse> createRenameSession() {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>('$_api/rename/session');
      return RenameSessionResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/rename/session/{id}/files` — append a chunk of files to a
  /// session. Files are sent as repeated `files` multipart parts (FastAPI
  /// `list[UploadFile] = File(...)`). Mirrors `upload_rename_files`.
  Future<RenameUploadResponse> uploadRenameFiles({
    required String sessionId,
    required List<ApiUploadFile> files,
  }) {
    return _guard(() async {
      final form = FormData();
      for (final f in files) {
        form.files.add(
          MapEntry(
            'files',
            MultipartFile.fromBytes(
              f.bytes,
              filename: f.filename,
              contentType: f.contentType,
            ),
          ),
        );
      }

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/rename/session/$sessionId/files',
        data: form,
      );
      return RenameUploadResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/rename/session/{id}/finalize` — pack staged files into a ZIP.
  ///
  /// Form fields `pattern`, `start`, `padding`, `names`, `output_format`,
  /// `jpg_quality`. Here `names` is a single JSON-array string of explicit
  /// output stems (the engine parses it with `json.loads`), exactly as
  /// `finalize_rename_session` expects. When [names] is null the field is
  /// omitted so the engine uses its `""` default.
  Future<RenameFinalizeResponse> finalizeRenameSession({
    required String sessionId,
    String pattern = '#',
    int start = 1,
    int padding = 0,
    List<String>? names,
    String outputFormat = 'original',
    int jpgQuality = 90,
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields
        ..add(MapEntry('pattern', pattern))
        ..add(MapEntry('start', start.toString()))
        ..add(MapEntry('padding', padding.toString()))
        ..add(MapEntry('output_format', outputFormat))
        ..add(MapEntry('jpg_quality', jpgQuality.toString()));
      if (names != null) {
        form.fields.add(MapEntry('names', jsonEncode(names)));
      }

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/rename/session/$sessionId/finalize',
        data: form,
      );
      return RenameFinalizeResponse.fromJson(res.data!);
    });
  }

  /// `DELETE /api/rename/session/{id}` — release a session after download.
  Future<void> deleteRenameSession(String sessionId) {
    return _guard(() async {
      await _dio.delete<dynamic>('$_api/rename/session/$sessionId');
    });
  }

  // ===========================================================================
  //  Tools — Compress
  // ===========================================================================

  /// `POST /api/tools/compress` — shrink a PDF by `level` or `target_mb`.
  ///
  /// Form `level` (default `balanced`) plus optional `target_mb` (sent only
  /// when provided) and multipart `file`. Mirrors `compress_endpoint`.
  Future<CompressResponse> compress({
    required List<int> fileBytes,
    required String filename,
    String level = 'balanced',
    double? targetMb,
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields.add(MapEntry('level', level));
      if (targetMb != null) {
        form.fields.add(MapEntry('target_mb', targetMb.toString()));
      }
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/compress',
        data: form,
      );
      return CompressResponse.fromJson(res.data!);
    });
  }

  // ===========================================================================
  //  Tools — Preflight
  // ===========================================================================

  /// `POST /api/tools/preflight` — read-only print-readiness inspection.
  /// Multipart `file`. Mirrors `preflight_endpoint`.
  Future<PreflightResponse> preflight({
    required List<int> fileBytes,
    required String filename,
  }) {
    return _guard(() async {
      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/preflight',
        data: form,
      );
      return PreflightResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/tools/preflight/fix-page-sizes` — normalize page sizes.
  ///
  /// Form `target`, `fill_mode` (`fit`/`stretch`), `skip_pages` and multipart
  /// `file`. Mirrors `preflight_fix_page_sizes`.
  Future<PreflightFixResponse> preflightFixPageSizes({
    required List<int> fileBytes,
    required String filename,
    String target = 'auto',
    String fillMode = 'fit',
    String skipPages = '',
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields
        ..add(MapEntry('target', target))
        ..add(MapEntry('fill_mode', fillMode))
        ..add(MapEntry('skip_pages', skipPages));
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/preflight/fix-page-sizes',
        data: form,
      );
      return PreflightFixResponse.fromJson(res.data!);
    });
  }

  // ===========================================================================
  //  Tools — Edit + OCR
  // ===========================================================================

  /// `POST /api/tools/edit/open` — stage a PDF for editing; returns editable
  /// spans + page geometry/previews. Multipart `file`. Mirrors `edit_open`.
  Future<EditExtractResponse> editOpen({
    required List<int> fileBytes,
    required String filename,
  }) {
    return _guard(() async {
      final form = FormData();
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/edit/open',
        data: form,
      );
      return EditExtractResponse.fromJson(res.data!);
    });
  }

  /// `GET /api/tools/edit/{job_id}/state` — re-extract spans + geometry for an
  /// already-staged edit job. Mirrors `edit_state`.
  Future<EditExtractResponse> editState(String jobId) {
    return _guard(() async {
      final res = await _dio.get<Map<String, dynamic>>(
        '$_api/tools/edit/$jobId/state',
      );
      return EditExtractResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/tools/edit/apply` — apply edits to a staged job. JSON body is
  /// the [EditApplyRequest]. Mirrors `edit_apply`.
  Future<EditApplyResponse> editApply(EditApplyRequest request) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/edit/apply',
        data: request.toJson(),
      );
      return EditApplyResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/tools/edit/ocr` — add a searchable OCR text layer.
  ///
  /// Form `languages`, `dpi` and multipart `file`. Mirrors `edit_ocr`.
  Future<OcrResponse> editOcr({
    required List<int> fileBytes,
    required String filename,
    String languages = '',
    int dpi = 300,
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields
        ..add(MapEntry('languages', languages))
        ..add(MapEntry('dpi', dpi.toString()));
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/edit/ocr',
        data: form,
      );
      return OcrResponse.fromJson(res.data!);
    });
  }

  // ===========================================================================
  //  Tools — Enhance
  // ===========================================================================

  /// `POST /api/tools/enhance` — enhance PDF page-by-page.
  Future<EnhanceResponse> enhance({
    required List<int> fileBytes,
    required String filename,
    bool binarize = false,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    bool deskew = false,
    int dpi = 200,
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields
        ..add(MapEntry('binarize', binarize.toString()))
        ..add(MapEntry('contrast', contrast.toString()))
        ..add(MapEntry('brightness', brightness.toString()))
        ..add(MapEntry('watermark_threshold', watermarkThreshold.toString()))
        ..add(MapEntry('deskew', deskew.toString()))
        ..add(MapEntry('dpi', dpi.toString()));
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: _pdfMediaType,
          ),
        ),
      );

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/enhance',
        data: form,
      );
      return EnhanceResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/tools/enhance-image` — enhance an image and return raw PNG bytes.
  Future<List<int>> enhanceImage({
    required List<int> fileBytes,
    required String filename,
    bool binarize = false,
    int binarizeThreshold = 185,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    int denoise = 0,
    bool deskew = false,
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields
        ..add(MapEntry('binarize', binarize.toString()))
        ..add(MapEntry('binarize_threshold', binarizeThreshold.toString()))
        ..add(MapEntry('contrast', contrast.toString()))
        ..add(MapEntry('brightness', brightness.toString()))
        ..add(MapEntry('watermark_threshold', watermarkThreshold.toString()))
        ..add(MapEntry('denoise', denoise.toString()))
        ..add(MapEntry('deskew', deskew.toString()));

      final isJpeg = filename.toLowerCase().endsWith('.jpg') ||
          filename.toLowerCase().endsWith('.jpeg');
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: isJpeg
                ? DioMediaType('image', 'jpeg')
                : DioMediaType('image', 'png'),
          ),
        ),
      );

      final res = await _dio.post<dynamic>(
        '$_api/tools/enhance-image',
        data: form,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      if (data is List<int>) return data;
      if (data is List) return data.cast<int>();
      return const <int>[];
    });
  }

  /// `POST /api/tools/ai-enhance-image` — AI-powered Remini-like enhancement.
  Future<List<int>> aiEnhanceImage({
    required List<int> fileBytes,
    required String filename,
    int strength = 3,
    bool faceEnhance = true,
    int sharpen = 3,
    int upscale = 1,
    bool colorFix = true,
    bool onlineSr = false,
  }) {
    return _guard(() async {
      final form = FormData();
      form.fields
        ..add(MapEntry('strength', strength.toString()))
        ..add(MapEntry('face_enhance', faceEnhance.toString()))
        ..add(MapEntry('sharpen', sharpen.toString()))
        ..add(MapEntry('upscale', upscale.toString()))
        ..add(MapEntry('color_fix', colorFix.toString()))
        ..add(MapEntry('online_sr', onlineSr.toString()));

      final isJpeg = filename.toLowerCase().endsWith('.jpg') ||
          filename.toLowerCase().endsWith('.jpeg');
      form.files.add(
        MapEntry(
          'file',
          MultipartFile.fromBytes(
            fileBytes,
            filename: filename,
            contentType: isJpeg
                ? DioMediaType('image', 'jpeg')
                : DioMediaType('image', 'png'),
          ),
        ),
      );

      final res = await _dio.post<dynamic>(
        '$_api/tools/ai-enhance-image',
        data: form,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = res.data;
      if (data is List<int>) return data;
      if (data is List) return data.cast<int>();
      return const <int>[];
    });
  }


  // ===========================================================================
  //  Download / preview URL builders (binary endpoints)
  // ===========================================================================
  //
  // Binary endpoints are not buffered through DTOs. These builders return the
  // absolute URL (joined onto Base_URL) so the DownloadService can stream them
  // to disk and the review/edit canvases can load previews via `Image.network`.

  /// Joins an engine path (absolute, e.g. the `download_url` / `preview_url`
  /// fields the engine returns, possibly with a query string) onto [baseUrl].
  /// An already-absolute URL is returned unchanged.
  Uri resolveUri(String enginePath) {
    final parsed = Uri.parse(enginePath);
    if (parsed.hasScheme) return parsed;
    return baseUrl.replace(
      path: parsed.path,
      query: parsed.hasQuery ? parsed.query : null,
    );
  }

  /// `GET /api/crop/download/{job_id}` with `kind`, `question_prefix`,
  /// `solution_prefix`. `kind` is one of `combined`, `questions`, `solutions`.
  Uri cropDownloadUri(
    String jobId, {
    String kind = 'combined',
    String questionPrefix = 'Q',
    String solutionPrefix = 'S',
  }) {
    return baseUrl.replace(
      path: '$_api/crop/download/$jobId',
      queryParameters: <String, String>{
        'kind': kind,
        'question_prefix': questionPrefix,
        'solution_prefix': solutionPrefix,
      },
    );
  }

  /// `GET /api/analyze/{job_id}/page/{page_no}` — cached page-preview PNG.
  Uri analyzePagePreviewUri(String jobId, int pageNo) {
    return baseUrl.replace(path: '$_api/analyze/$jobId/page/$pageNo');
  }

  /// `GET /api/rename/session/{id}/download` — the packed rename ZIP.
  Uri renameSessionDownloadUri(String sessionId) {
    return baseUrl.replace(path: '$_api/rename/session/$sessionId/download');
  }

  /// `GET /api/tools/compress/download/{job_id}` — the compressed PDF.
  Uri compressDownloadUri(String jobId) {
    return baseUrl.replace(path: '$_api/tools/compress/download/$jobId');
  }

  /// `GET /api/tools/preflight/download/{job_id}` — the normalized PDF.
  Uri preflightDownloadUri(String jobId) {
    return baseUrl.replace(path: '$_api/tools/preflight/download/$jobId');
  }

  /// `GET /api/tools/edit/{job_id}/page/{page_no}` — lazy edit page preview.
  Uri editPagePreviewUri(String jobId, int pageNo) {
    return baseUrl.replace(path: '$_api/tools/edit/$jobId/page/$pageNo');
  }

  /// `GET /api/tools/edit/download/{job_id}` — the edited / OCR'd PDF.
  Uri editDownloadUri(String jobId) {
    return baseUrl.replace(path: '$_api/tools/edit/download/$jobId');
  }

  /// `GET /api/tools/enhance/download/{job_id}` — the enhanced PDF.
  Uri enhanceDownloadUri(String jobId) {
    return baseUrl.replace(path: '$_api/tools/enhance/download/$jobId');
  }

  /// `GET /api/tools/enhance/{job_id}/page/{page_no}` — live preview of enhanced page.
  Uri enhancePagePreviewUri(
    String jobId,
    int pageNo, {
    bool binarize = false,
    double contrast = 1.0,
    double brightness = 1.0,
    int watermarkThreshold = 255,
    bool deskew = false,
    int dpi = 150,
  }) {
    return baseUrl.replace(
      path: '$_api/tools/enhance/$jobId/page/$pageNo',
      queryParameters: <String, String>{
        'binarize': binarize.toString(),
        'contrast': contrast.toString(),
        'brightness': brightness.toString(),
        'watermark_threshold': watermarkThreshold.toString(),
        'deskew': deskew.toString(),
        'dpi': dpi.toString(),
      },
    );
  }

  /// Streaming GET helper for binary endpoints. Returns the raw bytes for an
  /// engine path or absolute URL. Used by tests and as a fallback for the
  /// DownloadService; large saves should stream straight to disk instead.
  Future<List<int>> getBytes(String enginePath) {
    return _guard(() async {
      final res = await _dio.getUri<List<int>>(
        resolveUri(enginePath),
        options: Options(responseType: ResponseType.bytes),
      );
      return res.data ?? const <int>[];
    });
  }

  // ===========================================================================
  //  ML Model Runtime Config & Regex Testing
  // ===========================================================================

  /// `GET /api/config/ml-model` — read the current local ML configuration.
  Future<MLConfigResponse> getMlConfig() {
    return _guard(() async {
      final res = await _dio.get<Map<String, dynamic>>('$_api/config/ml-model');
      return MLConfigResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/config/ml-model` — update the local ML configuration parameters.
  Future<MLConfigResponse> updateMlConfig({
    String? modelPath,
    String? labelsPath,
    String? modelName,
    double? confidence,
    int? inputSize,
  }) {
    return _guard(() async {
      final body = <String, dynamic>{};
      if (modelPath != null) body['model_path'] = modelPath;
      if (labelsPath != null) body['labels_path'] = labelsPath;
      if (modelName != null) body['model_name'] = modelName;
      if (confidence != null) body['confidence'] = confidence;
      if (inputSize != null) body['input_size'] = inputSize;

      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/config/ml-model',
        data: body,
      );
      return MLConfigResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/tools/regex-test` — test a regex pattern against sample text lines.
  Future<RegexTestResponse> testRegex({
    required String pattern,
    required List<String> sampleLines,
  }) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/regex-test',
        data: <String, dynamic>{
          'pattern': pattern,
          'sample_lines': sampleLines,
        },
      );
      return RegexTestResponse.fromJson(res.data!);
    });
  }

  /// `POST /api/tools/align-offsets` — calculate recommended horizontal alignment offsets.
  Future<List<double>> alignOffsets({
    required String jobId,
    required List<QuestionSegment> segments,
  }) {
    return _guard(() async {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_api/tools/align-offsets',
        data: <String, dynamic>{
          'job_id': jobId,
          'segments': segments.map((s) => s.toJson()).toList(),
        },
      );
      final List<dynamic> list = res.data!['offsets'] as List<dynamic>;
      return list.map((dynamic e) => (e as num).toDouble()).toList();
    });
  }

  // ===========================================================================
  //  Error transform
  // ===========================================================================

  /// Runs [fn], converting any [DioException] with an error response into a
  /// typed [ApiException] that carries the engine's `{"detail": ...}` body
  /// verbatim. Non-HTTP failures (timeout, connection refused, cancellation)
  /// surface as `ApiException(0, <message>)`.
  Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  ApiException _toApiException(DioException e) {
    final response = e.response;
    if (response != null) {
      return ApiException(
        response.statusCode ?? 0,
        _extractDetail(response.data) ?? e.message ?? 'Request failed.',
      );
    }
    return ApiException(0, e.message ?? 'Request failed.');
  }

  /// Pulls the engine's `detail` string out of an error body. The body is a
  /// `{"detail": ...}` JSON map, but downloads use byte/stream/plain response
  /// types, so handle a decoded Map, a raw String, and raw bytes.
  String? _extractDetail(dynamic data) {
    if (data == null) return null;
    if (data is Map) {
      final detail = data['detail'];
      return detail?.toString();
    }
    if (data is List<int>) {
      try {
        return _extractDetail(jsonDecode(utf8.decode(data)));
      } catch (_) {
        return null;
      }
    }
    if (data is String) {
      final trimmed = data.trim();
      if (trimmed.startsWith('{')) {
        try {
          return _extractDetail(jsonDecode(trimmed));
        } catch (_) {
          return trimmed;
        }
      }
      return trimmed.isEmpty ? null : trimmed;
    }
    return data.toString();
  }
}
