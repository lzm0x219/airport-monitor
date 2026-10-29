import AppKit
import SwiftUI

@MainActor
final class ApplicationController: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private var workspace: AirportWorkspace!
    private let workspaceToolbarState = WorkspaceToolbarState()
    private var status: StatusController!
    private var settingsWindow: NSWindow?
    private var reopenAfterLaunch = false
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
        if reopenAfterLaunch { reopenAfterLaunch = false; requestReopen() }
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
        requestReopen(); return false
    }
    func requestReopen() {
        guard workspace != nil, status != nil else { reopenAfterLaunch = true; return }
        if status.isPopoverVisible { NSApp.activate(ignoringOtherApps: true); return }
        showMain()
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
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
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

private final class ToolbarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
