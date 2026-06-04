import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:file_selector/file_selector.dart' show XFile, XTypeGroup;
import 'package:flutter/services.dart';

/// Native file-open dialogs for the Qpic desktop client (Requirement 17).
///
/// This service is a thin, transport-only wrapper over the `file_selector`
/// package. It presents the platform-native open dialog with the correct
/// type filters for each flow and returns the user's raw selection:
///
/// * Crop / Tools flows show a dialog filtered to PDF files (17.1).
/// * Rename Batch shows a dialog allowing image files **and** PDF files (17.2),
///   with multi-select support.
///
/// On macOS, the Rename Batch multi-select dialog uses a custom method channel
/// that opens the panel as a standalone modal (runModal) rather than a sheet
/// (beginSheetModal). This fixes the known macOS issue where CMD+A does not
/// work for select-all in sheet-modal panels.
///
/// Loading the returned [XFile]s into the active tool is the responsibility of
/// feature code wired up by later tasks (17.3); this service only resolves the
/// selection. On cancel it returns `null` (single pick) or an empty list
/// (multi pick) so callers can treat "no selection" uniformly. It contains no
/// engine logic and performs no file I/O of its own.
class FilePickerService {
  /// Creates a file-picker service.
  const FilePickerService();

  /// Method channel for the custom macOS file picker that uses runModal().
  static const MethodChannel _macChannel =
      MethodChannel('com.qpic.desktop/file_picker');

  /// Image extensions accepted by the Rename Batch open dialog.
  ///
  /// Mirrors the formats the engine accepts for rename input. JPEG is listed
  /// under both common extensions so the native dialog matches either spelling.
  static const List<String> imageExtensions = <String>[
    'png',
    'jpg',
    'jpeg',
    'webp',
    'bmp',
    'gif',
    'tif',
    'tiff',
  ];

  /// Type group restricting selection to PDF documents.
  static const XTypeGroup _pdfGroup = XTypeGroup(
    label: 'PDF',
    extensions: <String>['pdf'],
    // macOS uniform type identifier + Windows MIME for a richer native filter.
    uniformTypeIdentifiers: <String>['com.adobe.pdf'],
    mimeTypes: <String>['application/pdf'],
  );

  /// Type group accepting images for the Rename Batch flow.
  static const XTypeGroup _imageGroup = XTypeGroup(
    label: 'Images',
    extensions: imageExtensions,
    uniformTypeIdentifiers: <String>['public.image'],
    mimeTypes: <String>['image/*'],
  );

  /// Presents a native open dialog filtered to a single PDF file.
  ///
  /// Used by the crop and tools flows (17.1). Returns the selected [XFile], or
  /// `null` when the user cancels the dialog.
  Future<XFile?> pickPdf() {
    return fs.openFile(acceptedTypeGroups: const <XTypeGroup>[_pdfGroup]);
  }

  /// Presents a native open dialog filtered to multiple PDF files.
  Future<List<XFile>> pickPdfs() {
    return fs.openFiles(acceptedTypeGroups: const <XTypeGroup>[_pdfGroup]);
  }

  /// Presents a native open dialog allowing image files and PDF files,
  /// returning every file the user selects (17.2).
  ///
  /// Used by the Rename Batch flow, which accepts a batch of inputs. Returns an
  /// empty list when the user cancels.
  ///
  /// On macOS this uses a custom method channel that opens the panel via
  /// `runModal()` (standalone) instead of `beginSheetModal` (sheet attached to
  /// window). Sheet-modal panels on macOS have a known limitation where CMD+A
  /// does not trigger select-all. The standalone modal has no such limitation.
  Future<List<XFile>> pickImagesAndPdf() async {
    if (Platform.isMacOS) {
      return _pickImagesAndPdfMacOS();
    }
    return fs.openFiles(
      acceptedTypeGroups: const <XTypeGroup>[_imageGroup, _pdfGroup],
    );
  }

  /// macOS-specific picker using custom method channel with runModal().
  Future<List<XFile>> _pickImagesAndPdfMacOS() async {
    final String home = Platform.environment['HOME'] ?? '/tmp';
    final String initialDir = '$home/Desktop';

    final List<dynamic>? paths = await _macChannel.invokeMethod<List<dynamic>>(
      'pickImagesAndPdf',
      <String, dynamic>{'initialDirectory': initialDir},
    );

    if (paths == null || paths.isEmpty) return <XFile>[];
    return paths.cast<String>().map((String path) => XFile(path)).toList();
  }

  /// Presents a native open dialog allowing a single image or PDF file.
  ///
  /// A single-select convenience for Rename Batch callers that add one file at
  /// a time. Returns `null` when the user cancels.
  Future<XFile?> pickImageOrPdf() {
    return fs.openFile(
      acceptedTypeGroups: const <XTypeGroup>[_imageGroup, _pdfGroup],
    );
  }

  /// Presents a native folder picker dialog. Returns the selected directory
  /// path, or `null` when the user cancels.
  ///
  /// Used as a workaround for macOS's CMD+A limitation in file-open dialogs:
  /// the user picks the folder and the caller loads all matching files from it.
  Future<String?> pickFolder() {
    return fs.getDirectoryPath();
  }
}
