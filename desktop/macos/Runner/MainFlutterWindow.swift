import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Register custom file picker channel that uses runModal() for CMD+A support.
    FilePickerChannel.register(with: flutterViewController.registrar(forPlugin: "FilePickerChannel"))

    super.awakeFromNib()
  }
}
