import AppKit
import SwiftUI
import Combine

/// Public AppKit panel, with the system menu material and no popover arrow.
@MainActor
private final class TrafficPanel: NSPanel {
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
