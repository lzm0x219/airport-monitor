import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct StatisticsIntegrationTests {
    @MainActor final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private var reference: Date { Date(timeIntervalSince1970: 1_792_497_600) } // 2026-10-20 12:00 UTC
    private func period(_ date: Date) -> DateInterval {
        DateInterval(start: date.addingTimeInterval(-8 * 86400), end: date.addingTimeInterval(86400))
    }
    private func rule() -> ResetRule {
        var result = ResetRule()
        result.kind = .monthly; result.day = 28; result.timeZoneID = "UTC"; result.anchor = reference
        return result
    }

    private func open(_ f: NativeRepositoryTests.Fixture, _ clock: Clock) throws -> NativeRepository {
        var services = f.vault.services
        services.now = { clock.date }
        return try NativeRepository(root: f.root, defaults: f.defaults, services: services)
    }

    private func seed(_ store: NativeRepository, _ id: UUID, at date: Date,
                      hours: [Int] = [-96, -72, -48, -24, 0]) throws {
        var source = try #require(store.source(for: id)), ledger = Ledger()
        for (index, hour) in hours.enumerated() {
            try ledger.append(Subscription(upload: 120, download: UInt64((index + 1) * 100), total: 10000,
                                           expiry: date.addingTimeInterval(30 * 86400)),
                              at: date.addingTimeInterval(Double(hour) * 3600))
        }
        source.ledger = ledger; source.syncAttempts = []; source.needsVerification = false
        source.resetRevisions = [ResetRevision(effectiveAt: nil, rule: rule())]
        try store.updateSource(source)
    }

    private func model(_ f: NativeRepositoryTests.Fixture, _ store: NativeRepository, _ clock: Clock,
                       fetch: ((URL) async throws -> TrafficCore.Subscription)? = nil) -> MonitorModel {
        var services = f.vault.services
        services.now = { clock.date }
        services.requestNotificationAuthorization = { false }
        if let fetch { services.fetch = fetch }
        return MonitorModel(profileID: f.first.historyID, credentialAccount: f.first.credentialAccount,
                            defaults: f.defaults, services: services, historyDirectory: f.root,
                            startAutomatically: false, repository: store, airportID: f.first.id)
    }

    @Test func migratedReportsRebuildWithoutWritingOrChangingIntervalIdentity() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock), m = model(f, store, clock)
        defer { m.stop() }
        let stateBytes = try Data(contentsOf: store.stateURL)
        let preferenceBytes = f.defaults.data(forKey: "airportCatalog.v1")
        let all = DateInterval(start: try #require(m.ledger.samples.first).date.addingTimeInterval(-86400),
                               end: try #require(m.latest).date.addingTimeInterval(86400))
        let first = m.statistics(in: all)
        let ids = m.statisticsIntervals.map(\.id)
        for _ in 0..<3 {
            #expect(m.statistics(in: all).summary.bytes == first.summary.bytes)
            #expect(m.statisticsIntervals.map(\.id) == ids)
        }
        let reopened = try open(f, clock), again = model(f, reopened, clock)
        defer { again.stop() }
        #expect(again.currentProfileID == m.currentProfileID)
        #expect(again.statisticsIntervals.map(\.id) == ids)
        #expect(again.statistics(in: all).summary.bytes == first.summary.bytes)
        #expect(try Data(contentsOf: store.stateURL) == stateBytes)
        #expect(f.defaults.data(forKey: "airportCatalog.v1") == preferenceBytes)
        try f.assertOriginals()
    }

    @Test func changedRuleRevisionsInvalidateCachedDailyObservations() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try store.setStatisticsTimeZone("UTC")
        try seed(store, f.first.id, at: clock.date, hours: [-3, -2, -1, 0])
        let m = model(f, store, clock); defer { m.stop() }
        let start = clock.date.addingTimeInterval(-86400)
        #expect(m.dailyRows(from: start, to: clock.date).last?.summary.bytes == 300)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 300)

        var source = try #require(store.source(for: f.first.id))
        source.resetRevisions.append(ResetRevision(effectiveAt: clock.date.addingTimeInterval(-5400), rule: rule()))
        try store.updateSource(source)

        #expect(m.dailyRows(from: start, to: clock.date).last?.summary.bytes == 200)
        #expect(m.statisticsIntervals.map(\.reason) == [.comparable, .ruleChanged, .comparable])
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 200)
    }

    @Test func sameSourceReplacementRetainsStatisticsButWaitsForVerification() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date)
        let m = model(f, store, clock); defer { m.stop() }
        let ids = m.statisticsIntervals.map(\.id), bytes = m.statistics(in: period(clock.date)).summary.bytes
        #expect(m.forecastResult.estimate != nil)
        _ = try store.saveAirport(profile: f.first, name: f.first.name, plan: f.first.plan,
                                  subscription: "https://same.example/new-token", reset: rule(), threshold: 7.5)
        m.applyStoredSource(try #require(store.source(for: f.first.id)))
        #expect(m.currentProfileID == f.first.historyID)
        #expect(m.statisticsIntervals.map(\.id) == ids)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == bytes)
        #expect(m.forecastResult.estimate == nil)
        #expect(m.historicalForecastResult?.generatedAt == clock.date)
        let again = model(f, try open(f, clock), clock); defer { again.stop() }
        #expect(again.forecastResult.estimate == nil)
        #expect(again.statisticsIntervals.map(\.id) == ids)
        try f.assertOriginals()
    }

    @Test func newSourceDoesNotBorrowOldStatisticsOrForecast() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date)
        let m = model(f, store, clock); defer { m.stop() }
        let originalIDs = m.ledger.samples.map(\.id)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 400)
        #expect(m.forecastResult.estimate != nil)
        _ = try store.saveAirport(profile: f.first, name: f.first.name, plan: f.first.plan,
                                  subscription: "https://other.example/new-source", reset: rule(), threshold: 7.5,
                                  change: .newSource)
        m.applyStoredSource(try #require(store.source(for: f.first.id)))
        #expect(m.currentProfileID != f.first.historyID)
        #expect(m.statistics(in: period(clock.date)).bytes == nil)
        #expect(m.statisticsIntervals.isEmpty)
        #expect(m.forecastResult.estimate == nil)
        #expect(m.historicalForecastResult == nil)
        let archived = try #require(store.history(for: f.first.id).first { $0.id == f.first.historyID })
        #expect(archived.ledger.samples.map(\.id) == originalIDs)
        let reopened = try open(f, clock), again = model(f, reopened, clock); defer { again.stop() }
        #expect(again.statisticsIntervals.isEmpty)
        #expect(reopened.history(for: f.first.id).count == 2)
        #expect(reopened.history(for: f.first.id).first { $0.id == f.first.historyID }?.ledger.samples.map(\.id) == originalIDs)
        try f.assertOriginals()
    }

    @Test func pausedBusyFailedAndStaleReadingsCannotProduceCurrentPrediction() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date)
        let transport = MonitorLifecycleTests.Transport()
        let m = model(f, store, clock, fetch: { try await transport.fetch($0) }); defer { m.stop() }
        #expect(m.forecastResult.estimate != nil)
        m.setLifecycle(enabled: false, archived: false)
        #expect(m.forecastResult.estimate == nil)
        m.setLifecycle(enabled: true, archived: false, refreshOnResume: false)
        clock.date.addTimeInterval(60)
        let pending = Task { await m.refresh() }; try await transport.waitFor(1)
        #expect(m.busy); #expect(m.forecastResult.estimate == nil)
        transport.fail(0); await pending.value
        #expect(m.error != nil); #expect(m.forecastResult.estimate == nil)
        #expect(m.historicalForecastResult?.generatedAt == reference)
        let retry = Task { await m.refresh() }; try await transport.waitFor(2)
        try transport.succeed(1, used: 600); await retry.value
        #expect(m.error == nil); #expect(m.forecastResult.estimate != nil)
        clock.date.addTimeInterval(46 * 60)
        #expect(m.forecastResult.estimate == nil)
        #expect(m.historicalForecastResult?.generatedAt == reference.addingTimeInterval(60))
        try f.assertOriginals()
    }

    @Test func pausedManualReadKeepsValidHistoryWithoutEnablingPrediction() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date)
        var catalog = store.snapshot.catalog; catalog.profiles[0].enabled = false
        try store.updateCatalog(catalog)
        let m = model(f, store, clock); defer { m.stop() }
        m.setLifecycle(enabled: false, archived: false)
        clock.date.addTimeInterval(60); f.vault.used = 600
        await m.refresh(purpose: .manual)
        #expect(!m.enabled); #expect(!m.syncPending)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 500)
        #expect(m.forecastResult.estimate == nil)
        #expect(m.historicalForecastResult?.estimate != nil)
        #expect(store.snapshot.catalog.profiles[0].enabled == false)
        try f.assertOriginals()
    }

    @Test func restoreFailureThenRetryRecordsCrossDayIncrementExactlyOnce() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date, hours: [-72, -48])
        var catalog = store.snapshot.catalog
        catalog.profiles[0].archived = true; catalog.menuAirport = nil
        try store.updateCatalog(catalog)
        catalog.profiles[0].archived = false; catalog.menuAirport = f.first.id
        try store.updateCatalog(catalog)
        let m = model(f, store, clock); defer { m.stop() }
        let before = m.statisticsIntervals.map(\.id)
        #expect(m.forecastResult.estimate == nil)
        f.vault.failFetch = true
        await m.refresh()
        #expect(m.statisticsIntervals.map(\.id) == before)
        #expect(m.syncPending); #expect(m.forecastResult.estimate == nil)
        f.vault.failFetch = false; f.vault.used = 500
        await m.refresh()
        let report = m.statistics(in: period(clock.date)), ids = m.statisticsIntervals.map(\.id)
        #expect(!m.syncPending)
        #expect(report.summary.bytes == 400)
        #expect(report.unallocated.count == 2)
        #expect(m.statisticsIntervals.count == before.count + 1)
        #expect(Set(ids).count == ids.count)
        #expect(m.forecastResult.estimate == nil) // A >24-hour gap starts a new prediction sequence.
        let reopened = model(f, try open(f, clock), clock); defer { reopened.stop() }
        #expect(reopened.statisticsIntervals.map(\.id) == ids)
        #expect(reopened.statistics(in: period(clock.date)).summary.bytes == 400)
        #expect(reopened.statistics(in: period(clock.date)).unallocated.map(\.id) == report.unallocated.map(\.id))
        #expect(store.source(for: f.first.id)?.gaps.count == 1)
        try f.assertOriginals()
    }

    @Test func restoreAcrossKnownResetPreservesReadingsWithoutInventingUsage() async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date, hours: [-72, -48])
        var source = try #require(store.source(for: f.first.id)), reset = ResetRule()
        reset.kind = .once; reset.anchor = clock.date.addingTimeInterval(-24 * 3600)
        source.resetRevisions = [ResetRevision(effectiveAt: nil, rule: reset)]
        try store.updateSource(source)
        var catalog = store.snapshot.catalog
        catalog.profiles[0].archived = true; catalog.menuAirport = nil; try store.updateCatalog(catalog)
        catalog.profiles[0].archived = false; catalog.menuAirport = f.first.id; try store.updateCatalog(catalog)
        let m = model(f, store, clock); defer { m.stop() }
        let retainedIDs = m.ledger.samples.map(\.id)
        f.vault.used = 500; await m.refresh()
        #expect(Array(m.ledger.samples.prefix(2)).map(\.id) == retainedIDs)
        #expect(m.statisticsIntervals.last?.reason == .knownReset)
        #expect(m.statisticsIntervals.last?.bytes == nil)
        let report = m.statistics(in: period(clock.date))
        #expect(report.summary.bytes == 100)
        #expect(report.excluded.count == 1)
        #expect(report.unallocated.count == 1)
        #expect(m.forecastResult.estimate == nil)
        try f.assertOriginals()
    }

    @Test func persistedStatisticsTimeZoneControlsDayAllocationAcrossRestart() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), initial = try open(f, clock)
        var snapshot = initial.snapshot
        snapshot.statisticsTimeZone = "America/New_York"
        try JSONEncoder().encode(snapshot).write(to: initial.stateURL, options: .atomic)
        let store = try open(f, clock)
        var source = try #require(store.source(for: f.first.id)), ledger = Ledger()
        // Across UTC midnight, but both points belong to October 19 in New York.
        let start = Date(timeIntervalSince1970: 1_792_447_200) // 2026-10-19 22:00 UTC
        try ledger.append(Subscription(upload: 0, download: 100, total: 1000), at: start)
        try ledger.append(Subscription(upload: 0, download: 350, total: 1000), at: start.addingTimeInterval(3 * 3600))
        source.ledger = ledger; source.resetRevisions = [ResetRevision(effectiveAt: nil, rule: ResetRule())]
        try store.updateSource(source)
        let m = model(f, store, clock); defer { m.stop() }
        #expect(m.calendar.timeZone.identifier == "America/New_York")
        let report = m.statistics(in: period(clock.date))
        #expect(report.unallocated.isEmpty)
        #expect(report.daily.filter { $0.bytes != nil }.count == 1)
        #expect(report.daily.first { $0.bytes != nil }?.bytes == 250)
        let reopened = model(f, try open(f, clock), clock); defer { reopened.stop() }
        #expect(reopened.calendar.timeZone.identifier == "America/New_York")
        #expect(reopened.statistics(in: period(clock.date)).daily.map(\.date) == report.daily.map(\.date))
        #expect(reopened.statistics(in: period(clock.date)).daily.map(\.bytes) == report.daily.map(\.bytes))
        #expect(reopened.statisticsIntervals.map(\.id) == m.statisticsIntervals.map(\.id))
        try f.assertOriginals()
    }

    @Test func laterResetRevisionDoesNotReinterpretEarlierUsage() throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date)
        let m = model(f, store, clock); defer { m.stop() }
        let earlier = Array(m.statisticsIntervals.prefix(2))
        var source = try #require(store.source(for: f.first.id)), changed = ResetRule()
        changed.kind = .once; changed.anchor = clock.date.addingTimeInterval(-80 * 3600)
        source.resetRevisions.append(ResetRevision(effectiveAt: clock.date.addingTimeInterval(-36 * 3600), rule: changed))
        try store.updateSource(source)
        m.applyStoredSource(try #require(store.source(for: f.first.id)))
        #expect(Array(m.statisticsIntervals.prefix(2)) == earlier)
        #expect(m.statisticsIntervals[2].reason == .ruleChanged)
        #expect(m.statisticsIntervals[2].bytes == nil)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 300)
        let reopened = model(f, try open(f, clock), clock); defer { reopened.stop() }
        #expect(reopened.statisticsIntervals == m.statisticsIntervals)
        try f.assertOriginals()
    }

    @Test(arguments: [false, true])
    func ruleEditAtLatestReadingKeepsCompletedHistoryAndWaitsForNewRead(savePreferences: Bool) async throws {
        let f = try NativeRepositoryTests.Fixture(); defer { f.cleanup() }
        let clock = Clock(reference), store = try open(f, clock)
        try seed(store, f.first.id, at: clock.date)
        let m = model(f, store, clock); defer { m.stop() }
        let completed = m.statisticsIntervals
        let oldEstimate = try #require(m.forecastResult.estimate)
        var changed = rule()
        changed.kind = .once; changed.anchor = clock.date.addingTimeInterval(30 * 60)
        if savePreferences {
            await m.savePreferences(interval: 15, reminders: false, threshold: 7.5, reset: changed)
        } else {
            _ = try store.saveAirport(profile: f.first, name: f.first.name, plan: f.first.plan,
                                      subscription: "", reset: changed, threshold: 7.5)
            m.applyStoredSource(try #require(store.source(for: f.first.id)))
        }
        #expect(m.statisticsIntervals == completed)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 400)
        #expect(m.forecastResult.estimate == nil)
        #expect(m.historicalForecastResult?.estimate?.dailyBytes == oldEstimate.dailyBytes)
        #expect(m.historicalForecastResult?.generatedAt == clock.date)
        #expect(store.source(for: f.first.id)?.needsVerification == true)
        let reopened = model(f, try open(f, clock), clock); defer { reopened.stop() }
        #expect(reopened.forecastResult.estimate == nil)
        #expect(reopened.statisticsIntervals == completed)
        #expect(reopened.historicalForecastResult?.estimate != nil)

        clock.date.addTimeInterval(3600); f.vault.used = 600
        await m.refresh()
        #expect(!m.syncPending)
        #expect(m.statisticsIntervals.count == completed.count + 1)
        #expect(Array(m.statisticsIntervals.dropLast()) == completed)
        // A new interval starting exactly at the edit uses the new schedule.
        #expect(m.statisticsIntervals.last?.reason == .knownReset)
        #expect(m.statisticsIntervals.last?.bytes == nil)
        #expect(m.statistics(in: period(clock.date)).summary.bytes == 400)
        try f.assertOriginals()
    }
}
