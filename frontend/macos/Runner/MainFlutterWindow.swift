import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Match AppTheme.canvas so pre-Flutter frames are never OS-white.
    self.backgroundColor = NSColor(srgbRed: 14 / 255, green: 14 / 255, blue: 18 / 255, alpha: 1)

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
