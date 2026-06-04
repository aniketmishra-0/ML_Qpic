// Transport-only DTO for the smart analyze pass, mirroring `AnalyzeResponse`
// in `app/models/schemas.py`. It composes the shared review types
// (`PageInfo`, `AnalyzedItem`, `ReviewNote`) declared in `crop.dart`, so they
// have a single source of truth and identical JSON shapes.
//
// No engine logic in Dart — this only carries the JSON the `/api/analyze`
// endpoint returns.

import 'crop.dart';

/// Result of the smart analyze pass, before final ZIP generation.
class AnalyzeResponse {
  const AnalyzeResponse({
    required this.jobId,
    required this.totalPages,
    required this.methodUsed,
    required this.pages,
    required this.items,
    required this.notes,
    required this.needsReview,
    this.answerKeyCount = 0,
    this.bilingualDetected = false,
  });

  final String jobId;
  final int totalPages;

  /// One of "text", "ocr", "ai".
  final String methodUsed;
  final List<PageInfo> pages;
  final List<AnalyzedItem> items;
  final List<ReviewNote> notes;
  final bool needsReview;

  /// Number of answers parsed from the paper's answer key (0 when none found).
  final int answerKeyCount;

  /// True when the detector found a bilingual side-by-side layout (English/Hindi).
  final bool bilingualDetected;

  factory AnalyzeResponse.fromJson(Map<String, dynamic> json) {
    return AnalyzeResponse(
      jobId: json['job_id'] as String,
      totalPages: (json['total_pages'] as num).toInt(),
      methodUsed: json['method_used'] as String,
      pages: (json['pages'] as List<dynamic>)
          .map((e) => PageInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      items: (json['items'] as List<dynamic>)
          .map((e) => AnalyzedItem.fromJson(e as Map<String, dynamic>))
          .toList(),
      notes: (json['notes'] as List<dynamic>)
          .map((e) => ReviewNote.fromJson(e as Map<String, dynamic>))
          .toList(),
      needsReview: json['needs_review'] as bool,
      answerKeyCount: (json['answer_key_count'] as num?)?.toInt() ?? 0,
      bilingualDetected: json['bilingual_detected'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'total_pages': totalPages,
      'method_used': methodUsed,
      'pages': pages.map((e) => e.toJson()).toList(),
      'items': items.map((e) => e.toJson()).toList(),
      'notes': notes.map((e) => e.toJson()).toList(),
      'needs_review': needsReview,
      'answer_key_count': answerKeyCount,
      'bilingual_detected': bilingualDetected,
    };
  }
}
