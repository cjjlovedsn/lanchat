import Cocoa

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}
let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/test/Applications")]
func offer(_ path: String, shown: Bool = false, debug: Bool = false) -> Bool {
    ApplicationInstallHint.shouldPresent(bundleURL: URL(fileURLWithPath: path),
                                          applicationDirectories: roots, alreadyShown: shown, isDebug: debug)
}
check(offer("/Users/test/Downloads/Example.app"), "A downloaded app offers installation")
check(offer("/Volumes/Example Installer/Example.app"), "An app running from a DMG offers installation")
check(offer("/private/var/folders/test/AppTranslocation/uuid/d/Example.app"), "Translocated apps offer installation")
check(!offer("/Applications/Example.app"), "System Applications is installed")
check(!offer("/Applications/Utilities/Example.app"), "Nested Applications folders are installed")
check(!offer("/Users/test/Applications/Example.app"), "User Applications is installed")
check(offer("/Applications Backup/Example.app"), "A similar path prefix is not Applications")
check(!offer("/Users/test/Downloads/Example.app", shown: true), "Continuing here suppresses future prompts")
check(!offer("/Users/test/Downloads/Example.app", debug: true), "Debug builds do not prompt")
check(!offer("/tmp/command-line-check"), "Unbundled checks do not prompt")
let _ = NSApplication.shared
let chinese = ApplicationInstallHint.makeAlert(displayName: "Example", useChinese: true)
check(chinese.buttons.count == 2, "Installation and continuation actions are available")
check(chinese.buttons[0].title == "打开安装位置", "The action accurately describes opening Finder")
check(chinese.buttons[1].title == "继续使用", "Users can keep running the current copy")
check(chinese.informativeText.contains("Example"), "The prompt identifies the current app")
let english = ApplicationInstallHint.makeAlert(displayName: "Example", useChinese: false)
check(english.buttons[0].title == "Open Installation Location", "English action is available")
check(english.informativeText.contains("Quit this app"), "Installation instructions explain quitting first")
if CommandLine.arguments.count > 1 {
    chinese.layout()
    let view = chinese.window.contentView!
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
print("Passed \(checks) installation hint checks")
