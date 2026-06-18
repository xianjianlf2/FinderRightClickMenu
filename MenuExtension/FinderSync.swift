import Cocoa
import FinderSync

/// 沙箱内的 Finder Sync 扩展：只负责构建菜单、拿到路径，
/// 需要权限的动作（开终端 / 导航 / 通知）通过 frcm:// URL 交给非沙箱的配套 App。
class MenuFinderSync: FIFinderSync {

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return menu
        }
        menu.addItem(NSMenuItem(title: "复制路径",
                                action: #selector(copyPath(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "上一层",
                                action: #selector(goToParent(_:)),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "在此打开终端",
                                action: #selector(openTerminal(_:)),
                                keyEquivalent: ""))
        return menu
    }

    // MARK: - 动作

    /// 复制选中项完整路径（多选每行一个），并请求配套 App 弹通知。
    @objc func copyPath(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        let text = urls.map { $0.path }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let body = urls.count == 1 ? urls[0].path : "已复制 \(urls.count) 个路径"
        callHelper(host: "notify", items: [
            URLQueryItem(name: "title", value: "已复制路径"),
            URLQueryItem(name: "body", value: body),
        ])
    }

    /// 让当前 Finder 窗口导航到上一层目录。
    @objc func goToParent(_ sender: AnyObject?) {
        guard let current = FIFinderSyncController.default().targetedURL() else { return }
        let parent = current.deletingLastPathComponent().path
        callHelper(host: "navigate", items: [URLQueryItem(name: "path", value: parent)])
    }

    /// 在当前路径打开终端。
    @objc func openTerminal(_ sender: AnyObject?) {
        callHelper(host: "terminal", items: [URLQueryItem(name: "path", value: directoryForTerminal().path)])
    }

    // MARK: - 与配套 App 通信

    private func callHelper(host: String, items: [URLQueryItem]) {
        var comps = URLComponents()
        comps.scheme = "frcm"
        comps.host = host
        comps.queryItems = items
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 辅助

    private func targetURLs() -> [URL] {
        if let selected = FIFinderSyncController.default().selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let target = FIFinderSyncController.default().targetedURL() {
            return [target]
        }
        return []
    }

    private func directoryForTerminal() -> URL {
        if let first = FIFinderSyncController.default().selectedItemURLs()?.first {
            return first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        }
        return FIFinderSyncController.default().targetedURL() ?? URL(fileURLWithPath: NSHomeDirectory())
    }
}
