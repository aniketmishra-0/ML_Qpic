// Transport-only DTOs for the PDF power tools (Compress / Edit + OCR /
// Preflight), mirroring the tool schemas in `app/models/schemas.py`:
//   CompressResponse,
//   EditableSpanModel, EditPageModel, EditExtractResponse,
//   EditOpModel, OperationModel, EditApplyRequest, EditApplyResponse,
//   OcrResponse,
//   PreflightCheckModel, PreflightFontModel, PreflightImageModel,
//   PreflightPageDetail, PreflightResponse, PreflightFixResponse.
//
// Pure data carriers with exact engine JSON keys and nullability. No engine
// logic in Dart — Compress/Preflight/Edit/OCR all run in the Python engine.

// ============================================================================
//  Compress
// ============================================================================

/// Result of a PDF compression job.
class CompressResponse {
  const CompressResponse({
    required this.jobId,
    required this.originalSize,
    required this.compressedSize,
    required this.ratio,
    required this.level,
    required this.downloadUrl,
    this.targetMet,
    this.note = '',
  });

  final String jobId;
  final int originalSize;
  final int compressedSize;

  /// Fraction of original size removed (0.0-1.0).
  final double ratio;
  final String level;
  final bool? targetMet;
  final String note;
  final String downloadUrl;

  factory CompressResponse.fromJson(Map<String, dynamic> json) {
    return CompressResponse(
      jobId: json['job_id'] as String,
      originalSize: (json['original_size'] as num).toInt(),
      compressedSize: (json['compressed_size'] as num).toInt(),
      ratio: (json['ratio'] as num).toDouble(),
      level: json['level'] as String,
      targetMet: json['target_met'] as bool?,
      note: json['note'] as String? ?? '',
      downloadUrl: json['download_url'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'original_size': originalSize,
      'compressed_size': compressedSize,
      'ratio': ratio,
      'level': level,
      'target_met': targetMet,
      'note': note,
      'download_url': downloadUrl,
    };
  }
}

// ============================================================================
//  Edit + OCR
// ============================================================================

/// One editable text run on a page, with its geometry and style.
class EditableSpanModel {
  const EditableSpanModel({
    required this.id,
    required this.page,
    required this.text,
    required this.bbox,
    required this.font,
    required this.size,
    required this.color,
    this.bold = false,
    this.italic = false,
  });

  final String id;
  final int page;
  final String text;

  /// [x0, y0, x1, y1] in PDF points.
  final List<double> bbox;
  final String font;
  final double size;
  final int color;
  final bool bold;
  final bool italic;

