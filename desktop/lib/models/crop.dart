// Transport-only DTOs mirroring the crop/analyze/finalize/snap schemas in
// `app/models/schemas.py`. These are pure data carriers: they hold exactly the
// fields the FastAPI engine sends and accepts, with the same JSON keys
// (snake_case) and the same nullability. There is NO engine logic in Dart —
// detection, cropping, stitching, OCR and PDF work all stay in the Python
// engine and are reached over HTTP.
//
// Client-only review UI state (e.g. `editing`, `manualOrder`, zoom/pan,
// hovered index) lives in the ReviewController/ReviewState — never here — so it
// is never serialized to the engine.
//
// Mirrors: QuestionSegment, DetectedQuestion, CropResponse, PageInfo,
// AnalyzedItem, ReviewNote, SnapRequest, SnapResponse, FinalizeItem,
// FinalizeRequest, HealthResponse.

/// A single question fragment on a page (page-percentage coordinates).
///
/// `xStartPct`/`xEndPct` describe the horizontal extent of the column the
/// fragment lives in; they default to the full page width so single-column
/// layouts behave exactly as before.
class QuestionSegment {
  const QuestionSegment({
    required this.page,
    required this.yStartPct,
    required this.yEndPct,
    this.xStartPct = 0.0,
    this.xEndPct = 100.0,
  });

  final int page;
  final double yStartPct;
  final double yEndPct;
  final double xStartPct;
  final double xEndPct;

  factory QuestionSegment.fromJson(Map<String, dynamic> json) {
    return QuestionSegment(
      page: (json['page'] as num).toInt(),
      yStartPct: (json['y_start_pct'] as num).toDouble(),
      yEndPct: (json['y_end_pct'] as num).toDouble(),
      xStartPct: (json['x_start_pct'] as num?)?.toDouble() ?? 0.0,
      xEndPct: (json['x_end_pct'] as num?)?.toDouble() ?? 100.0,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'page': page,
      'y_start_pct': yStartPct,
      'y_end_pct': yEndPct,
      'x_start_pct': xStartPct,
      'x_end_pct': xEndPct,
    };
  }
}

/// A detected question (or solution) with one or more page segments.
class DetectedQuestion {
  const DetectedQuestion({
    required this.qNum,
    required this.segments,
    this.isSolution = false,
    this.optionLabels = '',
    this.source = 'auto',
  });

  final String qNum;
  final List<QuestionSegment> segments;
  final bool isSolution;
  final String optionLabels;

  /// "auto" for pipeline detections, "manual" for hand-drawn items.
  final String source;

  factory DetectedQuestion.fromJson(Map<String, dynamic> json) {
    return DetectedQuestion(
      qNum: json['q_num'] as String,
      segments: (json['segments'] as List<dynamic>)
          .map((e) => QuestionSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
      isSolution: json['is_solution'] as bool? ?? false,
      optionLabels: json['option_labels'] as String? ?? '',
      source: json['source'] as String? ?? 'auto',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'q_num': qNum,
      'segments': segments.map((e) => e.toJson()).toList(),
      'is_solution': isSolution,
      'option_labels': optionLabels,
      'source': source,
    };
  }
}

/// Response after creating a crop job.
///
/// `downloadUrl` is the combined archive; `questionsDownloadUrl` /
/// `solutionsDownloadUrl` point to per-type archives and are present only when
/// that side produced at least one crop.
class CropResponse {
  const CropResponse({
    required this.jobId,
    required this.totalQuestions,
    required this.stitchedQuestions,
    required this.methodUsed,
    required this.downloadUrl,
    this.questionsDownloadUrl,
    this.solutionsDownloadUrl,
    this.questionsCount = 0,
    this.solutionsCount = 0,
    this.answerSheetIncluded = false,
    this.answersCount = 0,
  });

  final String jobId;
  final int totalQuestions;
  final int stitchedQuestions;

  /// One of "text", "ocr", "ai".
  final String methodUsed;
  final String downloadUrl;
  final String? questionsDownloadUrl;
  final String? solutionsDownloadUrl;
  final int questionsCount;
  final int solutionsCount;
  final bool answerSheetIncluded;
  final int answersCount;

