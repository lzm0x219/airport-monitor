// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirportMonitorCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TrafficCore", targets: ["TrafficCore"])],
    targets: [
        .target(name: "TrafficCore", path: "Sources/Core"),
        .target(name: "NativeModels", dependencies: ["TrafficCore"], path: "Sources/App",
                exclude: ["AirportMonitorApp.swift", "StatusLogoFeedback.swift", "OwlLogoGeometry.swift", "OwlTouchResponse.swift", "NavigationBenchmark.swift", "PanelPlacement.swift", "QuotaPanel.swift", "NativeDesign.swift", "WorkspaceView.swift", "AirportEditor.swift", "SettingsView.swift", "AirportUsageCharts.swift", "InlineAirportConnection.swift", "WorkspaceControls.swift", "WorkspaceReviewSupport.swift", "WorkspaceScaleFixture.swift", "Assets.xcassets"],
                sources: ["Keychain.swift", "MonitorModel.swift", "AirportWorkspace.swift", "NativeRepository.swift", "NativeSnapshot.swift", "LegacyMigration.swift", "ReminderCoordinator.swift", "SubscriptionPreview.swift", "SubscriptionReadLifecycle.swift", "QuotaPresentation.swift", "WorkspacePresentation.swift", "AirportEditingSession.swift", "SingleInstanceCoordinator.swift"]),
        .testTarget(name: "CoreTests", dependencies: ["TrafficCore"], path: "Tests/CoreTests"),
        .testTarget(name: "NativeModelTests", dependencies: ["NativeModels", "TrafficCore"], path: "Tests/NativeModelTests",
                    resources: [.copy("Fixtures")])
    ]
)
