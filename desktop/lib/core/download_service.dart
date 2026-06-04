// Native Save-As + streamed download for engine-produced files (Req 11, 16).
//
// A localhost sidecar cannot trigger a browser download (no download manager
// for `<a download>` / `blob:` URLs), so this service reproduces the
// `SaveBridge.save_url` flow from `desktop.py`: pop a native Save-As dialog for
// a suggested filename, then stream the engine URL straight to the chosen path
// in chunks so even a multi-gigabyte ZIP is written with a flat memory
// footprint (the Dart equivalent of `shutil.copyfileobj(resp, out, 1MB)`).
//
// There is no engine logic here. Download targets are always engine URLs
// joined onto Base_URL by [ApiClient.resolveUri] (combined / questions /
// solutions zips, compressed / normalized / edited PDFs, the rename zip), and
// the same Dio instance is reused so connection settings match the API client.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart' as fs;
import 'package:file_selector/file_selector.dart'
    show FileSaveLocation, XTypeGroup;

import 'api_client.dart';

/// How a [DownloadService.download] call ended.
enum DownloadStatus {
  /// The bytes were streamed to the user's chosen path.
  saved,

  /// The user cancelled — either by dismissing the Save-As dialog or by
  /// cancelling the in-flight transfer. No file is left behind (Req 16.4).
  cancelled,
}

/// The result of a download attempt.
///
/// Success/cancel are returned (not thrown) so the UI can treat a user cancel
/// as an ordinary, non-error outcome; only genuine failures raise
/// [DownloadException] (Req 16.5).
class DownloadResult {
  const DownloadResult._(this.status, this.path);

  /// The bytes were saved to [path].
  const DownloadResult.saved(String path) : this._(DownloadStatus.saved, path);

  /// The user cancelled; no file was written.
  const DownloadResult.cancelled() : this._(DownloadStatus.cancelled, null);

  /// Whether this download ended by saving a file.
  final DownloadStatus status;

  /// The absolute path the file was saved to, or `null` when [cancelled].
  final String? path;

  /// Convenience flag mirroring [DownloadStatus.saved].
  bool get isSaved => status == DownloadStatus.saved;

  /// Convenience flag mirroring [DownloadStatus.cancelled].
  bool get isCancelled => status == DownloadStatus.cancelled;
}

/// A readable failure surfaced when a download cannot complete (Req 16.5).
///
/// When the engine answered with a `{"detail": ...}` error body, [message]
/// carries that detail verbatim and [statusCode] the HTTP status; otherwise
/// [message] is a human-readable description of the transport failure
/// (timeout, connection refused, disk error, ...).
class DownloadException implements Exception {
  const DownloadException(this.message, {this.statusCode, this.cause});

  /// A message safe to show the user.
  final String message;

  /// The engine HTTP status code when the failure was an error response, else
  /// `null` (failure happened before/without an HTTP response).
  final int? statusCode;

  /// The underlying error, retained for logging/diagnostics.
  final Object? cause;

  @override
  String toString() => 'DownloadException: $message';
}

/// Presents a native Save-As dialog and returns the chosen location, or `null`
/// if the user cancels. Injectable so tests can drive the flow without the
/// platform file-dialog channel.
typedef SaveLocationResolver = Future<FileSaveLocation?> Function({
  required String suggestedName,
  required List<XTypeGroup> acceptedTypeGroups,
});

/// Streams the bytes at [uri] to [savePath] without fully buffering. Injectable
/// so tests can substitute the real Dio download. Implementations MUST delete
/// any partial file on error or cancellation.
typedef FileDownloader = Future<void> Function(
  Uri uri,
  String savePath, {
  CancelToken? cancelToken,
  ProgressCallback? onReceiveProgress,
});

/// Saves engine-produced files to disk via a native Save-As dialog + streamed
/// download.
class DownloadService {
  /// Creates a service bound to [apiClient] (whose Dio + Base_URL are reused).
  ///
  /// [saveLocationResolver] and [downloader] default to the real
  /// `file_selector` dialog and a streamed `Dio.downloadUri`; they exist so
  /// tests can exercise the flow deterministically.
  DownloadService(
    this.apiClient, {
    SaveLocationResolver? saveLocationResolver,
    FileDownloader? downloader,
  })  : _resolveSaveLocation = saveLocationResolver ?? _defaultSaveLocation,
        _downloader = downloader ?? _streamWith(apiClient.dio);

  /// The API client used to join engine paths onto Base_URL and to stream over
  /// the same Dio connection.
  final ApiClient apiClient;

  final SaveLocationResolver _resolveSaveLocation;
  final FileDownloader _downloader;

