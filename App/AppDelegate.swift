import Cocoa
import UserNotifications
import ServiceManagement
import ApplicationServices
import Carbon

/// 非沙箱配套 App：菜单栏常驻，接收扩展发来的 frcm:// URL 执行需要权限的动作，
/// 并提供设置页（授权 / 切换终端）。
@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 终端表
    struct Terminal {
        let bundleID: String
        let name: String
        /// 传给 /usr/bin/open 的参数
        let openArguments: (String) -> [String]
    }

    private let terminals: [Terminal] = [
        Terminal(bundleID: "com.cmuxterm.app", name: "cmux",
                 openArguments: { ["-na", "cmux", "--args", "--working-directory=\($0)"] }),
        Terminal(bundleID: "com.mitchellh.ghostty", name: "Ghostty",
                 openArguments: { ["-na", "Ghostty", "--args", "--working-directory=\($0)"] }),
        Terminal(bundleID: "com.github.wez.wezterm", name: "WezTerm",
                 openArguments: { ["-na", "WezTerm", "--args", "start", "--cwd", $0] }),
        Terminal(bundleID: "net.kovidgoyal.kitty", name: "kitty",
                 openArguments: { ["-na", "kitty", "--args", "--directory", $0] }),
        Terminal(bundleID: "io.alacritty", name: "Alacritty",
                 openArguments: { ["-na", "Alacritty", "--args", "--working-directory", $0] }),
        Terminal(bundleID: "com.googlecode.iterm2", name: "iTerm2",
                 openArguments: { ["-a", "iTerm", $0] }),
        Terminal(bundleID: "com.apple.Terminal", name: "终端 (Terminal)",
                 openArguments: { ["-a", "Terminal", $0] }),
    ]

    // MARK: - 状态
    private var statusItem: NSStatusItem!
    private var infoWindow: NSWindow?
    private weak var terminalPicker: NSPopUpButton?
    private let defaults = UserDefaults.standard
    private let kPreferred = "preferredTerminalBundleID"
    private let kOnboarded = "didOnboard"

    // MARK: - 权限
    /// 设置窗口里展示的三类隐私权限（与「拖图标授权」槽位一一对应）。
    private enum Perm: String, CaseIterable {
        case automation, accessibility, fulldisk

        var title: String {
            switch self {
            case .automation: return "自动化"
            case .accessibility: return "辅助功能"
            case .fulldisk: return "完全磁盘访问"
            }
        }
        var subtitle: String {
            switch self {
            case .automation: return "控制 Finder 等 App"
            case .accessibility: return "监听键盘与鼠标"
            case .fulldisk: return "读取受保护目录"
            }
        }
        var symbol: String {
            switch self {
            case .automation: return "gearshape.fill"
            case .accessibility: return "accessibility"
            case .fulldisk: return "externaldrive.fill"
            }
        }
        /// (R, G, B) 0–255 主题色。
        var tint: (CGFloat, CGFloat, CGFloat) {
            switch self {
            case .automation: return (255, 159, 10)
            case .accessibility: return (48, 209, 88)
            case .fulldisk: return (94, 160, 255)
            }
        }
    }

    // 设置窗口内需要随权限状态刷新的控件引用
    private var slotStatusByPerm: [Perm: NSTextField] = [:]
    private weak var footerStatusDot: NSView?
    private weak var footerStatusLabel: NSTextField?
    private weak var grantFinderButton: NSButton?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // 菜单栏 App，无 Dock 图标
        app.run()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        // 从「系统设置」授权回来后自动刷新窗口里的权限状态
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        if !defaults.bool(forKey: kOnboarded) {
            defaults.set(true, forKey: kOnboarded)
            try? SMAppService.mainApp.register() // 首次注册开机自启，让菜单栏图标常驻
            showInfoWindow(nil)
        }
    }

    @objc private func appDidBecomeActive() {
        if infoWindow?.isVisible == true { refreshPermissionUI() }
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "filemenu.and.cursorarrow", accessibilityDescription: "Finder 右键菜单") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "⌘"
        }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        let menu = NSMenu()
        let header = menu.addItem(withTitle: "Finder 右键菜单", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(.separator())

        // 终端子菜单
        let termItem = NSMenuItem(title: "终端", action: nil, keyEquivalent: "")
        termItem.submenu = buildTerminalMenu()
        menu.addItem(termItem)

        let info = NSMenuItem(title: "设置 / 关于…", action: #selector(showInfoWindow(_:)), keyEquivalent: ",")
        info.target = self
        menu.addItem(info)

        let launch = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(launch)

        let exts = NSMenuItem(title: "打开访达扩展设置…", action: #selector(openExtensionSettings(_:)), keyEquivalent: "")
        exts.target = self
        menu.addItem(exts)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildTerminalMenu() -> NSMenu {
        let termMenu = NSMenu()
        let pref = defaults.string(forKey: kPreferred) ?? ""

        let autoItem = NSMenuItem(title: "自动（\(autoTerminal()?.name ?? "终端")）",
                                  action: #selector(selectTerminal(_:)), keyEquivalent: "")
        autoItem.representedObject = ""
        autoItem.state = pref.isEmpty ? .on : .off
        autoItem.target = self
        termMenu.addItem(autoItem)
        termMenu.addItem(.separator())

        for t in terminals where isInstalled(t) {
            let it = NSMenuItem(title: t.name, action: #selector(selectTerminal(_:)), keyEquivalent: "")
            it.representedObject = t.bundleID
            it.state = (pref == t.bundleID) ? .on : .off
            it.target = self
            termMenu.addItem(it)
        }
        return termMenu
    }

    @objc private func selectTerminal(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? String ?? "", forKey: kPreferred)
        rebuildStatusMenu()
        if let p = terminalPicker { populateTerminalPicker(p) }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("FRCM login item error: \(error)")
        }
        rebuildStatusMenu()
    }

    @objc private func openExtensionSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    // MARK: - 设置 / 信息窗口

    @objc private func showInfoWindow(_ sender: Any?) {
        if infoWindow == nil { infoWindow = buildInfoWindow() }
        NSApp.activate(ignoringOtherApps: true)
        infoWindow?.center()
        infoWindow?.makeKeyAndOrderFront(nil)
        refreshPermissionUI()
    }

    private static let panelWidth: CGFloat = 600

    private func buildInfoWindow() -> NSWindow {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: AppDelegate.panelWidth, height: 680),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false)
        panel.title = "授权与设置"
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = true
        panel.level = .floating          // 浮在「系统设置」之上，方便把图标拖过去
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        // 深色渐变背景（对应设计稿的面板底色）
        let root = GradientBackgroundView(top: rgba(40, 42, 48), bottom: rgba(28, 30, 35))
        root.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(buildHeroSection())
        stack.addArrangedSubview(buildStep2Section())
        stack.addArrangedSubview(buildStep3Section())
        stack.addArrangedSubview(buildFooterSection())
        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: AppDelegate.panelWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        panel.contentView = root
        root.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: AppDelegate.panelWidth, height: root.fittingSize.height))
        return panel
    }

    // MARK: - 第 1 步：拖图标授权

    private func buildHeroSection() -> NSView {
        let hero = NSView()
        hero.wantsLayer = true
        hero.translatesAutoresizingMaskIntoConstraints = false

        // 标题列
        let eyebrow = eyebrowLabel("第 1 步")
        let title = headingLabel("拖动图标，一键授权", size: 20)
        let desc = bodyLabel("把右侧图标拖入下方任意权限槽，系统会自动把本应用加入对应的隐私白名单。",
                             maxWidth: 300)

        let textCol = NSStackView(views: [eyebrow, title, desc])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 5
        textCol.setCustomSpacing(7, after: eyebrow)
        textCol.translatesAutoresizingMaskIntoConstraints = false

        // 可拖拽 App 图标（带轻微悬浮动画）
        let iconView = DraggableAppIconView()
        iconView.wantsLayer = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)
        iconView.fileURL = Bundle.main.bundleURL
        iconView.toolTip = "拖到「系统设置」对应的隐私列表中以授权"
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 72).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let topRow = NSStackView(views: [textCol, iconView])
        topRow.orientation = .horizontal
        topRow.alignment = .top
        topRow.distribution = .fill
        topRow.spacing = 20
        topRow.translatesAutoresizingMaskIntoConstraints = false
        textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        // 三个权限槽
        let slots = NSStackView(views: Perm.allCases.map { buildSlot(for: $0) })
        slots.orientation = .horizontal
        slots.distribution = .fillEqually
        slots.spacing = 12
        slots.translatesAutoresizingMaskIntoConstraints = false

        let dashed = DashedLineView(color: rgba(94, 160, 255, 0.45))
        dashed.translatesAutoresizingMaskIntoConstraints = false
        dashed.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let col = NSStackView(views: [topRow, dashed, slots])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 16
        col.translatesAutoresizingMaskIntoConstraints = false

        hero.addSubview(col)
        NSLayoutConstraint.activate([
            topRow.widthAnchor.constraint(equalTo: col.widthAnchor),
            dashed.widthAnchor.constraint(equalTo: col.widthAnchor),
            slots.widthAnchor.constraint(equalTo: col.widthAnchor),
            col.topAnchor.constraint(equalTo: hero.topAnchor, constant: 14),
            col.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 28),
            col.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -28),
            col.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -24),
        ])
        return hero
    }

    private func buildSlot(for perm: Perm) -> NSView {
        let (r, g, b) = perm.tint
        let tint = rgba(r, g, b)
        let slot = SlotView(fill: rgba(r, g, b, 0.08), dash: rgba(r, g, b, 0.35))
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.onClick = { [weak self] in self?.openSettings(for: perm) }

        let chip = iconChip(symbol: perm.symbol, tint: tint, bg: rgba(r, g, b, 0.20), size: 24, radius: 7, pointSize: 12)
        let name = NSTextField(labelWithString: perm.title)
        name.font = .systemFont(ofSize: 12.5, weight: .semibold)
        name.textColor = .white

        let titleRow = NSStackView(views: [chip, name])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: perm.subtitle)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = rgba(142, 144, 152)
        sub.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: "未授权")
        status.font = .systemFont(ofSize: 9.5, weight: .semibold)
        status.textColor = rgba(142, 144, 152)
        status.translatesAutoresizingMaskIntoConstraints = false
        slotStatusByPerm[perm] = status

        slot.addSubview(titleRow)
        slot.addSubview(sub)
        slot.addSubview(status)
        NSLayoutConstraint.activate([
            slot.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
            titleRow.topAnchor.constraint(equalTo: slot.topAnchor, constant: 14),
            titleRow.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: 12),
            sub.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: 12),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: slot.trailingAnchor, constant: -12),
            sub.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 8),
            sub.bottomAnchor.constraint(lessThanOrEqualTo: slot.bottomAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: slot.topAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: -10),
        ])
        return slot
    }

    // MARK: - 第 2 步：允许控制 Finder

    private func buildStep2Section() -> NSView {
        let header = sectionHeader(step: "第 2 步", title: "允许控制 Finder",
                                   trailing: "可选 · 首次菜单点击时也会弹出")

        let grantBtn = primaryButton("授权", #selector(grantFinder(_:)))
        grantFinderButton = grantBtn
        let row1 = detailRow(chip: iconChip(symbol: "macwindow", tint: .white,
                                            bg: gradientChipColor(), size: 30, radius: 8, pointSize: 14),
                             title: "授权控制 Finder",
                             subtitle: "用于「上一层」等需要操作 Finder 的菜单项",
                             trailing: grantBtn)

        let row2 = detailRow(chip: iconChip(symbol: "bell.fill", tint: rgba(223, 225, 231),
                                            bg: rgba(255, 255, 255, 0.08), size: 30, radius: 8, pointSize: 13),
                             title: "允许通知",
                             subtitle: "操作完成、错误提示等系统通知",
                             trailing: secondaryButton("设置", #selector(grantNotifications(_:))))

        let card = makeCard(rows: [row1, row2])
        return wrapSection(header: header, card: card, topInset: 20, bottomInset: 8)
    }

    // MARK: - 第 3 步：个性化

    private func buildStep3Section() -> NSView {
        let header = sectionHeader(step: "第 3 步", title: "个性化", trailing: nil)

        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        populateTerminalPicker(picker)
        picker.target = self
        picker.action = #selector(pickerChanged(_:))
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.setContentHuggingPriority(.required, for: .horizontal)
        terminalPicker = picker

        let row1 = detailRow(chip: iconChip(symbol: "terminal.fill", tint: rgba(94, 160, 255),
                                            bg: rgba(94, 160, 255, 0.16), size: 30, radius: 8, pointSize: 13),
                             title: "默认终端",
                             subtitle: "「在此打开终端」使用的 App",
                             trailing: picker)

        let chevron = NSTextField(labelWithString: "›")
        chevron.font = .systemFont(ofSize: 15)
        chevron.textColor = rgba(108, 111, 119)
        let row2 = detailRow(chip: iconChip(symbol: "puzzlepiece.extension.fill", tint: rgba(199, 201, 209),
                                            bg: rgba(255, 255, 255, 0.06), size: 30, radius: 8, pointSize: 13),
                             title: "访达扩展设置",
                             subtitle: "在系统设置中开启 / 关闭右键菜单",
                             trailing: chevron,
                             onClick: { [weak self] in self?.openExtensionSettings(nil) })

        let card = makeCard(rows: [row1, row2])
        return wrapSection(header: header, card: card, topInset: 16, bottomInset: 16)
    }

    // MARK: - 底部状态栏

    private func buildFooterSection() -> NSView {
        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = rgba(0, 0, 0, 0.12).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        let topBorder = NSView()
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = rgba(255, 255, 255, 0.06).cgColor
        topBorder.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        footerStatusDot = dot

        let statusLabel = NSTextField(labelWithString: "0 / 3 项权限已授权")
        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = rgba(154, 157, 166)
        footerStatusLabel = statusLabel

        let left = NSStackView(views: [dot, statusLabel])
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false

        let help = NSButton(title: "查看帮助文档 ›", target: self, action: #selector(openExtensionSettings(_:)))
        help.isBordered = false
        help.contentTintColor = rgba(154, 157, 166)
        help.font = .systemFont(ofSize: 11.5, weight: .medium)
        help.translatesAutoresizingMaskIntoConstraints = false

        footer.addSubview(topBorder)
        footer.addSubview(left)
        footer.addSubview(help)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: footer.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 0.5),
            left.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 28),
            left.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -22),
            help.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footer.topAnchor.constraint(equalTo: left.topAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: left.bottomAnchor, constant: 14),
        ])
        return footer
    }

    // MARK: - 权限状态

    /// 重新检测三类权限并刷新槽位状态、底部计数、「授权控制 Finder」按钮。
    private func refreshPermissionUI() {
        guard !slotStatusByPerm.isEmpty else { return }
        var granted = 0
        for perm in Perm.allCases {
            let ok = isGranted(perm)
            if ok { granted += 1 }
            if let label = slotStatusByPerm[perm] {
                label.stringValue = ok ? "已授权" : "未授权"
                let (r, g, b) = perm.tint
                label.textColor = ok ? rgba(r, g, b) : rgba(142, 144, 152)
            }
        }
        footerStatusLabel?.stringValue = "\(granted) / \(Perm.allCases.count) 项权限已授权"
        let allDone = granted == Perm.allCases.count
        footerStatusDot?.layer?.backgroundColor = (allDone ? rgba(48, 209, 88) : rgba(255, 159, 10)).cgColor
        footerStatusDot?.layer?.shadowColor = (allDone ? rgba(48, 209, 88) : rgba(255, 159, 10)).cgColor
        footerStatusDot?.layer?.shadowOpacity = 0.6
        footerStatusDot?.layer?.shadowRadius = 4
        footerStatusDot?.layer?.shadowOffset = .zero
        if let btn = grantFinderButton {
            btn.title = isGranted(.automation) ? "已授权" : "授权"
            btn.isEnabled = !isGranted(.automation)
        }
    }

    private func isGranted(_ perm: Perm) -> Bool {
        switch perm {
        case .automation: return automationGranted()
        case .accessibility: return AXIsProcessTrusted()
        case .fulldisk: return fullDiskGranted()
        }
    }

    /// 不弹窗地查询「控制 Finder」的自动化授权状态。
    private func automationGranted() -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let aeDesc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(aeDesc, typeWildCard, typeWildCard, false)
        return status == noErr
    }

    /// 通过尝试读取受 TCC 保护的文件判断是否拥有完全磁盘访问。
    private func fullDiskGranted() -> Bool {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: path)
    }

    private func openSettings(for perm: Perm) {
        switch perm {
        case .automation: openAutomationSettings(nil)
        case .accessibility: openAccessibilitySettings(nil)
        case .fulldisk: openFullDiskSettings(nil)
        }
    }

    @objc private func openAutomationSettings(_ sender: Any?) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openFullDiskSettings(_ sender: Any?) {
        openSettingsURL("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    private func openSettingsURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    private func populateTerminalPicker(_ picker: NSPopUpButton) {
        picker.removeAllItems()
        picker.addItem(withTitle: "自动（\(autoTerminal()?.name ?? "终端")）")
        picker.lastItem?.representedObject = ""
        for t in terminals where isInstalled(t) {
            picker.addItem(withTitle: t.name)
            picker.lastItem?.representedObject = t.bundleID
        }
        let pref = defaults.string(forKey: kPreferred) ?? ""
        let idx = picker.itemArray.firstIndex { ($0.representedObject as? String ?? "") == pref } ?? 0
        picker.selectItem(at: idx)
    }

    @objc private func pickerChanged(_ sender: NSPopUpButton) {
        defaults.set(sender.selectedItem?.representedObject as? String ?? "", forKey: kPreferred)
        rebuildStatusMenu()
    }

    @objc private func grantFinder(_ sender: Any?) {
        // 跑一条无害的 Finder 脚本以触发「控制 Finder」授权弹窗
        runAppleScript("tell application \"Finder\" to count windows")
    }

    @objc private func grantNotifications(_ sender: Any?) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - UI 构件

    private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    private func eyebrowLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = rgba(94, 160, 255)
        return l
    }

    private func headingLabel(_ s: String, size: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: .semibold)
        l.textColor = .white
        return l
    }

    private func bodyLabel(_ s: String, maxWidth: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 12.5)
        l.textColor = rgba(154, 157, 166)
        l.isSelectable = false
        l.preferredMaxLayoutWidth = maxWidth
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        return l
    }

    /// 圆角图标芯片：底色 + 居中的 SF Symbol。
    private func iconChip(symbol: String, tint: NSColor, bg: NSColor,
                          size: CGFloat, radius: CGFloat, pointSize: CGFloat) -> NSView {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = radius
        chip.layer?.backgroundColor = bg.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: size).isActive = true
        chip.heightAnchor.constraint(equalToConstant: size).isActive = true

        let iv = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iv.contentTintColor = tint
        iv.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: chip.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
        ])
        return chip
    }

    private func gradientChipColor() -> NSColor { rgba(47, 142, 255) }

    private func eyebrowAndTitle(step: String, title: String) -> NSStackView {
        let s = NSStackView(views: [eyebrowLabel(step), headingLabel(title, size: 15)])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 4
        return s
    }

    private func sectionHeader(step: String, title: String, trailing: String?) -> NSView {
        let left = eyebrowAndTitle(step: step, title: title)
        left.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(left)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            left.topAnchor.constraint(equalTo: container.topAnchor),
            left.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if let trailing = trailing {
            let t = NSTextField(labelWithString: trailing)
            t.font = .systemFont(ofSize: 11)
            t.textColor = rgba(108, 111, 119)
            t.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(t)
            NSLayoutConstraint.activate([
                t.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                t.bottomAnchor.constraint(equalTo: left.bottomAnchor),
                t.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 8),
            ])
        }
        return container
    }

    /// 把「步骤标题 + 卡片」拼成一个带左右内边距的小节。
    private func wrapSection(header: NSView, card: NSView, topInset: CGFloat, bottomInset: CGFloat) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        section.addSubview(header)
        section.addSubview(card)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: section.topAnchor, constant: topInset),
            header.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -28),
            card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(equalTo: section.trailingAnchor, constant: -28),
            card.bottomAnchor.constraint(equalTo: section.bottomAnchor, constant: -bottomInset),
        ])
        return section
    }

    /// 半透明圆角卡片，内部纵向排列若干行并以细线分隔。
    private func makeCard(rows: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = rgba(255, 255, 255, 0.035).cgColor
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = rgba(255, 255, 255, 0.07).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = []
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = rgba(255, 255, 255, 0.07).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                views.append(sep)
            }
            views.append(row)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for v in views {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    /// 卡片内一行：图标芯片 + 标题/副标题 + 右侧控件，可选整行点击。
    private func detailRow(chip: NSView, title: String, subtitle: String,
                          trailing: NSView, onClick: (() -> Void)? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = rgba(223, 225, 231)
        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 11.5)
        subLabel.textColor = rgba(117, 120, 127)

        let textCol = NSStackView(views: [titleLabel, subLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.translatesAutoresizingMaskIntoConstraints = false

        let leftRow = NSStackView(views: [chip, textCol])
        leftRow.orientation = .horizontal
        leftRow.alignment = .centerY
        leftRow.spacing = 12
        leftRow.translatesAutoresizingMaskIntoConstraints = false

        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = RowView()
        row.onClick = onClick
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(leftRow)
        row.addSubview(trailing)
        NSLayoutConstraint.activate([
            leftRow.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            leftRow.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leftRow.trailingAnchor, constant: 14),
            row.topAnchor.constraint(equalTo: leftRow.topAnchor, constant: -13),
            row.bottomAnchor.constraint(equalTo: leftRow.bottomAnchor, constant: 13),
        ])
        return row
    }

    private func primaryButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.keyEquivalent = ""
        if #available(macOS 11.0, *) { b.bezelColor = rgba(47, 142, 255) }
        b.contentTintColor = .white
        return b
    }

    private func secondaryButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }


    // MARK: - URL 路由

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch url.host {
        case "terminal": if let p = value("path") { openTerminal(at: p) }
        case "navigate": if let p = value("path") { navigateFinder(to: p) }
        case "notify": notify(title: value("title") ?? "", body: value("body") ?? "")
        default: break
        }
    }

    // MARK: - 动作实现

    private func autoTerminal() -> Terminal? { terminals.first(where: isInstalled) }

    private func isInstalled(_ t: Terminal) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) != nil
    }

    private func chosenTerminal() -> Terminal {
        let pref = defaults.string(forKey: kPreferred) ?? ""
        if !pref.isEmpty, let t = terminals.first(where: { $0.bundleID == pref }), isInstalled(t) { return t }
        return autoTerminal() ?? terminals[terminals.count - 1]
    }

    private func openTerminal(at path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = chosenTerminal().openArguments(path)
        try? task.run()
    }

    private func navigateFinder(to path: String) {
        let p = escapeForAppleScript(path)
        runAppleScript("""
        tell application "Finder"
            activate
            if (count of Finder windows) > 0 then
                set target of front Finder window to (POSIX file "\(p)" as alias)
            else
                open (POSIX file "\(p)" as alias)
            end if
        end tell
        """)
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.postUserNotification(title: title, body: body)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { self.postUserNotification(title: title, body: body) }
                    else { self.postAppleScriptNotification(title: title, body: body) }
                }
            default:
                self.postAppleScriptNotification(title: title, body: body)
            }
        }
    }

    private func postUserNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func postAppleScriptNotification(title: String, body: String) {
        runAppleScript("display notification \"\(escapeForAppleScript(body))\" with title \"\(escapeForAppleScript(title))\"")
    }

    // MARK: - 工具

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error = error {
            NSLog("FRCM helper AppleScript error: \(error)")
        }
    }
}

