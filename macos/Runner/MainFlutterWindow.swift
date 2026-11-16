import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var clipboardChannel: FlutterMethodChannel?
  private var startupChannel: FlutterMethodChannel?
  private var startupItem: NSMenuItem?

  @objc private func toggleStartup(_ sender: NSMenuItem) {
    startupChannel?.invokeMethod("toggle", arguments: nil)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()

    let clipboard = FlutterMethodChannel(
      name: "lanchat/clipboard",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    clipboardChannel = clipboard
    clipboard.setMethodCallHandler { call, result in
      guard call.method == "files" else { result(FlutterMethodNotImplemented); return }
      let files = NSPasteboard.general.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      result(files.map { $0.path })
    }

    let channel = FlutterMethodChannel(
      name: "local.lanchat/startup_menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    startupChannel = channel
    if let menu = NSApp.mainMenu?.items.first?.submenu {
      let item = NSMenuItem(title: "开机启动", action: #selector(toggleStartup(_:)), keyEquivalent: "")
      item.target = self
      menu.insertItem(item, at: min(2, menu.items.count))
      startupItem = item
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "state", let state = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.startupItem?.state = (state["enabled"] as? Bool == true) ? .on : .off
      self?.startupItem?.isEnabled = state["busy"] as? Bool != true
      result(nil)
    }
  }
}
