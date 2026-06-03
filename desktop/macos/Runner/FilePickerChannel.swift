import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// A custom method-channel handler that opens an NSOpenPanel as a standalone
/// modal (runModal) instead of a sheet (beginSheetModal). This ensures CMD+A
/// works correctly for multi-select — macOS sheets have a known limitation
/// where CMD+A does not select all files.
class FilePickerChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.qpic.desktop/file_picker",
      binaryMessenger: registrar.messenger
    )
    channel.setMethodCallHandler { (call, result) in
      if call.method == "pickImagesAndPdf" {
        pickImagesAndPdf(arguments: call.arguments as? [String: Any], result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func pickImagesAndPdf(arguments: [String: Any]?, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true

    // Set initial directory if provided.
    if let dir = arguments?["initialDirectory"] as? String {
      panel.directoryURL = URL(fileURLWithPath: dir)
    }

    // Configure allowed content types.
    if #available(macOS 11.0, *) {
      var allowedTypes: [UTType] = []
      // Images
      if let imageType = UTType("public.image") {
        allowedTypes.append(imageType)
      }
      // PDF
      if let pdfType = UTType("com.adobe.pdf") {
        allowedTypes.append(pdfType)
      }
      panel.allowedContentTypes = allowedTypes
    } else {
      panel.allowedFileTypes = [
        "png", "jpg", "jpeg", "webp", "bmp", "gif", "tif", "tiff", "pdf"
      ]
    }

    // Use runModal() (standalone) instead of beginSheetModal to fix CMD+A.
    let response = panel.runModal()
    if response == .OK {
      let paths = panel.urls.map { $0.path }
      result(paths)
    } else {
      // User cancelled — return empty list.
      result([String]())
    }
  }
}
