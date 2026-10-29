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
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func click() {
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
        for _ in 0..<20 {
            click()
            precondition(controller.isPopoverVisible, "Each click must open once.")
            click()
            precondition(!controller.isPopoverVisible, "Each second click must close once.")
        }
        print("PASS: 42 native quick clicks open and close exactly once, including zero-pressure taps.")
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
