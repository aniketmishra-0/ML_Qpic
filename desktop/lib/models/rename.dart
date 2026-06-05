// Transport-only DTOs for the Rename Batch tool, mirroring the rename schemas
// in `app/models/schemas.py`:
//   RenamePlanItem, RenamePreviewResponse, PdfImageItem, PdfToImagesResponse,
//   RenameSessionResponse, RenameUploadResponse, RenameFinalizeResponse.
//
// Pure data carriers with exact engine JSON keys and nullability. No engine
// logic in Dart. The UI's variable-token expansion is computed in the rename
// feature controller and sent as explicit stems; it is not part of these DTOs.

/// A single before/after pair in a rename preview.
class RenamePlanItem {
  const RenamePlanItem({
    required this.original,
    required this.renamed,
  });

  final String original;
  final String renamed;

  factory RenamePlanItem.fromJson(Map<String, dynamic> json) {
    return RenamePlanItem(
      original: json['original'] as String,
      renamed: json['renamed'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'original': original,
      'renamed': renamed,
    };
  }
}

/// Preview of how a batch of files will be renamed.
class RenamePreviewResponse {
  const RenamePreviewResponse({
    required this.count,
    required this.items,
  });

  final int count;
  final List<RenamePlanItem> items;

  factory RenamePreviewResponse.fromJson(Map<String, dynamic> json) {
    return RenamePreviewResponse(
      count: (json['count'] as num).toInt(),
      items: (json['items'] as List<dynamic>)
          .map((e) => RenamePlanItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'count': count,
      'items': items.map((e) => e.toJson()).toList(),
    };
  }
}

/// One PDF page rendered to a PNG, returned as an inline `data:` URL.
class PdfImageItem {
  const PdfImageItem({
    required this.name,
    required this.dataUrl,
    required this.width,
    required this.height,
    required this.size,
  });

  final String name;
  final String dataUrl;
  final int width;
  final int height;
  final int size;

  factory PdfImageItem.fromJson(Map<String, dynamic> json) {
    return PdfImageItem(
      name: json['name'] as String,
      dataUrl: json['data_url'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      size: (json['size'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'data_url': dataUrl,
      'width': width,
      'height': height,
      'size': size,
    };
  }
}

/// All pages of an uploaded PDF, rasterised to PNG images.
class PdfToImagesResponse {
  const PdfToImagesResponse({
    required this.count,
    required this.images,
  });

  final int count;
  final List<PdfImageItem> images;

  factory PdfToImagesResponse.fromJson(Map<String, dynamic> json) {
    return PdfToImagesResponse(
      count: (json['count'] as num).toInt(),
      images: (json['images'] as List<dynamic>)
          .map((e) => PdfImageItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'count': count,
      'images': images.map((e) => e.toJson()).toList(),
    };
  }
}

/// One PDF page rendered to a JPEG file on disk, served via a URL.
class PdfPageItem {
  const PdfPageItem({
    required this.name,
    required this.pageUrl,
    required this.width,
    required this.height,
    required this.size,
  });

  final String name;
  final String pageUrl;
  final int width;
  final int height;
  final int size;

  factory PdfPageItem.fromJson(Map<String, dynamic> json) {
    return PdfPageItem(
      name: json['name'] as String,
      pageUrl: json['page_url'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      size: (json['size'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'page_url': pageUrl,
      'width': width,
      'height': height,
      'size': size,
    };
  }
}

/// PDF uploaded and rendered to per-page images on disk.
class PdfToSessionResponse {
  const PdfToSessionResponse({
    required this.jobId,
    required this.count,
    required this.pages,
  });

  final String jobId;
  final int count;
  final List<PdfPageItem> pages;

  factory PdfToSessionResponse.fromJson(Map<String, dynamic> json) {
    return PdfToSessionResponse(
      jobId: json['job_id'] as String,
      count: (json['count'] as num).toInt(),
      pages: (json['pages'] as List<dynamic>)
          .map((e) => PdfPageItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'job_id': jobId,
      'count': count,
      'pages': pages.map((e) => e.toJson()).toList(),
    };
  }
}

/// A freshly created upload session for a large rename batch.
class RenameSessionResponse {
  const RenameSessionResponse({required this.sessionId});

  final String sessionId;

  factory RenameSessionResponse.fromJson(Map<String, dynamic> json) {
    return RenameSessionResponse(
      sessionId: json['session_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'session_id': sessionId,
    };
  }
}

/// Acknowledges a chunk of files appended to a rename session.
class RenameUploadResponse {
  const RenameUploadResponse({
    required this.sessionId,
    required this.received,
    required this.total,
  });

  final String sessionId;
  final int received; // files accepted in this request
  final int total; // files staged in the session so far

  factory RenameUploadResponse.fromJson(Map<String, dynamic> json) {
    return RenameUploadResponse(
      sessionId: json['session_id'] as String,
      received: (json['received'] as num).toInt(),
      total: (json['total'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'session_id': sessionId,
      'received': received,
      'total': total,
    };
  }
}

/// The packed ZIP is ready; `downloadUrl` streams it to the client.
class RenameFinalizeResponse {
  const RenameFinalizeResponse({
    required this.sessionId,
    required this.count,
    required this.downloadUrl,
    this.excelDownloadUrl,
  });

  final String sessionId;
  final int count;
  final String downloadUrl;
  final String? excelDownloadUrl;

  factory RenameFinalizeResponse.fromJson(Map<String, dynamic> json) {
    return RenameFinalizeResponse(
      sessionId: json['session_id'] as String,
      count: (json['count'] as num).toInt(),
      downloadUrl: json['download_url'] as String,
      excelDownloadUrl: json['excel_download_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'session_id': sessionId,
      'count': count,
      'download_url': downloadUrl,
      'excel_download_url': excelDownloadUrl,
    };
  }
}