  factory CropResponse.fromJson(Map<String, dynamic> json) {
    return CropResponse(
      jobId: json['job_id'] as String,
      totalQuestions: (json['total_questions'] as num).toInt(),
      stitchedQuestions: (json['stitched_questions'] as num).toInt(),
      methodUsed: json['method_used'] as String,
      downloadUrl: json['download_url'] as String,
      questionsDownloadUrl: json['questions_download_url'] as String?,
      solutionsDownloadUrl: json['solutions_download_url'] as String?,
      questionsCount: (json['questions_count'] as num?)?.toInt() ?? 0,
      solutionsCount: (json['solutions_count'] as num?)?.toInt() ?? 0,
      answerSheetIncluded: json['answer_sheet_included'] as bool? ?? false,
      answersCount: (json['answers_count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'total_questions': totalQuestions,
      'stitched_questions': stitchedQuestions,
      'method_used': methodUsed,
      'download_url': downloadUrl,
      'questions_download_url': questionsDownloadUrl,
      'solutions_download_url': solutionsDownloadUrl,
      'questions_count': questionsCount,
      'solutions_count': solutionsCount,
      'answer_sheet_included': answerSheetIncluded,
      'answers_count': answersCount,
    };
  }
}

/// Geometry of a single PDF page, used by the manual-crop canvas.
class PageInfo {
  const PageInfo({
    required this.page,
    required this.widthPt,
    required this.heightPt,
    required this.previewUrl,
  });

  final int page; // 1-indexed
  final double widthPt;
  final double heightPt;
  final String previewUrl;

  factory PageInfo.fromJson(Map<String, dynamic> json) {
    return PageInfo(
      page: (json['page'] as num).toInt(),
      widthPt: (json['width_pt'] as num).toDouble(),
      heightPt: (json['height_pt'] as num).toDouble(),
      previewUrl: json['preview_url'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'page': page,
      'width_pt': widthPt,
      'height_pt': heightPt,
      'preview_url': previewUrl,
    };
  }
}

/// A detected (or user-added) item returned for on-screen review.
///
/// `source` distinguishes pipeline detections ("auto") from items the user
/// draws in the review popup ("manual"). `flagged` marks an item the review
/// heuristics are unsure about. These three fields ARE part of the engine
/// contract and are serialized.
class AnalyzedItem {
  const AnalyzedItem({
    required this.qNum,
    required this.segments,
    this.isSolution = false,
    this.source = 'auto',
    this.flagged = false,
    this.flagReason,
  });

  final String qNum;
  final bool isSolution;
  final List<QuestionSegment> segments;
  final String source;
  final bool flagged;
  final String? flagReason;

  factory AnalyzedItem.fromJson(Map<String, dynamic> json) {
    return AnalyzedItem(
      qNum: json['q_num'] as String,
      isSolution: json['is_solution'] as bool? ?? false,
      segments: (json['segments'] as List<dynamic>)
          .map((e) => QuestionSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
      source: json['source'] as String? ?? 'auto',
      flagged: json['flagged'] as bool? ?? false,
      flagReason: json['flag_reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'q_num': qNum,
      'is_solution': isSolution,
      'segments': segments.map((e) => e.toJson()).toList(),
      'source': source,
      'flagged': flagged,
      'flag_reason': flagReason,
    };
  }
}

/// A single human-readable thing to check in the review popup.
class ReviewNote {
  const ReviewNote({
    required this.kind,
    required this.message,
    this.qNum,
    this.page,
    this.isSolution = false,
  });

  /// One of "duplicate", "gap", "tiny", "incomplete", "low_confidence".
  final String kind;
  final String message;
  final String? qNum;
  final int? page;
  final bool isSolution;

  factory ReviewNote.fromJson(Map<String, dynamic> json) {
    return ReviewNote(
      kind: json['kind'] as String,
      message: json['message'] as String,
      qNum: json['q_num'] as String?,
      page: (json['page'] as num?)?.toInt(),
      isSolution: json['is_solution'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind,
      'message': message,
      'q_num': qNum,
      'page': page,
      'is_solution': isSolution,
    };
  }
}

/// A roughly drawn box to tighten to the content inside it (snap request body).
class SnapRequest {
  const SnapRequest({
    required this.jobId,
    required this.page,
    required this.xStartPct,
    required this.xEndPct,
    required this.yStartPct,
    required this.yEndPct,
  });

  final String jobId;
  final int page;
  final double xStartPct;
  final double xEndPct;
  final double yStartPct;
  final double yEndPct;

  factory SnapRequest.fromJson(Map<String, dynamic> json) {
    return SnapRequest(
      jobId: json['job_id'] as String,
      page: (json['page'] as num).toInt(),
      xStartPct: (json['x_start_pct'] as num).toDouble(),
      xEndPct: (json['x_end_pct'] as num).toDouble(),
      yStartPct: (json['y_start_pct'] as num).toDouble(),
      yEndPct: (json['y_end_pct'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'page': page,
      'x_start_pct': xStartPct,
      'x_end_pct': xEndPct,
      'y_start_pct': yStartPct,
      'y_end_pct': yEndPct,
    };
  }
}

/// The content-tightened region returned by snap (page percentages).
class SnapResponse {
  const SnapResponse({
    required this.xStartPct,
    required this.xEndPct,
    required this.yStartPct,
    required this.yEndPct,
  });

  final double xStartPct;
  final double xEndPct;
  final double yStartPct;
  final double yEndPct;

  factory SnapResponse.fromJson(Map<String, dynamic> json) {
    return SnapResponse(
      xStartPct: (json['x_start_pct'] as num).toDouble(),
      xEndPct: (json['x_end_pct'] as num).toDouble(),
      yStartPct: (json['y_start_pct'] as num).toDouble(),
      yEndPct: (json['y_end_pct'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'x_start_pct': xStartPct,
      'x_end_pct': xEndPct,
      'y_start_pct': yStartPct,
      'y_end_pct': yEndPct,
    };
  }
}

/// One item to crop in the finalize step (auto-kept or manually drawn).
class FinalizeItem {
  const FinalizeItem({
    required this.qNum,
    required this.segments,
    this.isSolution = false,
    this.source = 'auto',
  });

  final String qNum;
  final bool isSolution;
  final List<QuestionSegment> segments;
  final String source;

  factory FinalizeItem.fromJson(Map<String, dynamic> json) {
    return FinalizeItem(
      qNum: json['q_num'] as String,
      isSolution: json['is_solution'] as bool? ?? false,
      segments: (json['segments'] as List<dynamic>)
          .map((e) => QuestionSegment.fromJson(e as Map<String, dynamic>))
          .toList(),
      source: json['source'] as String? ?? 'auto',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'q_num': qNum,
      'is_solution': isSolution,
      'segments': segments.map((e) => e.toJson()).toList(),
      'source': source,
    };
  }
}

/// Payload that turns a reviewed item list into the downloadable ZIP.
class FinalizeRequest {
  const FinalizeRequest({
    required this.jobId,
    required this.items,
    this.dpi = 200,
    this.padding = 20,
    this.questionPrefix = 'Q',
    this.solutionPrefix = 'S',
    this.startNumber = 1,
    this.imageFormat = 'png',
    this.jpgQuality = 90,
    this.answerSheet = true,
  });

  final String jobId;
  final List<FinalizeItem> items;
  final int dpi;
  final int padding;
  final String questionPrefix;
  final String solutionPrefix;
  final int startNumber;

  /// One of "png", "jpg", "jpeg".
  final String imageFormat;
  final int jpgQuality;
  final bool answerSheet;

  factory FinalizeRequest.fromJson(Map<String, dynamic> json) {
    return FinalizeRequest(
      jobId: json['job_id'] as String,
      items: (json['items'] as List<dynamic>)
          .map((e) => FinalizeItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      dpi: (json['dpi'] as num?)?.toInt() ?? 200,
      padding: (json['padding'] as num?)?.toInt() ?? 20,
      questionPrefix: json['question_prefix'] as String? ?? 'Q',
      solutionPrefix: json['solution_prefix'] as String? ?? 'S',
      startNumber: (json['start_number'] as num?)?.toInt() ?? 1,
      imageFormat: json['image_format'] as String? ?? 'png',
      jpgQuality: (json['jpg_quality'] as num?)?.toInt() ?? 90,
      answerSheet: json['answer_sheet'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'items': items.map((e) => e.toJson()).toList(),
      'dpi': dpi,
      'padding': padding,
      'question_prefix': questionPrefix,
      'solution_prefix': solutionPrefix,
      'start_number': startNumber,
      'image_format': imageFormat,
      'jpg_quality': jpgQuality,
      'answer_sheet': answerSheet,
    };
  }
}

/// Engine health/status (GET /api/health).
class HealthResponse {
  const HealthResponse({
    required this.status,
    required this.tesseractAvailable,
    required this.aiAvailable,
    required this.version,
    this.aiProvider,
    this.aiModel,
  });

  final String status;
  final bool tesseractAvailable;
  final bool aiAvailable;
  final String version;
  final String? aiProvider;
  final String? aiModel;

  factory HealthResponse.fromJson(Map<String, dynamic> json) {
    return HealthResponse(
      status: json['status'] as String,
      tesseractAvailable: json['tesseract_available'] as bool,
      aiAvailable: json['ai_available'] as bool,
      version: json['version'] as String,
      aiProvider: json['ai_provider'] as String?,
      aiModel: json['ai_model'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'status': status,
      'tesseract_available': tesseractAvailable,
      'ai_available': aiAvailable,
      'version': version,
      'ai_provider': aiProvider,
      'ai_model': aiModel,
    };
  }
}