  factory EditableSpanModel.fromJson(Map<String, dynamic> json) {
    return EditableSpanModel(
      id: json['id'] as String,
      page: (json['page'] as num).toInt(),
      text: json['text'] as String,
      bbox: (json['bbox'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      font: json['font'] as String,
      size: (json['size'] as num).toDouble(),
      color: (json['color'] as num).toInt(),
      bold: json['bold'] as bool? ?? false,
      italic: json['italic'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'page': page,
      'text': text,
      'bbox': bbox,
      'font': font,
      'size': size,
      'color': color,
      'bold': bold,
      'italic': italic,
    };
  }
}

/// Geometry + preview for one page in the editor.
class EditPageModel {
  const EditPageModel({
    required this.page,
    required this.width,
    required this.height,
    required this.previewUrl,
  });

  final int page;
  final double width;
  final double height;
  final String previewUrl;

  factory EditPageModel.fromJson(Map<String, dynamic> json) {
    return EditPageModel(
      page: (json['page'] as num).toInt(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      previewUrl: json['preview_url'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'page': page,
      'width': width,
      'height': height,
      'preview_url': previewUrl,
    };
  }
}

/// One selectable vector graphic or image object on a page.
class VectorObjectModel {
  const VectorObjectModel({
    required this.id,
    required this.page,
    required this.type,
    required this.bbox,
  });

  final String id;
  final int page;
  final String type; // "image" or "vector"
  final List<double> bbox;

  factory VectorObjectModel.fromJson(Map<String, dynamic> json) {
    return VectorObjectModel(
      id: json['id'] as String,
      page: (json['page'] as num).toInt(),
      type: json['type'] as String,
      bbox: (json['bbox'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'page': page,
      'type': type,
      'bbox': bbox,
    };
  }
}

/// All editable text spans for a PDF opened in the editor.
class EditExtractResponse {
  const EditExtractResponse({
    required this.jobId,
    required this.hasText,
    required this.pages,
    required this.spans,
    this.vectorObjects = const <VectorObjectModel>[],
  });

  final String jobId;
  final bool hasText;
  final List<EditPageModel> pages;
  final List<EditableSpanModel> spans;
  final List<VectorObjectModel> vectorObjects;

  factory EditExtractResponse.fromJson(Map<String, dynamic> json) {
    return EditExtractResponse(
      jobId: json['job_id'] as String,
      hasText: json['has_text'] as bool,
      pages: (json['pages'] as List<dynamic>)
          .map((e) => EditPageModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      spans: (json['spans'] as List<dynamic>)
          .map((e) => EditableSpanModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      vectorObjects: ((json['vector_objects'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => VectorObjectModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'has_text': hasText,
      'pages': pages.map((e) => e.toJson()).toList(),
      'spans': spans.map((e) => e.toJson()).toList(),
      'vector_objects': vectorObjects.map((e) => e.toJson()).toList(),
    };
  }
}

/// A single span edit submitted from the editor (legacy text-only).
class EditOpModel {
  const EditOpModel({
    required this.page,
    required this.bbox,
    required this.newText,
    this.font,
    this.size,
    this.color,
  });

  final int page;
  final List<double> bbox;
  final String newText;
  final String? font;
  final double? size;
  final int? color;

  factory EditOpModel.fromJson(Map<String, dynamic> json) {
    return EditOpModel(
      page: (json['page'] as num).toInt(),
      bbox: (json['bbox'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      newText: json['new_text'] as String,
      font: json['font'] as String?,
      size: (json['size'] as num?)?.toDouble(),
      color: (json['color'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'page': page,
      'bbox': bbox,
      'new_text': newText,
      'font': font,
      'size': size,
      'color': color,
    };
  }
}

/// A single Acrobat-style edit operation submitted from the editor.
///
/// `type` is one of: `edit_text`, `add_text`, `add_image`, `add_link`, `erase`.
class OperationModel {
  const OperationModel({
    required this.type,
    required this.page,
    required this.bbox,
    this.text = '',
    this.font,
    this.size,
    this.color,
    this.bold = false,
    this.italic = false,
    this.align = 0,
    this.imageB64,
    this.url,
    this.fill,
  });

  final String type;
  final int page;
  final List<double> bbox;
  final String text;
  final String? font;
  final double? size;
  final int? color;
  final bool bold;
  final bool italic;
  final int align;
  final String? imageB64;
  final String? url;
  final int? fill;

  factory OperationModel.fromJson(Map<String, dynamic> json) {
    return OperationModel(
      type: json['type'] as String,
      page: (json['page'] as num).toInt(),
      bbox: (json['bbox'] as List<dynamic>)
          .map((e) => (e as num).toDouble())
          .toList(),
      text: json['text'] as String? ?? '',
      font: json['font'] as String?,
      size: (json['size'] as num?)?.toDouble(),
      color: (json['color'] as num?)?.toInt(),
      bold: json['bold'] as bool? ?? false,
      italic: json['italic'] as bool? ?? false,
      align: (json['align'] as num?)?.toInt() ?? 0,
      imageB64: json['image_b64'] as String?,
      url: json['url'] as String?,
      fill: (json['fill'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': type,
      'page': page,
      'bbox': bbox,
      'text': text,
      'font': font,
      'size': size,
      'color': color,
      'bold': bold,
      'italic': italic,
      'align': align,
      'image_b64': imageB64,
      'url': url,
      'fill': fill,
    };
  }
}

/// Payload that applies a set of in-place text edits to a job's PDF.
///
/// Either `edits` (legacy text-only) or `operations` (full Acrobat-style set)
/// may be supplied; `operations` wins when both are present.
class EditApplyRequest {
  const EditApplyRequest({
    required this.jobId,
    this.edits = const <EditOpModel>[],
    this.operations = const <OperationModel>[],
  });

  final String jobId;
  final List<EditOpModel> edits;
  final List<OperationModel> operations;

  factory EditApplyRequest.fromJson(Map<String, dynamic> json) {
    return EditApplyRequest(
      jobId: json['job_id'] as String,
      edits: ((json['edits'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => EditOpModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      operations: ((json['operations'] as List<dynamic>?) ?? const <dynamic>[])
          .map((e) => OperationModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'edits': edits.map((e) => e.toJson()).toList(),
      'operations': operations.map((e) => e.toJson()).toList(),
    };
  }
}

/// The edited PDF is ready for download.
class EditApplyResponse {
  const EditApplyResponse({
    required this.jobId,
    required this.editsApplied,
    required this.downloadUrl,
  });

  final String jobId;
  final int editsApplied;
  final String downloadUrl;

  factory EditApplyResponse.fromJson(Map<String, dynamic> json) {
    return EditApplyResponse(
      jobId: json['job_id'] as String,
      editsApplied: (json['edits_applied'] as num).toInt(),
      downloadUrl: json['download_url'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'edits_applied': editsApplied,
      'download_url': downloadUrl,
    };
  }
}

/// Result of adding a searchable OCR text layer to a PDF.
class OcrResponse {
  const OcrResponse({
    required this.jobId,
    required this.pagesOcred,
    required this.languages,
    required this.note,
    required this.downloadUrl,
  });

  final String jobId;
  final int pagesOcred;
  final String languages;
  final String note;
  final String downloadUrl;

  factory OcrResponse.fromJson(Map<String, dynamic> json) {
    return OcrResponse(
      jobId: json['job_id'] as String,
      pagesOcred: (json['pages_ocred'] as num).toInt(),
      languages: json['languages'] as String,
      note: json['note'] as String,
      downloadUrl: json['download_url'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'pages_ocred': pagesOcred,
      'languages': languages,
      'note': note,
      'download_url': downloadUrl,
    };
  }
}

// ============================================================================
//  Preflight
// ============================================================================

/// A single preflight check result.
class PreflightCheckModel {
  const PreflightCheckModel({
    required this.id,
    required this.title,
    required this.status,
    required this.detail,
  });

  final String id;
  final String title;

  /// One of: ok | warn | fail | info.
  final String status;
  final String detail;

  factory PreflightCheckModel.fromJson(Map<String, dynamic> json) {
    return PreflightCheckModel(
      id: json['id'] as String,
      title: json['title'] as String,
      status: json['status'] as String,
      detail: json['detail'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'status': status,
      'detail': detail,
    };
  }
}

/// A font referenced by the PDF.
class PreflightFontModel {
  const PreflightFontModel({
    required this.name,
    required this.type,
    required this.embedded,
    required this.subset,
  });

  final String name;
  final String type;
  final bool embedded;
  final bool subset;

  factory PreflightFontModel.fromJson(Map<String, dynamic> json) {
    return PreflightFontModel(
      name: json['name'] as String,
      type: json['type'] as String,
      embedded: json['embedded'] as bool,
      subset: json['subset'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'type': type,
      'embedded': embedded,
      'subset': subset,
    };
  }
}

/// An image referenced by the PDF.
class PreflightImageModel {
  const PreflightImageModel({
    required this.page,
    required this.width,
    required this.height,
    required this.dpi,
    required this.colorspace,
    required this.bpc,
  });

  final int page;
  final int width;
  final int height;
  final double dpi;
  final String colorspace;
  final int bpc;

  factory PreflightImageModel.fromJson(Map<String, dynamic> json) {
    return PreflightImageModel(
      page: (json['page'] as num).toInt(),
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      dpi: (json['dpi'] as num).toDouble(),
      colorspace: json['colorspace'] as String,
      bpc: (json['bpc'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'page': page,
      'width': width,
      'height': height,
      'dpi': dpi,
      'colorspace': colorspace,
      'bpc': bpc,
    };
  }
}

/// Per-page geometry detail for the Preflight Check table.
class PreflightPageDetail {
  const PreflightPageDetail({
    required this.page,
    required this.wMm,
    required this.hMm,
    required this.wPt,
    required this.hPt,
    required this.wPx,
    required this.hPx,
    required this.format,
    required this.orientation,
  });

  final int page;
  final double wMm;
  final double hMm;
  final double wPt;
  final double hPt;
  final int wPx;
  final int hPx;

  /// "A4" | "A3" | "Letter" | "Legal" | "A5" | "Custom".
  final String format;

  /// "Portrait" | "Landscape".
  final String orientation;

  factory PreflightPageDetail.fromJson(Map<String, dynamic> json) {
    return PreflightPageDetail(
      page: (json['page'] as num).toInt(),
      wMm: (json['w_mm'] as num).toDouble(),
      hMm: (json['h_mm'] as num).toDouble(),
      wPt: (json['w_pt'] as num).toDouble(),
      hPt: (json['h_pt'] as num).toDouble(),
      wPx: (json['w_px'] as num).toInt(),
      hPx: (json['h_px'] as num).toInt(),
      format: json['format'] as String,
      orientation: json['orientation'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'page': page,
      'w_mm': wMm,
      'h_mm': hMm,
      'w_pt': wPt,
      'h_pt': hPt,
      'w_px': wPx,
      'h_px': hPx,
      'format': format,
      'orientation': orientation,
    };
  }
}

/// Full read-only preflight report for a PDF.
class PreflightResponse {
  const PreflightResponse({
    required this.verdict,
    required this.pageCount,
    required this.pageSizes,
    required this.fileSize,
    required this.isEncrypted,
    required this.hasTextLayer,
    required this.checks,
    required this.fonts,
    required this.images,
    required this.metadata,
    this.distinctPageSizes = const <String>[],
    this.mixedPageSizes = false,
    this.pageDetails = const <PreflightPageDetail>[],
  });

  /// pass | warn | fail.
  final String verdict;
  final int pageCount;
  final List<String> pageSizes;
  final int fileSize;
  final bool isEncrypted;
  final bool hasTextLayer;
  final List<PreflightCheckModel> checks;
  final List<PreflightFontModel> fonts;
  final List<PreflightImageModel> images;
  final Map<String, String> metadata;
  final List<String> distinctPageSizes;
  final bool mixedPageSizes;
  final List<PreflightPageDetail> pageDetails;

  factory PreflightResponse.fromJson(Map<String, dynamic> json) {
    return PreflightResponse(
      verdict: json['verdict'] as String,
      pageCount: (json['page_count'] as num).toInt(),
      pageSizes: (json['page_sizes'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      fileSize: (json['file_size'] as num).toInt(),
      isEncrypted: json['is_encrypted'] as bool,
      hasTextLayer: json['has_text_layer'] as bool,
      checks: (json['checks'] as List<dynamic>)
          .map((e) => PreflightCheckModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      fonts: (json['fonts'] as List<dynamic>)
          .map((e) => PreflightFontModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      images: (json['images'] as List<dynamic>)
          .map((e) => PreflightImageModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      metadata: (json['metadata'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, value as String),
      ),
      distinctPageSizes:
          ((json['distinct_page_sizes'] as List<dynamic>?) ?? const <dynamic>[])
              .map((e) => e as String)
              .toList(),
      mixedPageSizes: json['mixed_page_sizes'] as bool? ?? false,
      pageDetails:
          ((json['page_details'] as List<dynamic>?) ?? const <dynamic>[])
              .map((e) =>
                  PreflightPageDetail.fromJson(e as Map<String, dynamic>))
              .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'verdict': verdict,
      'page_count': pageCount,
      'page_sizes': pageSizes,
      'file_size': fileSize,
      'is_encrypted': isEncrypted,
      'has_text_layer': hasTextLayer,
      'checks': checks.map((e) => e.toJson()).toList(),
      'fonts': fonts.map((e) => e.toJson()).toList(),
      'images': images.map((e) => e.toJson()).toList(),
      'metadata': metadata,
      'distinct_page_sizes': distinctPageSizes,
      'mixed_page_sizes': mixedPageSizes,
      'page_details': pageDetails.map((e) => e.toJson()).toList(),
    };
  }
}

/// Result of normalizing a PDF's pages to one uniform size.
class PreflightFixResponse {
  const PreflightFixResponse({
    required this.jobId,
    required this.targetLabel,
    required this.targetWidth,
    required this.targetHeight,
    required this.pagesTotal,
    required this.pagesChanged,
    required this.note,
    required this.downloadUrl,
  });

  final String jobId;
  final String targetLabel;
  final double targetWidth; // PDF points
  final double targetHeight; // PDF points
  final int pagesTotal;
  final int pagesChanged;
  final String note;
  final String downloadUrl;

  factory PreflightFixResponse.fromJson(Map<String, dynamic> json) {
    return PreflightFixResponse(
      jobId: json['job_id'] as String,
      targetLabel: json['target_label'] as String,
      targetWidth: (json['target_width'] as num).toDouble(),
      targetHeight: (json['target_height'] as num).toDouble(),
      pagesTotal: (json['pages_total'] as num).toInt(),
      pagesChanged: (json['pages_changed'] as num).toInt(),
      note: json['note'] as String,
      downloadUrl: json['download_url'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'target_label': targetLabel,
      'target_width': targetWidth,
      'target_height': targetHeight,
      'pages_total': pagesTotal,
      'pages_changed': pagesChanged,
      'note': note,
      'download_url': downloadUrl,
    };
  }
}

// ============================================================================
//  Enhance
// ============================================================================

/// Result of a PDF enhancement job.
class EnhanceResponse {
  const EnhanceResponse({
    required this.jobId,
    required this.pagesTotal,
    required this.downloadUrl,
    this.note = '',
  });

  final String jobId;
  final int pagesTotal;
  final String downloadUrl;
  final String note;

  factory EnhanceResponse.fromJson(Map<String, dynamic> json) {
    return EnhanceResponse(
      jobId: json['job_id'] as String,
      pagesTotal: (json['pages_total'] as num).toInt(),
      downloadUrl: json['download_url'] as String,
      note: json['note'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'pages_total': pagesTotal,
      'download_url': downloadUrl,
      'note': note,
    };
  }
}

