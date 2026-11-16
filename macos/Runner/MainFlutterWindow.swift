import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var updaterChannel: FlutterMethodChannel?
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

    let updater = FlutterMethodChannel(
      name: "lanchat/updater", binaryMessenger: flutterViewController.engine.binaryMessenger)
    updaterChannel = updater
    updater.setMethodCallHandler { call, result in
      guard call.method == "install", let args = call.arguments as? [String: String],
            let path = args["path"], let version = args["version"] else {
        result(FlutterMethodNotImplemented); return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try MacUpdateInstaller.prepare(dmg: URL(fileURLWithPath: path), version: version)
          DispatchQueue.main.async { result("launched") }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "install", message: error.localizedDescription, details: nil)) }
        }
      }
    }

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

/// Stage on the destination filesystem, verify the bundle, then let an external
/// helper replace it only after this process exits. No elevated shell or sudo.
enum MacUpdateInstaller {
  private static func fail(_ message: String) -> NSError {
    NSError(domain: "LanChat.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private static func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    if process.terminationStatus != 0 { throw fail("准备更新失败，请检查安装包和应用目录的权限") }
  }

  static func prepare(dmg: URL, version: String) throws {
    let manager = FileManager.default
    let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let parent = target.deletingLastPathComponent()
    guard target.pathExtension == "app", !target.path.hasPrefix("/Volumes/"),
          manager.isWritableFile(atPath: parent.path) else {
      throw fail("请先将 LanChat 安装到可写的应用程序目录，再重试更新")
    }
    // Reaching another update means the current version launched successfully.
    // Remove only our previous, same-identifier bundles to bound disk usage.
    if let files = try? manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
      for file in files where file.lastPathComponent.hasPrefix(".lanchat-previous-") && file.pathExtension == "app" {
        if Bundle(url: file)?.bundleIdentifier == Bundle.main.bundleIdentifier { try? manager.removeItem(at: file) }
      }
    }
    let id = UUID().uuidString
    let work = manager.temporaryDirectory.appendingPathComponent("lanchat-update-" + id)
    let mount = work.appendingPathComponent("volume")
    let staged = parent.appendingPathComponent(".lanchat-new-" + id + ".app")
    let backup = parent.appendingPathComponent(".lanchat-previous-" + id + ".app")
    try manager.createDirectory(at: mount, withIntermediateDirectories: true)
    var mounted = false
    var prepared = false
    defer {
      if mounted { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }
      if !prepared {
        try? manager.removeItem(at: staged)
        try? manager.removeItem(at: work)
      }
    }
    try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path])
    mounted = true
    let source = mount.appendingPathComponent("lanchat.app")
    guard let bundle = Bundle(url: source), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
          bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
      throw fail("更新包的应用标识或版本号不正确")
    }
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
    try run("/usr/bin/ditto", [source.path, staged.path])
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
    guard let frameworks = Bundle.main.privateFrameworksURL else { throw fail("找不到更新助手") }
    let helper = frameworks.appendingPathComponent("App.framework/Resources/flutter_assets/assets/install-macos-update.sh")
    let script = work.appendingPathComponent("install.sh")
    try manager.copyItem(at: helper, to: script)
    let log = work.appendingPathComponent("install.log")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, backup.path, log.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    prepared = true
  }
}
