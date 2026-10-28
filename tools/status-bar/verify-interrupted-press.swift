import AppKit
import QuartzCore

// Reproduce a press whose mouse-up never reaches the status item's action.
@main
struct VerifyInterruptedPress {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        precondition(NSEvent.pressedMouseButtons & 1 == 0, "Run without holding the physical mouse button.")
        let items = (0..<3).map { _ in NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        let buttons = items.map { $0.button! }
        for button in buttons { button.image = OwlLogoGeometry.templateImage }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        var finishCounts = [0, 0, 0]
        var mouseDown = true
        let feedback = StatusLogoFeedback(button: buttons[0]) { finishCounts[0] += 1 }!
        feedback.beginPress()
        let held = StatusLogoFeedback(button: buttons[1], primaryButtonIsDown: { mouseDown }) { finishCounts[1] += 1 }!
        held.beginPress()
        let interrupted = StatusLogoFeedback(button: buttons[2]) { finishCounts[2] += 1 }!
        interrupted.play()
        // Pause the delegate-bearing animation: normal completion cannot fire.
        interrupted.layer!.sublayers![0].sublayers![1].speed = 0
        CATransaction.flush()
        // Exercise the native tracking run-loop mode, not just the default mode.
        func track(for seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { _ = RunLoop.current.run(mode: .eventTracking, before: end) }
        }
        track(for: 0.6)
        precondition(held.isPressed && finishCounts[1] == 0, "A genuine long press must remain held.")
        precondition(!feedback.isPressed, "A missing release must be detected while tracking.")
        mouseDown = false // Again, intentionally deliver no endPress() action.
        track(for: 3.3)
        let responses = [feedback, held, interrupted]
        let restored = finishCounts == [1, 1, 1] && zip(responses, buttons).allSatisfy { response, button in
            !response.isPressed && response.superview == nil && button.image === OwlLogoGeometry.templateImage
        }
        for response in responses { response.endPress(); response.cancel() }
        precondition(finishCounts == [1, 1, 1], "Recovery and late callbacks must finish once.")
        print(restored ? "PASS: lost release, real hold, tracking-mode recovery and stalled completion restore once."
              : "FAIL: interrupted interaction leaves the owl held or hidden.")
        for item in items { NSStatusBar.system.removeStatusItem(item) }
        exit(restored ? 0 : 1)
    }
}
