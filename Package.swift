// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AirportMonitorCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TrafficCore", targets: ["TrafficCore"])],
    targets: [
        .target(name: "TrafficCore", path: "Sources/Core"),
        .target(name: "NativeModels", dependencies: ["TrafficCore"], path: "Sources/App",
                exclude: [
                    "Application/AirportMonitorApp.swift", "Application/ApplicationController.swift", "Application/AppUpdater.swift",
                    "MenuBar/StatusLogoFeedback.swift", "MenuBar/OwlLogoGeometry.swift", "MenuBar/OwlTouchResponse.swift",
                    "MenuBar/PanelPlacement.swift", "MenuBar/QuotaPanel.swift", "MenuBar/StatusController.swift",
                    "Presentation/NativeDesign.swift", "Presentation/WorkspaceControls.swift",
                    "Review/NavigationBenchmark.swift", "Review/WorkspaceReviewSupport.swift", "Review/WorkspaceScaleFixture.swift",
                    "Review/MenuLayoutSnapshots.swift",
                    "Settings/SettingsView.swift",
                    "Workspace/WorkspaceView.swift", "Workspace/AirportEditor.swift", "Workspace/AirportUsageCharts.swift",
                    "Workspace/InlineAirportConnection.swift", "Workspace/WorkspaceToolbar.swift", "Workspace/AirportCard.swift",
                    "Workspace/SourceHistoryView.swift", "Assets.xcassets"
                ],
                sources: [
                    "Application/SingleInstanceCoordinator.swift",
                    "Monitoring/MonitorModel.swift", "Monitoring/ReminderCoordinator.swift",
                    "Monitoring/SubscriptionPreview.swift", "Monitoring/SubscriptionReadLifecycle.swift",
                    "Presentation/QuotaPresentation.swift", "Presentation/WorkspacePresentation.swift",
                    "Storage/Keychain.swift", "Storage/NativeRepository.swift", "Storage/NativeSnapshot.swift", "Storage/LegacyMigration.swift",
                    "Workspace/AirportWorkspace.swift", "Workspace/AirportEditingSession.swift"
                ]),
        .testTarget(name: "CoreTests", dependencies: ["TrafficCore"], path: "Tests/CoreTests"),
        .testTarget(name: "NativeModelTests", dependencies: ["NativeModels", "TrafficCore"], path: "Tests/NativeModelTests",
                    resources: [.copy("Fixtures")])
    ]
)
