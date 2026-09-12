import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Match AppTheme.canvas (#0E0E12) so native frames are never OS-white.
    let canvas = NSColor(srgbRed: 14.0 / 255.0, green: 14.0 / 255.0, blue: 18.0 / 255.0, alpha: 1.0)
    self.backgroundColor = canvas
    self.isOpaque = true
    self.hasShadow = true

    let flutterViewController = FlutterViewController()
    // Flutter's view can flash clear/white before the first Dart frame.
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = canvas.cgColor

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.contentView?.wantsLayer = true
    self.contentView?.layer?.backgroundColor = canvas.cgColor
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
