import AppKit
import SwiftUI

@MainActor
enum MenuLayoutSnapshots {
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
