import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct SyncStatusPresentationTests {
    @Test func plannedWaitEligibilityFailureAndClockRemainDistinct() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open()
        let readAt = ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z")!
        var source = try #require(store.source(for: f.first.id))
        source.ledger = Ledger(); source.syncAttempts = []; source.needsVerification = false
        try source.ledger.append(Subscription(upload: 0, download: 1000, total: 10000, expiry: nil), at: readAt)
        try store.updateSource(source)
        var now = readAt.addingTimeInterval(36 * 3600)
        var services = f.vault.services; services.now = { now }
        let gate = SubscriptionRequestGate(storeURL: f.root.appendingPathComponent("test-request-gate.json"))
        services.nextSubscriptionRequest = { try gate.nextAllowedDate(for: $0, observedAttempt: $1, now: now) }
        services.fetch = { url in
            try gate.reserve(url, now: now)
            f.vault.fetches += 1
            throw TrafficError.network(-1009)
        }
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: services, startAutomatically: false)
        let model = workspace.model(for: f.first)
        #expect(WorkspacePresentation(model: model).status == "限频等待")
        #expect(WorkspacePresentation(model: model).statusDetail.contains("最早可刷新"))
        #expect(WorkspacePresentation(model: model).usesOldReading)
        await model.refresh()
        #expect(model.error == nil)
        #expect(f.vault.fetches == 0)
        #expect(WorkspacePresentation(model: model).status == "限频等待")
        now = readAt.addingTimeInterval(72 * 3600)
        #expect(WorkspacePresentation(model: model).status == "可刷新")
        await model.refresh()
        #expect(f.vault.fetches == 1)
        let error = try #require(model.error)
        #expect(WorkspacePresentation(model: model).status == "同步失败")
        #expect(WorkspacePresentation(model: model).statusDetail.contains(error))
        #expect(WorkspacePresentation(model: model).statusDetail.contains("最早可刷新"))
        await model.refresh()
        #expect(f.vault.fetches == 1)
        #expect(WorkspacePresentation(model: model).status == "同步失败")
        #expect(model.latest?.date == readAt)
        now = readAt.addingTimeInterval(-60)
        #expect(WorkspacePresentation(model: model).status == "同步失败")
    }
    @Test func futureReadIsNotNormalWait() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let store = try f.open()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var source = try #require(store.source(for: f.first.id))
        source.ledger = Ledger(); source.syncAttempts = []; source.needsVerification = false
        try source.ledger.append(Subscription(upload: 0, download: 1000, total: 10000, expiry: nil), at: now.addingTimeInterval(60))
        try store.updateSource(source)
        var services = f.vault.services; services.now = { now }
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: services, startAutomatically: false)
        let model = workspace.model(for: f.first)
        #expect(WorkspacePresentation(model: model).status == "读数时间异常")
    }
}
