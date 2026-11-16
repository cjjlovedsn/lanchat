import Cocoa

/// A one-time drag-install hint. Finder handles installation and replacement.
enum ApplicationInstallHint {
    private static let preferenceKey = "applicationInstallHintShown.v1"

    static func shouldPresent(bundleURL: URL, applicationDirectories: [URL], alreadyShown: Bool,
                              isDebug: Bool) -> Bool {
        guard !isDebug, !alreadyShown, bundleURL.pathExtension.lowercased() == "app" else { return false }
        let components = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return !applicationDirectories.contains { directory in
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return components.count > root.count && Array(components.prefix(root.count)) == root
        }
    }

    static func makeAlert(displayName: String, useChinese: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = useChinese ? "建议移到“应用程序”" : "Move to Applications"
        alert.informativeText = useChinese
            ? "将 \(displayName) 拖到“应用程序”文件夹，再从那里打开，避免清理下载文件时误删应用。\n\n点击“打开安装位置”可在访达中查看应用和“应用程序”文件夹。请先退出当前应用，再拖入安装。"
            : "Drag \(displayName) into Applications, then open it from there so it stays installed when you clean up Downloads.\n\nOpen the installation location to reveal the app and Applications in Finder. Quit this app before dragging it into place."
        alert.addButton(withTitle: useChinese ? "打开安装位置" : "Open Installation Location")
        alert.addButton(withTitle: useChinese ? "继续使用" : "Continue Here")
        return alert
    }

    static func presentIfNeeded(displayName: String) {
        #if DEBUG
        return
        #else
        let bundleURL = Bundle.main.bundleURL
        let directories = FileManager.default.urls(for: .applicationDirectory,
                                                   in: [.userDomainMask, .localDomainMask, .systemDomainMask, .networkDomainMask])
        let defaults = UserDefaults.standard
        guard shouldPresent(bundleURL: bundleURL, applicationDirectories: directories,
                            alreadyShown: defaults.bool(forKey: preferenceKey), isDebug: false) else { return }
        let alert = makeAlert(displayName: displayName,
                              useChinese: Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        defaults.set(true, forKey: preferenceKey)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            if let applications = directories.first(where: { $0.path == "/Applications" }) ?? directories.first {
                NSWorkspace.shared.open(applications)
            }
        }
        #endif
    }
}
