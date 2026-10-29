import Testing
import Foundation
import TrafficCore
@testable import NativeModels

/// Exercises real workspace persistence while every external service is fake.
@Suite @MainActor
struct MenuPanelIsolationTests {
    @MainActor final class Fixture {
        let original: NativeRepositoryFixture
        let fetches = ControlledFetches()
        var sends = 0
        var permissionRequests = 0
        var failCommit = false
        var workspace: AirportWorkspace!

        init() throws {
            original = try NativeRepositoryFixture()
            original.catalog.profiles[1].archived = false
            original.defaults.set(try JSONEncoder().encode(original.catalog), forKey: "airportCatalog.v1")
            original.defaults.set(false, forKey: "remindersEnabled")
            workspace = reopen()
        }
        func reopen() -> AirportWorkspace {
            var services = original.vault.services
            services.fetch = { [fetches] in try await fetches.fetch($0) }
            services.notificationAuthorizationStatus = { .authorized }
            services.requestNotificationAuthorization = { [weak self] in self?.permissionRequests += 1; return false }
            services.reminderServices = ReminderServices(authorizationStatus: { .authorized },
                send: { [weak self] _, _, _ in self?.sends += 1 }, queryAcceptance: { _ in .unknown })
            return AirportWorkspace(defaults: original.defaults, historyDirectory: original.root,
                services: services, startAutomatically: false, checkpoint: { [weak self] point in
                    if self?.failCommit == true && point == .beforePublish { throw TrafficError.storage }
                })
        }
        func stop(_ workspace: AirportWorkspace) {
            for profile in workspace.profiles { workspace.model(for: profile).stop() }
        }
        func cleanup() { stop(workspace); fetches.finish(); original.cleanup() }
    }

    @Test(arguments: ["overview", "magpie"], ["gb-iconAndBalance", "gb-balance", "gb-icon", "gib-iconAndBalance", "gib-balance", "gib-icon"])
    func displayChoicesSurviveReopenWithoutRewritingHistory(layoutName: String, choice: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let parts = choice.split(separator: "-").map(String.init)
        let unit = try #require(TrafficUnit(rawValue: parts[0]))
        let display = try #require(MenuDisplay(rawValue: parts[1]))
        let layout = try #require(MenuPanelLayout(rawValue: layoutName))
        let stateURL = try #require(f.workspace.repository?.stateURL)
        let before = try Data(contentsOf: stateURL)
        f.workspace.panelExplanationOpen = true
        f.workspace.setMenuPanelLayout(layout)
        f.workspace.setDisplay(unit: unit, menu: display)
        #expect(!f.workspace.panelExplanationOpen)
        #expect(try Data(contentsOf: stateURL) == before)
        let reopened = f.reopen(); defer { f.stop(reopened) }
        #expect(reopened.menuPanelLayout == layout)
        #expect(reopened.menuAirport == f.original.catalog.menuAirport)
        for profile in reopened.profiles {
            #expect(reopened.model(for: profile).trafficUnit == unit)
            #expect(reopened.model(for: profile).menuDisplay == display)
            #expect(reopened.model(for: profile).ledger.samples.map(\.id) == f.workspace.model(for: profile).ledger.samples.map(\.id))
        }
        #expect(f.sends == 0 && f.permissionRequests == 0)
        try f.original.assertOriginals()
    }

    @Test func changingPrimaryDuringFetchNeverRedirectsTheLateReading() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = f.workspace.profiles[0], second = f.workspace.profiles[1]
        let firstModel = f.workspace.model(for: first), secondModel = f.workspace.model(for: second)
        let firstIDs = firstModel.ledger.samples.map(\.id), secondIDs = secondModel.ledger.samples.map(\.id)
        let request = Task { await firstModel.refresh() }
        try await f.fetches.waitFor(1)
        f.workspace.menuAirport = second.id
        f.workspace.browsingAirport = first.id
        #expect(f.workspace.menuModel === secondModel)
        try f.fetches.succeed(0, used: 500)
        await request.value
        #expect(f.workspace.menuAirport == second.id)
        #expect(f.workspace.menuModel === secondModel)
        #expect(secondModel.ledger.samples.map(\.id) == secondIDs)
        #expect(firstModel.ledger.samples.count == firstIDs.count + 1)
        #expect(Array(firstModel.ledger.samples.prefix(firstIDs.count)).map(\.id) == firstIDs)
        let acceptedFirstIDs = firstModel.ledger.samples.map(\.id)
        let otherRequest = Task { await secondModel.refresh() }
        try await f.fetches.waitFor(2)
        try f.fetches.succeed(1, used: 700)
        await otherRequest.value
        #expect(secondModel.ledger.samples.count == secondIDs.count + 1)
        #expect(firstModel.ledger.samples.map(\.id) == acceptedFirstIDs)
        let reopened = f.reopen(); defer { f.stop(reopened) }
        #expect(reopened.menuAirport == second.id)
        #expect(reopened.menuModel?.currentProfileID == second.historyID)
        #expect(f.sends == 0 && f.permissionRequests == 0)
        try f.original.assertOriginals()
    }

    @Test func failedPrimarySaveRetainsPrimaryAndDoesNotRewriteDisplayPreferences() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = f.workspace.profiles[0], second = f.workspace.profiles[1]
        f.workspace.setDisplay(unit: .gb, menu: .balance)
        f.workspace.setMenuPanelLayout(.magpie)
        let stateURL = try #require(f.workspace.repository?.stateURL)
        let before = try Data(contentsOf: stateURL)
        f.failCommit = true
        f.workspace.menuAirport = second.id
        #expect(f.workspace.menuAirport == first.id)
        #expect(f.workspace.menuModel === f.workspace.model(for: first))
        #expect(f.workspace.message != nil)
        #expect(try Data(contentsOf: stateURL) == before)
        let reopened = f.reopen(); defer { f.stop(reopened) }
        #expect(reopened.menuAirport == first.id)
        #expect(reopened.menuPanelLayout == .magpie)
        #expect(reopened.menuModel?.trafficUnit == .gb)
        #expect(reopened.menuModel?.menuDisplay == .balance)
        #expect(f.sends == 0 && f.permissionRequests == 0)
        try f.original.assertOriginals()
    }
}
