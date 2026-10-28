import Testing
import Foundation
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct NativeModelTests {
    private func model(left: Double, days: Int = 0, daily: Double = 0.2, total: Double = 100) throws -> MonitorModel {
        let defaults = UserDefaults(suiteName: "NativeModelTests.\(UUID().uuidString)")!
        var ledger = Ledger()
        let now = Date(), start = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(days) * 86400)
        let count = Int(now.timeIntervalSince(start) / 300)
        for i in 0...count {
            let at = start.addingTimeInterval(Double(i) * 300)
            let used = max(0, total - left - daily * now.timeIntervalSince(at) / 86400)
            try ledger.append(TrafficCore.Subscription(upload: 0, download: UInt64(used * 1e9), total: UInt64(total * 1e9)), at: at)
        }
        if ledger.samples.last!.date < now { try ledger.append(TrafficCore.Subscription(upload: 0, download: UInt64(max(0, total - left) * 1e9), total: UInt64(total * 1e9)), at: now) }
        return MonitorModel(profileID: UUID().uuidString, defaults: defaults, demoLedger: ledger)
    }

    @Test(arguments: [0, 1, 2])
    func lowBalanceCollectingKeepsBothMessages(days: Int) throws {
        let m = try model(left: 8, days: days), p = QuotaPresentation(model: m)
        #expect(p.risk == .warning)
        #expect(p.title == "余量偏低 · 预测数据不足")
        #expect(p.result.diagnostic == .insufficientHistory)
        #expect(p.detail.contains("需 72 小时、4 次、3 个日期"))
        #expect(p.help.contains("包括今天的有效读数"))
        #expect(p.value == nil)
    }

    @Test func enoughForecastRemainsWarningAtLowBalance() throws {
        let p = QuotaPresentation(model: try model(left: 8, days: 7))
        #expect(p.title == "余量偏低 · 预计可用至重置")
        #expect(p.risk == .warning); #expect(p.value != nil)
    }
    @Test func failureStopsCurrentForecastAndRetainsTimestampedHistoricalEstimate() throws {
        let m = try model(left: 8, days: 7, daily: 4)
        #expect(m.forecastResult.estimate?.runsOutBeforeBoundary == true)
        m.configureDemo(error: "网络不可达")
        let p = QuotaPresentation(model: m)
        #expect(p.risk == .warning); #expect(p.title == "同步失败 · 预测暂停")
        #expect(p.result.estimate == nil)
        #expect(m.historicalForecastResult?.estimate?.runsOutBeforeBoundary == true)
        #expect(m.historicalForecastResult?.generatedAt == m.latest?.date)
        #expect(p.help.contains("上次成功"))
    }
    @Test func exhaustedBalanceTakesPrecedenceOverInsufficientData() throws {
        let p = QuotaPresentation(model: try model(left: 0))
        #expect(p.risk == .danger); #expect(p.title == "可用流量已用尽")
    }
    @Test func unknownTotalDoesNotClaimUnlimited() throws {
        let p = QuotaPresentation(model: try model(left: 0, total: 0))
        #expect(p.title == "套餐总量未知"); #expect(p.risk == .normal); #expect(p.value == nil)
    }
    @Test func pausedAirportDoesNotPromiseForecast() throws {
        let m = try model(left: 50, days: 7); m.enabled = false
        #expect(QuotaPresentation(model: m).title == "同步已暂停")
        #expect(QuotaPresentation(model: m).value == nil)
    }
    @Test func demoCannotFetchWriteOrRequestNotification() async throws {
        let m = try model(left: 8)
        let profile = m.currentProfileID, samples = m.ledger.samples.count
        await m.refresh()
        #expect(await m.saveSubscription("https://example.invalid/secret") == false)
        m.removeSubscription(); await m.recoverHistory(); await m.updateNotificationStatus()
        #expect(m.currentProfileID == profile); #expect(m.ledger.samples.count == samples); #expect(!m.busy)
    }
    @Test func workspaceDemoSeparatesMenuAndBrowsingSelectionAndPreservesArchive() {
        let w = AirportWorkspace(demo: true), first = w.activeProfiles[0], other = w.activeProfiles[1]
        w.browsingAirport = other.id
        #expect(w.menuAirport == first.id)
        w.archive(first, archived: true)
        #expect(w.activeProfiles.count == 2); #expect(w.model(for: first).ledger.samples.count > 0)
        #expect(w.model(for: first).enabled && w.model(for: first).archived)
        #expect(w.profiles.first(where: { $0.id == first.id })?.enabled == true)
        #expect(w.menuAirport != first.id)
        w.archive(first, archived: false)
        #expect(w.activeProfiles.count == 3); #expect(w.model(for: first).enabled)
    }
    @Test func recentSummaryRowsCoverExactlySevenDates() throws {
        let m = try model(left: 50, days: 7)
        #expect(m.recentDays.count == 7)
        #expect(Calendar.current.isDateInToday(m.recentDays.last!.date))
        #expect(m.recentDays.first!.coverage > 0.8)
        #expect(m.recentDays.allSatisfy { $0.coverage >= 0 && $0.coverage <= 1 })
    }
    @Test func navigationStatisticsStayWithinInteractiveBudget() throws {
        let m = try model(left: 50, days: 8)
        let start = ContinuousClock.now
        // Match the repeated presentation and daily-table reads in navigation.
        for _ in 0..<8 {
            let p = QuotaPresentation(model: m)
            #expect(p.risk == .normal)
            #expect(!p.title.isEmpty)
            #expect(p.value != nil)
            #expect(m.recentDays.count == 7)
        }
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(400), "Navigation statistics blocked the main actor for \(elapsed)")
    }
    @Test func dailyCoverageRefreshesWhenSamplingIntervalChanges() throws {
        let m = try model(left: 50, days: 7)
        let original = try #require(m.recentDays.first)
        #expect(original.coverage > 0.8)
        m.intervalMinutes = 1
        let updated = try #require(m.recentDays.first)
        #expect(updated.coverage == 0)
        #expect(updated.summary.bytes == original.summary.bytes)
        m.intervalMinutes = 5
        #expect(m.recentDays.first?.coverage == original.coverage)
    }
    @Test func catalogRejectsDuplicatedIdentityAndInvalidHistoryPath() throws {
        let p = AirportProfile(id: UUID(), historyID: UUID().uuidString, credentialAccount: "airport-test", name: "机场", plan: "", enabled: true, archived: false)
        try AirportCatalog(profiles: [p], menuAirport: p.id).validate()
        #expect(throws: (any Error).self) { try AirportCatalog(profiles: [p, p], menuAirport: p.id).validate() }
        var invalid = p; invalid.historyID = "../../secret"
        #expect(throws: (any Error).self) { try AirportCatalog(profiles: [invalid], menuAirport: p.id).validate() }
    }
    @Test func syncLogRoundTripIncludesFailureAndRawAmounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SyncAttemptStore(url: directory.appendingPathComponent("history.sync"))
        let info = try TrafficCore.Subscription(upload: 12, download: 30, total: 100)
        let attempts = [SyncAttempt(date: Date(), subscription: nil, message: "网络错误"), SyncAttempt(date: Date(), subscription: info, message: nil)]
        try store.save(attempts)
        let loaded = try store.load()
        #expect(loaded.count == 2); #expect(!loaded[0].succeeded); #expect(loaded[0].message == "网络错误")
        #expect(loaded[1].subscription?.remaining == 58); #expect(loaded[1].succeeded)
        #expect((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int) == 0o600)
    }
    @Test func timeUsesTwentyFourHourClock() throws {
        let calendar = Calendar.current
        let date = try #require(calendar.date(bySettingHour: 20, minute: 17, second: 0, of: Date()))
        #expect(NativeFormat.time(date) == "20:17")
    }
    @Test func quotaPercentKeepsFractionAndCoverageUsesOneRoundingRule() {
        #expect(NativeFormat.percentage(0.063) == "6.3%")
        #expect(NativeFormat.percentage(0.684) == "68.4%")
        #expect(NativeFormat.percentage(0.89) == "89%")
        #expect(NativeFormat.percentage(0) == "0%")
        #expect(NativeFormat.percentage(.nan) == "—")
        #expect(NativeFormat.percentage(0.996, decimals: 0) == "100%")
    }
    @Test func compactForecastExplainsWhatItsDateAndAmountMean() throws {
        let early = QuotaPresentation(model: try model(left: 12.6, days: 7, daily: 4.1, total: 200))
        #expect(early.compactTitle.contains("用尽"))
        #expect(early.compactValueLabel?.contains("提前") == true)
        let sufficient = QuotaPresentation(model: try model(left: 80, days: 7))
        #expect(sufficient.compactValueLabel?.hasPrefix("重置时约剩 ") == true)
    }
    @Test func demoAppearanceDoesNotWritePreferences() {
        let suite = "AppearanceIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("light", forKey: "appearanceMode.v1")
        let workspace = AirportWorkspace(demo: true, defaults: defaults)
        workspace.setAppearance(.dark)
        #expect(workspace.appearanceMode == .dark)
        #expect(defaults.string(forKey: "appearanceMode.v1") == "light")
    }
    @Test func corruptCatalogIsPreservedAndBlocksReplacement() async {
        let suite = "BrokenCatalog.\(UUID().uuidString)", data = Data("invalid-json".utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set(data, forKey: "airportCatalog.v1")
        let workspace = AirportWorkspace(defaults: defaults, historyDirectory: directory, startAutomatically: false)
        #expect(workspace.catalogBlocked); #expect(workspace.profiles.isEmpty)
        #expect(await workspace.save(profile: nil, name: "机场", plan: "", subscription: "https://example.invalid", reset: ResetRule(), threshold: 10) == false)
        #expect(defaults.data(forKey: "airportCatalog.v1") == data)
    }
}