  /// Downloads the engine file at [engineUrl] to a user-chosen path.
  ///
  /// [engineUrl] may be absolute or engine-relative (e.g. a `download_url`
  /// like `/api/crop/download/{job}?kind=combined`); it is joined onto
  /// Base_URL via [ApiClient.resolveUri] (Req 16.2). [suggestedName] seeds the
  /// native Save-As dialog (Req 16.1).
  ///
  /// The bytes are streamed to disk in chunks so large archives never buffer
  /// fully in memory (Req 16.3). Pass a [cancelToken] to let the UI abort an
  /// in-flight transfer; the partial file is removed (Req 16.4). [onProgress]
  /// reports received/total bytes when the engine sends a Content-Length.
  ///
  /// Returns [DownloadResult.cancelled] when the user dismisses the dialog or
  /// cancels the transfer (no file written), or [DownloadResult.saved] with the
  /// chosen path on success. Throws [DownloadException] with a readable message
  /// on failure (Req 16.5).
  Future<DownloadResult> download({
    required String engineUrl,
    required String suggestedName,
    CancelToken? cancelToken,
    List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
    void Function(int received, int total)? onProgress,
  }) async {
    // 1) Native Save-As (Req 16.1). A null location means the user cancelled,
    //    so we abort before fetching anything — no file is written (Req 16.4).
    final FileSaveLocation? location = await _resolveSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: acceptedTypeGroups,
    );
    if (location == null || location.path.isEmpty) {
      return const DownloadResult.cancelled();
    }

    // 2) Join onto Base_URL and stream to the chosen path (Req 16.2, 16.3).
    final Uri uri = apiClient.resolveUri(engineUrl);
    try {
      await _downloader(
        uri,
        location.path,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
      return DownloadResult.saved(location.path);
    } on DioException catch (e) {
      // A user-initiated cancel is a clean abort, not a failure: the streamed
      // download deletes its partial file, so report it like a dialog cancel.
      if (e.type == DioExceptionType.cancel) {
        return const DownloadResult.cancelled();
      }
      throw _toDownloadException(e);
    } catch (e) {
      // Disk errors and anything else the downloader surfaces.
      throw DownloadException('Could not save the file: $e', cause: e);
    }
  }

  // ===========================================================================
  //  Defaults
  // ===========================================================================

  /// The real native Save-As dialog backed by `file_selector`.
  static Future<FileSaveLocation?> _defaultSaveLocation({
    required String suggestedName,
    required List<XTypeGroup> acceptedTypeGroups,
  }) {
    return fs.getSaveLocation(
      acceptedTypeGroups: acceptedTypeGroups,
      suggestedName: suggestedName,
    );
  }

  /// Builds a [FileDownloader] that streams over [dio]. `Dio.downloadUri` reads
  /// the response as a stream and writes each chunk to a `RandomAccessFile`, so
  /// the whole payload is never held in memory; `deleteOnError: true` removes
  /// the partial file on any failure or cancellation (Req 16.3, 16.4).
  static FileDownloader _streamWith(Dio dio) {
    return (
      Uri uri,
      String savePath, {
      CancelToken? cancelToken,
      ProgressCallback? onReceiveProgress,
    }) async {
      await dio.downloadUri(
        uri,
        savePath,
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
        deleteOnError: true,
      );
    };
  }

  // ===========================================================================
  //  Error transform
  // ===========================================================================

  /// Converts a download [DioException] into a readable [DownloadException].
  ///
  /// When the engine returned an error response, its `{"detail": ...}` body is
  /// surfaced verbatim with the HTTP status; otherwise a transport-level
  /// message (timeout, connection refused, ...) is used.
  DownloadException _toDownloadException(DioException e) {
    final Response<dynamic>? response = e.response;
    if (response != null) {
      final String? detail = _extractDetail(response.data);
      return DownloadException(
        detail ?? e.message ?? 'Download failed.',
        statusCode: response.statusCode,
        cause: e,
      );
    }
    return DownloadException(
      _transportMessage(e),
      cause: e,
    );
  }

  /// A friendly message for failures that never produced an HTTP response.
  String _transportMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The download timed out. Please try again.';
      case DioExceptionType.connectionError:
        return 'Could not reach the Qpic engine to download the file.';
      default:
        return e.message ?? 'Download failed.';
    }
  }

  /// Pulls the engine's `detail` string from an error body. Download responses
  /// can be a decoded `{"detail": ...}` Map, a raw JSON String, or raw bytes
  /// (depending on the error content type), so handle each shape.
  String? _extractDetail(dynamic data) {
    if (data == null) return null;
    if (data is Map) {
      final dynamic detail = data['detail'];
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
      final String trimmed = data.trim();
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