/// 显示 App 图标、可被拖拽到「系统设置」隐私列表中以添加授权。
final class DraggableAppIconView: NSImageView, NSDraggingSource {
    var fileURL: URL?

    override func mouseDown(with event: NSEvent) {
        guard let url = fileURL else {
            super.mouseDown(with: event)
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// 自上而下的线性渐变背景视图（用作设置窗口面板底色）。
final class GradientBackgroundView: NSView {
    private let topColor: NSColor
    private let bottomColor: NSColor

    init(top: NSColor, bottom: NSColor) {
        self.topColor = top
        self.bottomColor = bottom
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAGradientLayer()
        layer.colors = [topColor.cgColor, bottomColor.cgColor]
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        return layer
    }
}

/// 虚线圆角描边的权限「槽位」，整块可点击。
final class SlotView: NSView {
    var onClick: (() -> Void)?
    private let fillColor: NSColor
    private let dashColor: NSColor

    init(fill: NSColor, dash: NSColor) {
        self.fillColor = fill
        self.dashColor = dash
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        fillColor.setFill()
        path.fill()
        dashColor.setStroke()
        path.lineWidth = 1.2
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 卡片内的一行，可选整行点击（用于「访达扩展设置」等）。
final class RowView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if onClick != nil { onClick?() } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// 一条水平虚线（设计稿里连接图标与权限槽的装饰线）。
final class DashedLineView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.midY
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: y))
        path.line(to: CGPoint(x: bounds.maxX, y: y))
        color.setStroke()
        path.lineWidth = 1.2
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
    }
}
