import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import TrafficCore
#endif

@MainActor
final class AirportEditingSession: ObservableObject, Identifiable {
    enum Field: String, Hashable { case name, subscription, reset, threshold, expiry, plan, save, settings }
    let id = UUID()
    let profile: AirportProfile?
    @Published var draft: AirportEditorDraft
    @Published var reminders: ReminderPreferences
    @Published var thresholdText: String
    @Published var expiryDaysText: String
    @Published var airportRemindersEnabled: Bool
    @Published var replacing = false
    @Published var change = SubscriptionChange.sameSource
    @Published var customTimeZone = false
    @Published var saving = false
    @Published var fieldErrors: [Field: String] = [:]
    @Published var saveError: String?
    var focusedField: Field? = .name
    var scrollOffset: CGFloat = 0
    weak var scrollView: NSScrollView?
    var pendingScrollRestore: CGFloat?
    var scrollSuspended = false
    private var scrollGeneration = UUID()
    var appeared = false
    init(workspace: AirportWorkspace, profile: AirportProfile?) {
        self.profile = profile
        let model = profile.map { workspace.model(for: $0) }
        let source = profile.flatMap { workspace.currentSource(for: $0) }
        draft = AirportEditorDraft(name: profile?.name ?? "", plan: profile?.plan ?? "",
            threshold: model?.thresholdGB ?? 10, resetRule: model?.resetRule ?? ResetRule())
        let preferences = source?.reminderPreferences ?? ReminderPreferences(lowEnabled: true,
            forecastEnabled: source?.notifyForecast ?? (profile == nil), expiryEnabled: source?.notifyExpiry ?? (profile == nil),
            lowThreshold: source?.threshold ?? 10, thresholdMode: source?.thresholdMode == .legacyAbsoluteGB ? .legacyAbsoluteGB : .percent)
        reminders = preferences
        thresholdText = String(preferences.lowThreshold)
        expiryDaysText = String(preferences.expiryLeadDays)
        airportRemindersEnabled = source?.airportRemindersEnabled ?? true
    }
    func validate(requiresSubscription: Bool) -> Field? {
        fieldErrors = [:]; saveError = nil
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fieldErrors[.name] = "请填写机场名称。" }
        if requiresSubscription || !draft.subscription.isEmpty {
            if (try? Subscription.validatedURL(draft.subscription)) == nil { fieldErrors[.subscription] = TrafficError.invalidURL.localizedDescription }
        }
        if (try? draft.resetRule.validate()) == nil { fieldErrors[.reset] = "请检查重置日期、时间和 IANA 时区。" }
        if airportRemindersEnabled && reminders.lowEnabled && thresholdValue(from: thresholdText) == nil {
            fieldErrors[.threshold] = reminders.thresholdMode == .percent ? "低余量阈值需为 1–50%。" : "旧版阈值需大于 0 且不超过 1,000,000 GB。"
        }
        if !reminders.lowThreshold.isFinite { fieldErrors[.threshold] = "提醒阈值必须是有限数值。" }
        if airportRemindersEnabled && reminders.expiryEnabled && expiryValue(from: expiryDaysText) == nil { fieldErrors[.expiry] = "首次提醒需提前 2–30 天。" }
        return [Field.name, .subscription, .reset, .threshold, .expiry].first { fieldErrors[$0] != nil }
    }
    // Incomplete text stays in the draft, but must not replace the last valid
    // numeric setting. Saving with reminders off preserves that usable value.
    func updateThresholdValue(from text: String) {
        guard let value = thresholdValue(from: text) else { return }
        reminders.lowThreshold = value
    }
    func updateExpiryValue(from text: String) {
        guard let value = expiryValue(from: text) else { return }
        reminders.expiryLeadDays = value
    }
    private func thresholdValue(from text: String) -> Double? {
        guard let value = Double(text), ReminderPreferences.isValidLowThreshold(value, mode: reminders.thresholdMode) else { return nil }
        return value
    }
    private func expiryValue(from text: String) -> Int? {
        guard let value = Int(text), ReminderPreferences.isValidExpiryLeadDays(value) else { return nil }
        return value
    }
    func cancelReplacement() {
        draft.subscription = ""; replacing = false; change = .sameSource; fieldErrors.removeValue(forKey: .subscription)
    }
    func suspendScrollForSettings() {
        scrollOffset = scrollView?.contentView.bounds.minY ?? scrollOffset
        pendingScrollRestore = scrollOffset
        scrollSuspended = true
        scrollGeneration = UUID()
    }
    func scheduleScrollRestoration() {
        guard let scroll = scrollView, pendingScrollRestore != nil else { return }
        let generation = UUID()
        scrollGeneration = generation
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.scrollGeneration == generation else { return }
            scroll.layoutSubtreeIfNeeded()
            // SwiftUI applies the measured sheet height after the first layout.
            // Keep the saved offset separate from transient native bounds changes.
            DispatchQueue.main.async { [weak self, weak scroll] in
                guard let self, let scroll, self.scrollView === scroll,
                      self.scrollGeneration == generation, let target = self.pendingScrollRestore,
                      scroll.window != nil else { return }
                scroll.layoutSubtreeIfNeeded()
                let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, target), maximum)))
                scroll.reflectScrolledClipView(scroll.contentView)
                self.scrollOffset = scroll.contentView.bounds.minY
                self.pendingScrollRestore = nil
                self.scrollSuspended = false
            }
        }
    }
}

/// Keep native scrolling through a visit to settings without reserving blank space.
struct EditorScrollMemory: NSViewRepresentable {
    let session: AirportEditingSession
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scroll = view.enclosingScrollView, context.coordinator.scroll !== scroll else { return }
            context.coordinator.connect(scroll, session: session)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        @MainActor func connect(_ scroll: NSScrollView, session: AirportEditingSession) {
            self.scroll = scroll
            session.scrollView = scroll
            if session.pendingScrollRestore == nil { session.pendingScrollRestore = session.scrollOffset }
            session.scrollSuspended = true
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll, weak session] _ in
                MainActor.assumeIsolated {
                    guard let session, let scroll, session.scrollView === scroll, !session.scrollSuspended else { return }
                    session.scrollOffset = scroll.contentView.bounds.minY
                }
            }
            session.scheduleScrollRestoration()
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
