import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@MainActor final class WorkspaceLifecycleFixture {
    let original: NativeRepositoryFixture
    let fetches = ControlledFetches()
    var failCommit = false
    var workspace: AirportWorkspace!
    init() throws {
        original = try NativeRepositoryFixture()
        // Stable order: main, paused backup, running backup.
        original.catalog.profiles[1].archived = false
        let third = AirportProfile(id: UUID(), historyID: UUID().uuidString, credentialAccount: "legacy-c",
            name: "第三机场", plan: "保留套餐", enabled: true, archived: false)
        original.catalog.profiles.append(third)
        original.vault.credentials[third.credentialAccount] = "https://c.example/subscription"
        try original.original.write(to: original.root.appendingPathComponent("\(third.historyID).json"))
        original.defaults.set(try JSONEncoder().encode(original.catalog), forKey: "airportCatalog.v1")
        var services = original.vault.services
        services.fetch = { [fetches] in try await fetches.fetch($0) }
        services.requestNotificationAuthorization = { false }
        workspace = AirportWorkspace(defaults: original.defaults, historyDirectory: original.root,
            services: services, startAutomatically: false, checkpoint: { [weak self] point in
                if self?.failCommit == true && point == .beforePublish { throw TrafficError.storage }
            })
        #expect(!workspace.catalogBlocked)
    }
    func cleanup() {
        for profile in workspace.profiles { workspace.model(for: profile).stop() }
        fetches.finish(); original.cleanup()
    }
    var main: AirportProfile { workspace.profiles[0] }
    var model: MonitorModel { workspace.model(for: main) }
    var store: NativeRepository { workspace.repository! }
    func waitUntilIdle(_ model: MonitorModel) async throws {
        for _ in 0..<1000 {
            if !model.busy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Request did not finish"); throw TrafficError.storage
    }
}
