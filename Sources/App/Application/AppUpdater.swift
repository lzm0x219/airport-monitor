import AppKit
import Combine

#if UPDATE_TESTING && (!DEBUG || AIRPORT_RELEASE)
#error("UPDATE_TESTING is only permitted in Debug builds")
#endif

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var restartAvailable = false

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var installAndRelaunch: (() -> Void)?
    #endif

    func start() {
        #if canImport(Sparkle)
        guard controller == nil,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feed), Self.isAllowedFeed(feedURL),
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                DispatchQueue.main.async { self?.canCheck = change.newValue ?? false }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                DispatchQueue.main.async { self?.automaticallyChecks = change.newValue ?? false }
            }
        ]
        isConfigured = true
        controller.startUpdater()
        #if UPDATE_TESTING
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak updater] in
            updater?.checkForUpdatesInBackground()
        }
        #endif
        #endif
    }

    private static func isAllowedFeed(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        #if UPDATE_TESTING
        return url.scheme?.lowercased() == "http" && url.host == "127.0.0.1"
        #else
        return false
        #endif
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        #if canImport(Sparkle)
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = updater.automaticallyChecksForUpdates
        #endif
    }

    func checkNow() {
        #if canImport(Sparkle)
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
        #endif
    }

    func restartToInstall() {
        #if canImport(Sparkle)
        installAndRelaunch?()
        #endif
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock install: @escaping () -> Void) -> Bool {
        installAndRelaunch = install
        restartAvailable = true
        DispatchQueue.main.async { [weak self] in self?.showRestartPrompt() }
        return true
    }

    private func showRestartPrompt() {
        guard restartAvailable else { return }
        let alert = NSAlert()
        alert.messageText = "更新已下载"
        alert.informativeText = "重新启动 Airport Monitor 即可安装更新。请先保存正在编辑的内容。"
        alert.addButton(withTitle: "重新启动并更新")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { restartToInstall() }
    }
}
#endif
