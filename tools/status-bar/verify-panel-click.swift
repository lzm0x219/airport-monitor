import AppKit

// Compile all Sources with -D STATUS_INTERACTION_TEST and this entry point.
// Demo workspace isolates storage, credentials, notifications and network.
// swiftc -parse-as-library -D STATUS_INTERACTION_TEST \
//   $(find Sources -name '*.swift' -print) tools/status-bar/verify-panel-click.swift -o /tmp/verify-airport-panel
// /tmp/verify-airport-panel
@main struct VerifyPanelClick {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let workspace = AirportWorkspace(demo: true)
        let controller = StatusController(workspace: workspace, openMain: {}, openSettings: {})
        let item = Mirror(reflecting: controller).children.first { $0.label == "item" }!.value as! NSStatusItem
        let button = item.button!
        func click(top: Bool = false) {
            // AppKit can initially expose a visible status-item window with
            // zero height. Also recalculate the point after display changes.
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var readyLocation: NSPoint?
            while readyLocation == nil && ProcessInfo.processInfo.systemUptime < deadline {
                if let window = button.window, window.isVisible,
                   button.bounds.width > 0, button.bounds.height > 0 {
                    let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    let point = top ? NSPoint(x: center.x, y: window.frame.height - 0.5) : center
                    if NSRect(origin: .zero, size: window.frame.size).contains(point) {
                        readyLocation = point
                        break
                    }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard let location = readyLocation else {
                print("FAIL: status button window did not become ready for a click.")
                exit(1)
            }
            let timestamp = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: timestamp,
                                   windowNumber: button.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            }
            app.postEvent(event(.leftMouseUp), atStart: true)
            app.postEvent(event(.leftMouseDown), atStart: true)
            let down = app.nextEvent(matching: .leftMouseDown, until: .distantFuture, inMode: .default, dequeue: true)!
            // Use the real NSStatusBarButton tracking and its configured target/action.
            app.sendEvent(down)
        }
        click()
        guard controller.isPopoverVisible else {
            print("FAIL: quick zero-pressure click leaves the panel hidden.")
            exit(1)
        }
        click()
        guard !controller.isPopoverVisible else {
            print("FAIL: second click does not close the panel.")
            exit(1)
        }
        click()
        let window = button.window!
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // The pointer is clamped to precisely the screen's upper edge.
        let top = NSPoint(x: buttonFrame.midX, y: window.frame.maxY)
        precondition(!buttonFrame.contains(top), "The test requires a status-window area above the button.")
        controller.handleGlobalMouseDown(at: top, timestamp: ProcessInfo.processInfo.systemUptime + 1)
        click(top: true)
        guard !controller.isPopoverVisible else {
            print("FAIL: clicking the top of the status item reopens the panel.")
            exit(1)
        }
        click()
        controller.handleGlobalMouseDown(at: NSPoint(x: window.frame.minX - 10, y: window.frame.midY),
                                         timestamp: ProcessInfo.processInfo.systemUptime + 1)
        precondition(!controller.isPopoverVisible, "A new outside press must close the panel.")
        for _ in 0..<20 {
            click()
            precondition(controller.isPopoverVisible, "Each click must open once.")
            click()
            precondition(!controller.isPopoverVisible, "Each second click must close once.")
        }
        print("PASS: top-edge and 42 native quick clicks open and close once; outside press closes the panel.")
        let model = workspace.menuModel!
        model.configureDemo(error: "模拟网络不可达")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(button.image === OwlLogoGeometry.dizzyImage && !button.image!.isTemplate,
                     "An error must display the colored dizzy owl.")
        for display in [MenuDisplay.iconAndBalance, .icon, .balance] {
            model.menuDisplay = display
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            precondition(button.image === OwlLogoGeometry.dizzyImage, "All display modes must retain the error owl.")
        }
        click()
        precondition(controller.isPopoverVisible, "The colored owl must open the panel.")
        let feedback = Mirror(reflecting: controller).children.first { $0.label == "logoFeedback" }!.value
        precondition(Mirror(reflecting: feedback).children.isEmpty, "Dizzy eyes must not morph into the normal gaze.")
        controller.closePopover()
        print("PASS: error uses the colored owl in all three display modes; clicking opens the panel without normal-eye animation.")
    }
}
