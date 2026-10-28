import AppKit
import SwiftUI
import Combine

#if !STATUS_INTERACTION_TEST
@main
#endif
struct AirportMonitorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = ApplicationController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private var workspace: AirportWorkspace!
    private let workspaceToolbarState = WorkspaceToolbarState()
    private var status: StatusController!
    private var settingsWindow: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--design-demo")
        if demo && CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if demo && CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--workspace-review") {
            do { workspace = try WorkspaceReviewSupport.make() }
            catch { print("Isolated workspace unavailable: \(error)"); NSApp.terminate(nil); return }
        } else { workspace = AirportWorkspace(demo: demo) }
        if !demo { NSApp.appearance = workspace.appearanceMode.native }
        if demo && CommandLine.arguments.contains("--status-error-preview") {
            workspace.menuModel?.configureDemo(error: "模拟同步错误：订阅服务器暂时不可达")
        }
        if demo, let index = CommandLine.arguments.firstIndex(of: "--menu-layout-snapshots"), CommandLine.arguments.indices.contains(index + 1) {
            do { try MenuLayoutSnapshots.export(workspace: workspace, to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print("Native menu snapshot failed: \(error)") }
            NSApp.terminate(nil)
            return
        }
        if demo, let index = CommandLine.arguments.firstIndex(of: "--settings-tab-snapshots"), CommandLine.arguments.indices.contains(index + 1) {
            do { try MenuLayoutSnapshots.exportSettings(workspace: workspace, to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print("Settings tab snapshots failed: \(error)") }
            NSApp.terminate(nil)
            return
        }
        status = StatusController(workspace: workspace, openMain: { [weak self] in self?.showMain() }, openSettings: { [weak self] in self?.showSettings() })
        makeMenu()
        if (demo || workspace.isIsolatedReview) && CommandLine.arguments.contains("--show-settings") {
            showSettings()
            return
        }
        if CommandLine.arguments.contains("--panel-preview") || CommandLine.arguments.contains("--show-panel") {
            // Keep a regular window available to native desktop review tools.
            if workspace.isIsolatedReview { showMain() }
            DispatchQueue.main.async { [weak self] in self?.status.showPopover() }
        }
        else if workspace.activeProfiles.isEmpty || demo || workspace.isIsolatedReview || CommandLine.arguments.contains("--show-main") { showMain() }
        if demo && CommandLine.arguments.contains("--navigation-benchmark"), let window = settingsWindow {
            NavigationBenchmark.run(workspace: workspace, window: window)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if status?.isPopoverVisible == true || settingsWindow?.isVisible == true { return true }
        showMain(); return true
    }
    @objc private func showSettings() {
        workspace.page = .settings; showMain()
    }
    @objc private func showMain() {
        status?.closePopover()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = workspace.isIsolatedReview ? "Airport Monitor · 隔离交互验证" : workspace.isDemo ? "Airport Monitor · 设计预览" : "Airport Monitor"
            window.contentMinSize = NSSize(width: 680, height: 548)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: WorkspaceView(workspace: workspace, toolbarState: workspaceToolbarState))
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            // A unified native toolbar centers the traffic lights in the same
            // 52pt header as the SwiftUI brand and settings action.
            let toolbar = NSToolbar(identifier: "WorkspaceToolbar")
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
            toolbar.delegate = self
            toolbar.centeredItemIdentifiers = [.init("WorkspaceNavigation")]
            window.toolbarStyle = .unified
            window.toolbar = toolbar
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor.windowBackgroundColor
            window.setContentSize(NSSize(width: 860, height: 680))
            if (workspace.isDemo || workspace.isIsolatedReview) && CommandLine.arguments.contains("--design-compact") {
                window.setContentSize(window.contentMinSize)
            }
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("WorkspaceBrand"), .flexibleSpace, .init("WorkspaceNavigation"), .flexibleSpace, .init("WorkspaceFeedback"), .init("WorkspaceActions")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = false
        switch identifier.rawValue {
        case "WorkspaceBrand": item.label = "Airport Monitor"; item.view = ToolbarHostingView(rootView: WorkspaceBrand())
        case "WorkspaceNavigation": item.label = "页面切换"; item.view = ToolbarHostingView(rootView: WorkspaceNavigationTabs(workspace: workspace))
        case "WorkspaceFeedback": item.label = "操作提示"; item.view = ToolbarHostingView(rootView: WorkspaceToolbarFeedback(state: workspaceToolbarState))
        case "WorkspaceActions": item.label = "添加机场与设置"; item.view = ToolbarHostingView(rootView: WorkspaceToolbarActions(workspace: workspace, state: workspaceToolbarState))
        default: return nil
        }
        if let view = item.view {
            let size = view.fittingSize
            view.frame = NSRect(origin: .zero, size: size)
            item.minSize = size; item.maxSize = size
        }
        return item
    }
    private func makeMenu() {
        let main = NSMenu(), item = NSMenuItem(), appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; appMenu.addItem(settings); appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Airport Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; main.addItem(item)
        let edit = NSMenuItem(), editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu; main.addItem(edit)
        let windowItem = NSMenuItem(), windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; main.addItem(windowItem); NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

@MainActor
private enum MenuLayoutSnapshots {
    static func export(workspace: AirportWorkspace, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard workspace.isDemo, let model = workspace.menuModel else { return }
        let total: UInt64 = 214_750_000_000
        let states: [(String, UInt64?, Bool)] = [("normal", 55_550_000_000, false), ("warning50", total / 2, false), ("danger20", total * 4 / 5, false), ("failure", 55_550_000_000, true), ("unknown-total", 5_000_000_000, false), ("first-sync", nil, false)]
        var report: [[String: String]] = []
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for layout in MenuPanelLayout.allCases {
                workspace.setMenuPanelLayout(layout)
                for (name, used, failure) in states {
                    var ledger = Ledger()
                    if let used {
                        let upload = min(UInt64(3_200_000_000), used)
                        let info = try Subscription(upload: upload, download: used - upload, total: name == "unknown-total" ? 0 : total,
                                                    expiry: Date().addingTimeInterval(90 * 86400))
                        try ledger.append(info, at: Date().addingTimeInterval(failure ? -1200 : 0))
                    }
                    model.configureDemo(ledger: ledger, error: failure ? "网络连接超时" : nil)
                    var naturalHeight: CGFloat = 400
                    let root = QuotaPanel(workspace: workspace, openMain: {}, openSettings: {}, contentHeightChanged: { naturalHeight = $0 })
                    let file = "\(layout.rawValue)-\(name)-\(dark ? "dark" : "light").png"
                    let size = try capture(root, width: 320, height: 400, naturalHeight: { naturalHeight }, to: directory.appendingPathComponent(file))
                    report.append(["file": file, "width": String(Int(size.width)), "height": String(Int(size.height)), "layout": layout.rawValue])
                }
                workspace.page = .settings
                _ = try capture(SettingsView(workspace: workspace, state: .constant(SettingsPageState())).background(Magpie.background), width: 760, height: 660,
                                to: directory.appendingPathComponent("settings-\(layout.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        print("Native menu snapshots: \(report.count) panel states and 4 settings views")
    }

    static func exportSettings(workspace: AirportWorkspace, to directory: URL) throws {
        guard workspace.isDemo else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [[String: String]] = []
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for section in SettingsSection.allCases {
                let state = SettingsPageState(section: section, restoredSelection: true)
                let file = "settings-\(section.rawValue)-\(dark ? "dark" : "light").png"
                let size = try capture(SettingsView(workspace: workspace, state: .constant(state)).background(Magpie.background),
                                       width: 680, height: 474, to: directory.appendingPathComponent(file))
                report.append(["file": file, "width": String(Int(size.width)), "height": String(Int(size.height)), "section": section.rawValue])
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        print("Settings tab snapshots: \(report.count) sections and themes")
    }

    private static func capture<Content: View>(_ root: Content, width: CGFloat, height: CGFloat,
                                               naturalHeight: (() -> CGFloat)? = nil, to file: URL) throws -> NSSize {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        if let naturalHeight {
            window.setContentSize(NSSize(width: width, height: max(1, naturalHeight())))
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        }
        defer { window.orderOut(nil); window.close() }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
        return hosting.bounds.size
    }
}

private final class ToolbarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Public AppKit panel, with the system menu material and no popover arrow.
@MainActor
final class TrafficPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusController: NSObject, NSWindowDelegate {
    private let brandImage: NSImage? = OwlLogoGeometry.templateImage
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = TrafficPanel(contentRect: NSRect(x: 0, y: 0, width: PanelPlacement.width, height: PanelPlacement.height),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let workspace: AirportWorkspace
    private let openMain: () -> Void
    private let openSettings: () -> Void
    private var host: NSHostingController<QuotaPanel>?
    private var observations: Set<AnyCancellable> = []
    private var menuModelObservation: AnyCancellable?
    private var clock: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var desiredPanelHeight: CGFloat = PanelPlacement.height
    private var logoFeedback: StatusLogoFeedback?
    private var lastLogoFeedbackTime: CFTimeInterval = -.infinity
    private var panelOpenedAt: TimeInterval = 0
    var isPopoverVisible: Bool { panel.isVisible }
    init(workspace: AirportWorkspace, openMain: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.workspace = workspace; self.openMain = openMain; self.openSettings = openSettings; super.init()
        panel.isReleasedWhenClosed = false
        panel.title = "Airport Monitor · 菜单栏"
        panel.level = .popUpMenu
        panel.isOpaque = false; panel.backgroundColor = .clear
        // Dismiss on an explicit outside click or Escape. Activation changes
        // during a programmatic reopen must not immediately hide the panel.
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        if let button = item.button {
            button.target = self; button.action = #selector(clicked)
            // Keep native release tracking. Including mouse-down can dispatch
            // only the press action and swallow the release on a quick tap.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading; button.imageHugsTitle = true
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, !self.panel.isVisible,
               let button = self.item.button, event.window === button.window,
               button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
                // Observe the press without changing NSButton's action mask.
                self.startLogoFeedback(pressed: true)
            }
            if event.type == .leftMouseUp, self.logoFeedback?.isPressed == true {
                let inside = self.item.button.map { button in
                    event.window === button.window && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
                } ?? false
                if !inside || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self.logoFeedback?.cancel()
                } else {
                    // Do not depend on NSButton tracking delivering a second action.
                    self.logoFeedback?.endPress()
                }
            }
            guard self.panel.isVisible else { return event }
            if event.type == .keyDown, event.window === self.panel, event.keyCode == 53, !self.workspace.panelExplanationOpen { self.closePopover(); return nil }
            // A release can arrive after the button action has opened the panel,
            // particularly after a held trackpad press. Only a new press outside
            // the panel should dismiss it.
            if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
               event.window !== self.panel, event.window !== self.item.button?.window,
               !self.statusButtonContains(NSEvent.mouseLocation) {
                self.closePopover()
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let released = event.type == .leftMouseUp
            let eventTime = event.timestamp
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                if released {
                    if self.logoFeedback?.isPressed == true { self.logoFeedback?.cancel() }
                } else if self.panel.isVisible, eventTime > self.panelOpenedAt {
                    // The status item can belong to another process's event stream.
                    // Its action handles toggling; never treat that click as outside.
                    if self.statusButtonContains(location) { return }
                    self.closePopover()
                }
            }
        }
        // Main-window navigation must not rescan subscription history or redraw
        // the system status item. Observe only its actual inputs.
        workspace.$menuAirport.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.observeMenuModel(); self?.render() }
        }.store(in: &observations)
        workspace.$profiles.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.observeMenuModel(); self?.render() }
        }.store(in: &observations)
        observeMenuModel()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
        render()
    }
    private func observeMenuModel() {
        menuModelObservation = workspace.menuModel?.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.render() }
        }
    }
    private func statusButtonContains(_ screenPoint: NSPoint) -> Bool {
        guard let button = item.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(screenPoint)
    }
    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        clock?.invalidate()
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePopover()
            let menu = NSMenu()
            let refresh = NSMenuItem(title: "立即同步", action: #selector(refresh), keyEquivalent: "")
            refresh.target = self; refresh.isEnabled = workspace.menuModel.map { $0.hasURL && !$0.busy && !$0.storageBlocked && $0.enabled && !$0.isDemo } ?? false
            menu.autoenablesItems = false; menu.addItem(refresh)
            let settings = NSMenuItem(title: "设置…", action: #selector(settings), keyEquivalent: "")
            settings.target = self; menu.addItem(settings); menu.addItem(.separator())
            menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            item.menu = menu; item.button?.performClick(nil); item.menu = nil
        } else if panel.isVisible { closePopover() }
        else {
            showPopover()
            if logoFeedback?.isPressed == true {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { logoFeedback?.cancel() }
                else { logoFeedback?.endPress() }
            } else { startLogoFeedback(pressed: false) }
        }
    }
    @objc private func refresh() { Task { await workspace.menuModel?.refresh() } }
    @objc private func settings() { openSettings() }
    func closePopover() {
        logoFeedback?.cancel()
        workspace.panelExplanationOpen = false
        panel.orderOut(nil)
    }
    private func startLogoFeedback(pressed: Bool) {
        let trigger: NSEvent.EventType = pressed ? .leftMouseDown : .leftMouseUp
        guard NSApp.currentEvent?.type == trigger,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              logoFeedback == nil,
              CACurrentMediaTime() - lastLogoFeedbackTime >= 0.8,
              let button = item.button, button.image === brandImage else { return }
        guard let feedback = StatusLogoFeedback(button: button, onFinish: { [weak self] in
            self?.logoFeedback = nil
        }) else { return }
        lastLogoFeedbackTime = CACurrentMediaTime()
        logoFeedback = feedback
        if pressed { feedback.beginPress() }
        else { feedback.play() }
    }
    func showPopover() {
        guard let button = item.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: screen.visibleFrame, desiredHeight: desiredPanelHeight)
        let height = frame.height
        let width = frame.width
        if host == nil {
            host = NSHostingController(rootView: QuotaPanel(workspace: workspace, openMain: openMain, openSettings: openSettings, contentHeightChanged: { [weak self] height in
                Task { @MainActor in self?.resizePanel(to: height) }
            }))
        }
        guard let content = host?.view else { return }
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.layer?.isOpaque = false
        content.layer?.cornerRadius = 12; content.layer?.masksToBounds = true
        content.frame = bounds; content.autoresizingMask = [.width, .height]
        panel.contentView = makeBackground(content: content, bounds: bounds)
        panel.setFrame(frame, display: true)
        // Ignore an opening press delivered by the global monitor after the
        // button's release action has already displayed the panel.
        panelOpenedAt = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        resizePanel(to: desiredPanelHeight)
    }
    private func resizePanel(to height: CGFloat) {
        guard height.isFinite, height > 40 else { return }
        desiredPanelHeight = ceil(height)
        guard panel.isVisible, let button = item.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        var visibleFrame = screen.visibleFrame
        if workspace.isDemo && CommandLine.arguments.contains("--panel-short") {
            visibleFrame.origin.y = max(visibleFrame.minY, anchor.minY - 566)
            visibleFrame.size.height = max(1, screen.visibleFrame.maxY - visibleFrame.minY)
        }
        let frame = PanelPlacement.frame(anchor: anchor, visibleFrame: visibleFrame, desiredHeight: desiredPanelHeight)
        if abs(panel.frame.height - frame.height) > 0.5 { panel.setFrame(frame, display: true); panel.invalidateShadow() }
    }
    private func makeBackground(content: NSView, bounds: NSRect) -> NSView {
        let material = NSVisualEffectView(frame: bounds)
        material.material = .popover; material.blendingMode = .withinWindow; material.state = .active
        material.wantsLayer = true
        material.layer?.backgroundColor = NSColor.clear.cgColor
        material.layer?.isOpaque = false
        material.layer?.cornerRadius = 12; material.layer?.masksToBounds = true
        // Mask the native material as well as its content sublayers. AppKit also
        // uses this alpha mask to give the window a rounded shadow.
        let mask = NSImage(size: NSSize(width: 25, height: 25), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        mask.resizingMode = .stretch
        material.maskImage = mask
        material.addSubview(content)
        return material
    }
    private func render() {
        guard let button = item.button else { return }
        // A model/display change must immediately regain ownership of the icon.
        logoFeedback?.cancel()
        let model = workspace.menuModel
        let warning = model.map { BasicQuotaPresentation(model: $0).needsAttention } ?? false
        item.length = NSStatusItem.variableLength
        let image = warning
            ? OwlLogoGeometry.dizzyImage
            : (brandImage ?? NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "套餐流量"))
        image?.isTemplate = !warning
        button.image = (model?.menuDisplay == .balance && !warning) ? nil : image
        let title = model?.menuDisplay == .icon ? "" : model?.menuTitle ?? "—"
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
        ])
        if let space = title.lastIndex(of: " ") {
            let start = title.distance(from: title.startIndex, to: space)
            text.addAttribute(.font, value: NSFont.systemFont(ofSize: 10.5), range: NSRange(location: start, length: title.count - start))
        }
        button.attributedTitle = text
        button.setAccessibilityLabel("\(workspace.menuProfile?.name ?? "Airport Monitor") 套餐剩余 \(model?.menuTitle ?? "未知")\(warning ? "，请检查状态" : "")")
        if let model, let sample = model.latest {
            button.toolTip = "剩余 \(sample.subscription.remaining.map { model.trafficUnit.text($0) } ?? "不限量")\n已用 \(model.trafficUnit.text(sample.subscription.used))\n更新于 \(PanelFormat.date(sample.date, time: true))\(warning ? "\n请打开面板检查状态" : "")"
        } else { button.toolTip = model?.error ?? "点击添加机场" }
    }
}
