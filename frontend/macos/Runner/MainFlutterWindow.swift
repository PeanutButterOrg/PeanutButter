import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var scaleObservers: [NSObjectProtocol] = []
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Match AppTheme.canvas (#0E0E12) so native frames are never OS-white.
    let canvas = NSColor(srgbRed: 14.0 / 255.0, green: 14.0 / 255.0, blue: 18.0 / 255.0, alpha: 1.0)
    self.backgroundColor = canvas
    self.isOpaque = true
    self.hasShadow = true

    let flutterViewController = FlutterViewController()
    // Don't force a layer onto the Flutter view before it is in a window: the
    // layer is then created at the main screen's scale and never corrected.
    flutterViewController.backgroundColor = canvas

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    windowChannel = FlutterMethodChannel(
      name: "peanutbutter/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()

    // macOS 27 leaves view layers at the main (Retina) display's contentsScale
    // when the window lives on a 1x display. Flutter then sizes its content
    // layer as physical/2 and the UI renders half-size in the corner.
    let center = NotificationCenter.default
    for name in [
      NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didChangeScreenNotification,
      NSWindow.didBecomeKeyNotification,
    ] {
      scaleObservers.append(
        center.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
          self?.syncLayerScale()
        })
    }
    // The player's fullscreen is a Flutter route; when the user leaves native
    // fullscreen (green button / Esc) the route must be popped too.
    scaleObservers.append(
      center.addObserver(
        forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main
      ) { [weak self] _ in
        self?.syncLayerScale()
        self?.windowChannel?.invokeMethod("didExitFullScreen", arguments: nil)
      })
    DispatchQueue.main.async { [weak self] in self?.syncLayerScale() }
  }

  deinit {
    scaleObservers.forEach(NotificationCenter.default.removeObserver)
  }

  private func syncLayerScale() {
    guard let root = contentView else { return }
    syncLayerScale(root, backingScaleFactor)
  }

  private func syncLayerScale(_ view: NSView, _ scale: CGFloat) {
    if let layer = view.layer, layer.contentsScale != scale {
      layer.contentsScale = scale
      // FlutterView re-sizes its surface/content layer from this callback.
      view.viewDidChangeBackingProperties()
    }
    view.subviews.forEach { syncLayerScale($0, scale) }
  }
}
