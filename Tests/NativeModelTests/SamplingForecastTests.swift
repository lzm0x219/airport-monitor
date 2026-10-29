import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct SamplingForecastModelTests {
    @Test func snapshotSurvivesClockFailureAndRestartButUpdatesOnNewReading() async throws {
        let f = try NativeRepositoryFixture(); defer { f.cleanup() }
        let store = try f.open()
        let start = ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z")!
        var rule = ResetRule(); rule.kind = .monthly; rule.day = 1; rule.timeZoneID = "UTC"
        var source = try #require(store.source(for: f.first.id))
        source.resetRevisions = [ResetRevision(effectiveAt: nil, rule: rule)]
        source.needsVerification = false; source.ledger = Ledger()
        for index in 0..<4 {
            try source.ledger.append(Subscription(upload: 0, download: UInt64(index) * 7_200_000_000, total: 200_000_000_000, expiry: nil),
                                     at: start.addingTimeInterval(Double(index) * 72 * 3600))
        }
        try store.updateSource(source)
        let latest = try #require(source.ledger.samples.last).date
        var now = latest.addingTimeInterval(36 * 3600)
        var services = f.vault.services; services.now = { now }
        services.fetch = { _ in
            f.vault.fetches += 1
            if f.vault.failFetch { throw TrafficError.network(-1009) }
            return try Subscription(upload: 0, download: 28_800_000_000, total: 200_000_000_000, expiry: nil)
        }
        let workspace = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: services, startAutomatically: false)
        let model = workspace.model(for: f.first)
        let original = model.samplingForecastResult
        #expect(original.estimate != nil)
        #expect(model.forecastResult.estimate == nil)
        #expect(model.stale)
        #expect(!model.samplingForecastIsHistorical)
        now = now.addingTimeInterval(4 * 86400)
        #expect(model.samplingForecastResult.generatedAt == latest)
        #expect(model.samplingForecastResult.estimate?.remainingAtBoundary == original.estimate?.remainingAtBoundary)
        f.vault.failFetch = true
        await model.refresh()
        #expect(model.error != nil)
        #expect(model.samplingForecastIsHistorical)
        #expect(model.samplingForecastResult.estimate?.remainingAtBoundary == original.estimate?.remainingAtBoundary)
        f.vault.failFetch = false
        await model.refresh()
        let updated = model.samplingForecastResult
        #expect(updated.estimate != nil)
        #expect(updated.generatedAt == now)
        #expect(updated.sampleCount == 5)
        #expect(updated.estimate?.remainingAtBoundary != original.estimate?.remainingAtBoundary)
        #expect(model.forecastResult.estimate == nil)
        let reopened = AirportWorkspace(defaults: f.defaults, historyDirectory: f.root, services: services, startAutomatically: false)
        let restored = reopened.model(for: f.first)
        #expect(restored.samplingForecastResult.generatedAt == updated.generatedAt)
        #expect(restored.samplingForecastResult.estimate?.remainingAtBoundary == updated.estimate?.remainingAtBoundary)
        now = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!
        #expect(restored.samplingForecastIsHistorical)
        #expect(restored.samplingForecastResult.estimate?.boundary == original.estimate?.boundary)
        #expect(f.vault.fetches == 2)
    }
}
