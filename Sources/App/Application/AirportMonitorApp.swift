import AppKit

#if !STATUS_INTERACTION_TEST
@main
#endif
struct AirportMonitorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let controller = ApplicationController()
        let arguments = CommandLine.arguments
        let review = arguments.contains("--workspace-review")
        let demo = arguments.contains("--design-demo")
        let directory = review || demo
            ? FileManager.default.temporaryDirectory.appendingPathComponent(review ? "AirportMonitorReviewInstance" : "AirportMonitorDemoInstance")
            : NativeRepository.defaultRoot
        let instance: SingleInstanceCoordinator
        do {
            guard let owner = try SingleInstanceCoordinator.start(directory: directory, onReopen: { [weak controller] in
                controller?.requestReopen()
            }) else { return }
            instance = owner
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动 Airport Monitor"
            alert.informativeText = "无法检查是否已有应用正在运行。请检查应用数据目录的权限后重试。"
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime((controller, instance)) { app.run() }
    }
}
