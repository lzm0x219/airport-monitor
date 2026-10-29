import AppKit

/// Opt-in, synthetic-data-only measurement of the real SwiftUI navigation path.
/// Includes main-queue delivery, layout and display; excludes the settling pause.
@MainActor
enum NavigationBenchmark {
    private struct Sample: Encodable {
        let page: String
        let milliseconds: Double
        var headerHitTargets: [String]? = nil
        var windowHeaderHitTargets: [String]? = nil
        var headerGeometry: String? = nil
    }

    static func run(workspace: AirportWorkspace, window: NSWindow) {
        guard workspace.isDemo else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            var samples: [Sample] = []
            let routes: [WorkspacePage] = [.settings, .airports]
            let arguments = CommandLine.arguments
            let repeats = arguments.firstIndex(of: "--navigation-repetitions").flatMap { index in
                arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
            } ?? 3
            for _ in 0..<min(100, max(3, repeats)) {
                for page in routes {
                    let start = ContinuousClock.now
                    workspace.page = page
                    // Let SwiftUI receive objectWillChange and update its tree.
                    for _ in 0..<2 {
                        await withCheckedContinuation { continuation in
                            DispatchQueue.main.async { continuation.resume() }
                        }
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                    }
                    let elapsed = start.duration(to: .now).components
                    let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
                    var sample = Sample(page: page.rawValue, milliseconds: milliseconds)
                    if arguments.contains("--navigation-hit-testing"), let root = window.contentView {
                        let y = root.isFlipped ? root.bounds.minY + 26 : root.bounds.maxY - 26
                        sample.headerHitTargets = [-66.0, -10.0, 53.0].map { offset in
                            let point = root.convert(NSPoint(x: root.bounds.midX + offset, y: y), to: root.superview)
                            return root.hitTest(point).map { String(reflecting: type(of: $0)) } ?? "nil"
                        }
                        var top = root
                        while let parent = top.superview { top = parent }
                        sample.windowHeaderHitTargets = [-66.0, -10.0, 53.0].map { offset in
                            let point = top.convert(NSPoint(x: window.frame.width / 2 + offset, y: window.frame.height - 26), from: nil)
                            return top.hitTest(point).map { String(reflecting: type(of: $0)) } ?? "nil"
                        }
                        sample.headerGeometry = "root \(root.frame), bounds \(root.bounds), window \(window.frame), layout \(window.contentLayoutRect), flipped \(root.isFlipped)"
                    }
                    samples.append(sample)
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            if let data = try? JSONEncoder().encode(samples) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}
