import Testing
import Foundation
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct BasicQuotaTests {
    private func model(remaining: Double, total: Double = 100, days: Int = 0, daily: Double = 0, expired: Bool = false) throws -> MonitorModel {
        var ledger = Ledger()
        let now = Date()
        let start = Calendar.current.startOfDay(for: now).addingTimeInterval(-Double(days) * 86400)
        let count = Int(now.timeIntervalSince(start) / 300)
        for index in 0...count {
            let at = start.addingTimeInterval(Double(index) * 300)
            let used = max(0, total - remaining - daily * now.timeIntervalSince(at) / 86400)
            try ledger.append(Subscription(upload: 0, download: UInt64(used * 1e9), total: UInt64(total * 1e9),
                                           expiry: expired ? now.addingTimeInterval(-1) : nil), at: at)
        }
        if ledger.samples.last!.date < now {
            try ledger.append(Subscription(upload: 0, download: UInt64(max(0, total - remaining) * 1e9), total: UInt64(total * 1e9),
                                           expiry: expired ? now.addingTimeInterval(-1) : nil), at: now)
        }
        let name = "BasicQuotaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let model = MonitorModel(profileID: UUID().uuidString, defaults: defaults, demoLedger: ledger)
        defaults.removePersistentDomain(forName: name)
        return model
    }

    @Test func futureForecastCannotChangeBasicQuotaRisk() throws {
        let model = try model(remaining: 40, days: 7, daily: 8)
        #expect(model.forecastResult.estimate?.runsOutBeforeBoundary == true)
        let presentation = BasicQuotaPresentation(model: model)
        #expect(presentation.risk == .normal)
        #expect(presentation.status == nil)
        #expect(!presentation.needsAttention)
    }

    @Test func realQuotaAndExpiryStillRequireAttention() throws {
        let low = BasicQuotaPresentation(model: try model(remaining: 8))
        #expect(low.risk == .warning)
        #expect(low.status == "余量偏低")
        let empty = BasicQuotaPresentation(model: try model(remaining: 0))
        #expect(empty.risk == .danger)
        #expect(empty.status == "流量已用尽")
        let expired = BasicQuotaPresentation(model: try model(remaining: 50, expired: true))
        #expect(expired.risk == .danger)
        #expect(expired.status == "套餐已到期")
        #expect(low.needsAttention && empty.needsAttention && expired.needsAttention)
    }

    @Test func unknownQuotaAndSyncFailureKeepTheirMeaning() throws {
        let unknown = BasicQuotaPresentation(model: try model(remaining: 0, total: 0))
        #expect(unknown.risk == .normal)
        #expect(unknown.status == "总额未知，无法计算余量")
        #expect(unknown.needsAttention)
        let model = try model(remaining: 50)
        let reading = model.latest
        model.configureDemo(error: "网络不可达")
        #expect(BasicQuotaPresentation(model: model).needsAttention)
        #expect(model.latest?.subscription.remaining == reading?.subscription.remaining)
        model.enabled = false
        #expect(BasicQuotaPresentation(model: model).status == "同步已暂停")
    }

    @Test func minimalEditorRequiresNameAndNewSubscriptionButPreservesSavedOptions() {
        var draft = AirportEditorDraft()
        #expect(!draft.canSave(requiresSubscription: true))
        draft.name = "云海"
        #expect(!draft.canSave(requiresSubscription: true))
        #expect(draft.canSave(requiresSubscription: false))
        draft.subscription = "   "
        #expect(!draft.canSave(requiresSubscription: true))
        draft.subscription = "https://example.invalid/subscription"
        #expect(draft.canSave(requiresSubscription: true))
        draft.threshold = .infinity
        #expect(!draft.canSave(requiresSubscription: true))
    }

    @Test func resetEditsAreDirtyAndInvalidRulesCannotSave() {
        var draft = AirportEditorDraft(name: "云海")
        let original = draft
        draft.resetRule.kind = .monthly
        draft.resetRule.day = 31
        draft.resetRule.timeZoneID = "Asia/Shanghai"
        #expect(draft != original)
        #expect(draft.canSave(requiresSubscription: false))
        draft.resetRule.timeZoneID = "Invalid/Zone"
        #expect(!draft.canSave(requiresSubscription: false))
        draft.resetRule.timeZoneID = "UTC"
        draft.resetRule.day = 32
        #expect(!draft.canSave(requiresSubscription: false))
        draft = original
        #expect(draft == original)
        #expect(draft.canSave(requiresSubscription: false))
    }
}
