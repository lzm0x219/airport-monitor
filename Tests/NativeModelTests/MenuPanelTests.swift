import Testing
import Foundation
import TrafficCore
@testable import NativeModels

@Suite
struct MenuQuotaTests {
    @Test(arguments: [UInt64(2_000_000_000), UInt64(1_000_000_000_000)])
    func percentageBandsUseServerTotal(total: UInt64) throws {
        let cases: [(Double, QuotaRisk)] = [
            (0, .danger), (19.999, .danger), (20, .danger),
            (20.001, .warning), (49.999, .warning), (50, .warning),
            (50.001, .normal), (100, .normal)
        ]
        for (percentage, expected) in cases {
            let remaining = UInt64(Double(total) * percentage / 100)
            let info = try Subscription(upload: 0, download: total - remaining, total: total)
            let presentation = MenuQuotaPresentation(subscription: info)
            #expect(presentation.risk == expected)
            #expect(abs((presentation.remainingFraction ?? -1) - percentage / 100) < 0.000001)
        }
    }

    @Test func missingAndUnknownTotalsDoNotInventQuota() throws {
        for info in [nil, try Subscription(upload: 10, download: 20, total: 0)] {
            let presentation = MenuQuotaPresentation(subscription: info)
            #expect(presentation.risk == .normal)
            #expect(presentation.remainingFraction == nil)
        }
    }

    @Test func overdrawnBalanceClampsToZero() throws {
        let info = try Subscription(upload: 80, download: 30, total: 100)
        let presentation = MenuQuotaPresentation(subscription: info)
        #expect(presentation.risk == .danger)
        #expect(presentation.remainingFraction == 0)
    }
}

@Suite @MainActor
struct MenuLayoutPreferenceTests {
    @Test func previewLayoutChangesStayInMemoryAndCloseExplanation() {
        let name = "MenuLayoutPreferenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("magpie", forKey: "menuPanelLayout.v1")
        let workspace = AirportWorkspace(demo: true, defaults: defaults)
        workspace.panelExplanationOpen = true
        workspace.setMenuPanelLayout(.overview)
        #expect(workspace.menuPanelLayout == .overview)
        #expect(!workspace.panelExplanationOpen)
        #expect(defaults.string(forKey: "menuPanelLayout.v1") == "magpie")
        workspace.setMenuPanelLayout(.magpie)
        #expect(workspace.menuPanelLayout == .magpie)
    }
}

@Suite
struct ResetPresentationTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    @Test func missingScheduleDoesNotInventAReset() {
        let result = ResetPresentation(rule: ResetRule(), at: date("2026-10-20T00:00:00Z"))
        #expect(result.next == nil)
        #expect(result.value == "未设置")
    }

    @Test func monthlyResetUsesItsTimeZoneAndClampsShortMonths() {
        var rule = ResetRule()
        rule.kind = .monthly; rule.day = 31; rule.timeZoneID = "Asia/Shanghai"
        let result = ResetPresentation(rule: rule, at: date("2026-02-01T00:00:00Z"))
        #expect(result.next == date("2026-02-27T16:00:00Z"))
        #expect(result.value == "02-28 00:00")
        #expect(result.detail.contains("Asia/Shanghai"))
        let afterBoundary = ResetPresentation(rule: rule, at: date("2026-02-27T16:00:00Z"))
        #expect(afterBoundary.next == date("2026-03-30T16:00:00Z"))
    }

    @Test func billingResetUsesPurchaseDay() {
        var rule = ResetRule()
        rule.kind = .billing; rule.anchor = date("2026-01-14T16:00:00Z")
        rule.day = 1; rule.timeZoneID = "Asia/Shanghai"
        let result = ResetPresentation(rule: rule, at: date("2026-10-20T00:00:00Z"))
        #expect(result.value == "11-15 00:00")
    }

    @Test func elapsedOneOffIsNotReportedAsACompletedReset() {
        var rule = ResetRule()
        rule.kind = .once; rule.anchor = date("2026-10-18T00:00:00Z"); rule.timeZoneID = "UTC"
        let result = ResetPresentation(rule: rule, at: date("2026-10-20T00:00:00Z"))
        #expect(result.next == nil)
        #expect(result.value == "计划已过")
        #expect(result.detail.contains("未安排下次重置"))
        let upcoming = ResetPresentation(rule: rule, at: date("2026-10-17T00:00:00Z"))
        #expect(upcoming.value == "10-18 00:00")
    }

    @Test func invalidScheduleIsExplicit() {
        var rule = ResetRule(); rule.kind = .monthly; rule.timeZoneID = "not/a-zone"
        let result = ResetPresentation(rule: rule, at: date("2026-10-20T00:00:00Z"))
        #expect(result.next == nil)
        #expect(result.value == "规则无效")
    }

    @Test func localDisplayConvertsAcrossDateBoundaryWithoutChangingSchedule() {
        var rule = ResetRule()
        rule.kind = .monthly; rule.day = 1; rule.timeZoneID = "Asia/Tokyo"
        let result = ResetPresentation(rule: rule, at: date("2026-10-20T00:00:00Z"), displayTimeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(result.next == date("2026-10-31T15:00:00Z"))
        #expect(result.value == "10-31 08:00 · 本地")
        #expect(result.detail.contains("2026-11-01 00:00（规则时区 Asia/Tokyo）"))
        #expect(result.detail.contains("2026-10-31 08:00（America/Los_Angeles）"))
    }
}
