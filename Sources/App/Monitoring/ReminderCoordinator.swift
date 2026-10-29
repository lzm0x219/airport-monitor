import Foundation
import UserNotifications
#if SWIFT_PACKAGE
import TrafficCore
#endif

enum ReminderAcceptance { case accepted, notFound, unknown }
enum ReminderDeliveryStatus: Equatable { case idle, sent, denied, retryScheduled, unconfirmed, storageFailure }

/// A durable intention, never a claim that the user saw a notification.
struct ReminderDelivery: Codable {
    enum Status: String, Codable { case pending, failed, unconfirmed }
    var id: String
    var sourceID: String
    var reasons: [ReminderReason]
    var attemptedAt: Date
    var retryAfter: Date?
    var status: Status
}

@MainActor
struct ReminderServices {
    var authorizationStatus: () async -> UNAuthorizationStatus = {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    var send: (String, String, [ReminderReason]) async throws -> Void = { id, airport, reasons in
        let content = UNMutableNotificationContent()
        content.title = airport + " · " + Self.title(for: reasons.first)
        content.body = reasons.map { Self.title(for: $0) }.joined(separator: "；")
        if reasons.contains(where: \.expiryUnverified) {
            content.body += "。到期日期按上次读数，尚未重新核实。"
        }
        content.sound = .default
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    var queryAcceptance: (String) async -> ReminderAcceptance = { id in
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == id }) { return .accepted }
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == id }) { return .accepted }
        // Absence is not proof of rejection: the user may have cleared it already.
        return .unknown
    }
    var now: () -> Date = Date.init

    private static func title(for reason: ReminderReason?) -> String {
        guard let reason else { return "机场提醒" }
        switch reason.kind {
        case .low: return "剩余流量偏低"
        case .exhausted: return "流量已用尽"
        case .forecast: return "预计流量不足以撑到重置"
        case .expirySoon: return "即将到期"
        case .expiryDay: return "24 小时内到期"
        case .expired: return "已到期"
        }
    }
}

/// Main-actor serialization prevents two entry points sharing a repository from
/// sending the same intention. Repository revision checks cover separate processes.
@MainActor
final class ReminderCoordinator {
    private static var active = Set<String>()
    private let repository: NativeRepository
    private let services: ReminderServices

    init(repository: NativeRepository, services: ReminderServices? = nil) {
        self.repository = repository; self.services = services ?? ReminderServices()
    }

    @discardableResult
    func evaluate(airportID: UUID, inputProvider: () -> ReminderInput?) async -> ReminderDeliveryStatus {
        guard let initial = repository.source(for: airportID) else { return .idle }
        let lock = repository.stateURL.standardizedFileURL.path + "/" + initial.id
        guard Self.active.insert(lock).inserted else {
            // Pausing or disabling reminders must invalidate confirmations even
            // while another evaluation is waiting on the notification service.
            // Waiting for that evaluation would miss a quick off/on transition.
            guard var source = repository.source(for: airportID), let supplied = inputProvider() else { return .idle }
            let input = effectiveInput(supplied, airportID: airportID, source: source)
            let startingState = initialState(for: source, at: input.now)
            let decision = ReminderPolicy.evaluate(input: input, preferences: preferences(for: source), state: startingState)
            if decision.state != startingState {
                source.reminderState = decision.state
                do { try repository.updateSource(source) } catch { return .storageFailure }
            }
            return .idle
        }
        defer { Self.active.remove(lock) }
        let sourceID = initial.id
        var hasUnconfirmed = !(initial.reminderUnconfirmedDeliveries ?? []).isEmpty

        // A crash can leave an intention accepted by the OS but not acknowledged
        // locally. Reconcile before evaluating new risk; absence stays conservative.
        if let pending = initial.reminderDelivery, pending.status != .failed {
            let acceptance = await services.queryAcceptance(pending.id)
            guard var current = repository.history(for: airportID).first(where: { $0.id == sourceID }),
                  current.reminderDelivery?.id == pending.id else { return .idle }
            switch acceptance {
            case .accepted:
                current.reminderState = ReminderPolicy.markAccepted(pending.reasons, at: pending.attemptedAt,
                                                                   state: current.reminderState ?? ReminderState())
                current.reminderDelivery = nil
            case .unknown, .notFound:
                var uncertain = pending; uncertain.status = .unconfirmed
                current.reminderUnconfirmedDeliveries = (current.reminderUnconfirmedDeliveries ?? []) + [uncertain]
                // Reserve only these reasons conservatively. This is not evidence
                // of OS acceptance; the separate audit list preserves that distinction.
                current.reminderState = ReminderPolicy.markAccepted(pending.reasons, at: pending.attemptedAt,
                    state: current.reminderState ?? ReminderState())
                current.reminderDelivery = nil
                hasUnconfirmed = true
            }
            do { try repository.updateReminderRecord(sourceID: sourceID, deliveryID: pending.id,
                state: current.reminderState, delivery: current.reminderDelivery,
                unconfirmedDeliveries: current.reminderUnconfirmedDeliveries) }
            catch { return .storageFailure }
        }

        guard var source = repository.source(for: airportID), source.id == sourceID,
              let suppliedInput = inputProvider() else { return .idle }
        let input = effectiveInput(suppliedInput, airportID: airportID, source: source)
        let startingState = initialState(for: source, at: input.now)
        let decision = ReminderPolicy.evaluate(input: input, preferences: preferences(for: source),
                                               state: startingState)
        // Retain failed-attempt cooldown even if a switch is temporarily disabled.
        if decision.state != startingState {
            source.reminderState = decision.state
            do { try repository.updateSource(source) } catch { return .storageFailure }
        }
        guard !decision.reasons.isEmpty else { return hasUnconfirmed ? .unconfirmed : .idle }
        if let retry = source.reminderDelivery?.retryAfter, input.now < retry { return .retryScheduled }

        let authorization = await services.authorizationStatus()
        guard authorization == .authorized || authorization == .provisional else { return .denied }
        // Permissions and settings can change while the system call is suspended.
        guard var latest = repository.source(for: airportID), latest.id == sourceID,
              let suppliedCurrentInput = inputProvider() else { return .idle }
        let currentInput = effectiveInput(suppliedCurrentInput, airportID: airportID, source: latest)
        let currentStartingState = initialState(for: latest, at: currentInput.now)
        let currentDecision = ReminderPolicy.evaluate(input: currentInput, preferences: preferences(for: latest),
                                                      state: currentStartingState)
        guard isEnabled(airportID, input: currentInput), !currentDecision.reasons.isEmpty else {
            if currentDecision.state != currentStartingState {
                latest.reminderState = currentDecision.state
                do { try repository.updateSource(latest) } catch { return .storageFailure }
            }
            return .idle
        }
        let intention = ReminderDelivery(id: "airport-reminder-" + UUID().uuidString,
                                         sourceID: sourceID, reasons: currentDecision.reasons,
                                         attemptedAt: services.now(), status: .pending)
        latest.reminderState = currentDecision.state
        latest.reminderDelivery = intention
        // No submission is permitted until its identity has been durably published.
        do { try repository.updateSource(latest) } catch { return .storageFailure }
        let name = repository.snapshot.catalog.profiles.first(where: { $0.id == airportID })?.name ?? "机场"
        do {
            try await services.send(intention.id, name, intention.reasons)
        } catch {
            guard var current = repository.history(for: airportID).first(where: { $0.id == sourceID }),
                  current.reminderDelivery?.id == intention.id else { return .idle }
            current.reminderDelivery?.status = .failed
            current.reminderDelivery?.retryAfter = services.now().addingTimeInterval(300)
            do { try repository.updateReminderRecord(sourceID: sourceID, deliveryID: intention.id,
                state: current.reminderState ?? ReminderState(), delivery: current.reminderDelivery) }
            catch { return .storageFailure }
            return .retryScheduled
        }
        // An accepted request must stay deduplicated even if paused during send.
        // A new source never inherits this acknowledgment from the previous source.
        guard var current = repository.history(for: airportID).first(where: { $0.id == sourceID }),
              current.reminderDelivery?.id == intention.id else { return .idle }
        current.reminderState = ReminderPolicy.markAccepted(intention.reasons, at: intention.attemptedAt,
                                                           state: current.reminderState ?? ReminderState())
        current.reminderDelivery = nil
        do { try repository.updateReminderRecord(sourceID: sourceID, deliveryID: intention.id,
            state: current.reminderState ?? ReminderState(), delivery: nil) }
        catch { return .storageFailure }
        return .sent
    }

    private func isEnabled(_ airportID: UUID, input: ReminderInput) -> Bool {
        guard let profile = repository.snapshot.catalog.profiles.first(where: { $0.id == airportID }) else { return false }
        return profile.enabled && !profile.archived && input.globalEnabled && input.airportEnabled && !input.paused && !input.archived
    }

    private func preferences(for source: SourceRecord) -> ReminderPreferences {
        source.reminderPreferences ?? ReminderPreferences(lowEnabled: true, forecastEnabled: source.notifyForecast,
            expiryEnabled: source.notifyExpiry, lowThreshold: source.threshold,
            thresholdMode: source.thresholdMode == .percent ? .percent : .legacyAbsoluteGB)
    }

    private func effectiveInput(_ supplied: ReminderInput, airportID: UUID, source: SourceRecord) -> ReminderInput {
        var input = supplied
        let profile = repository.snapshot.catalog.profiles.first(where: { $0.id == airportID })
        input.paused = input.paused || profile?.enabled != true
        input.archived = input.archived || profile?.archived != false
        input.airportEnabled = input.airportEnabled && source.airportRemindersEnabled != false
        return input
    }

    private func initialState(for source: SourceRecord, at date: Date) -> ReminderState {
        if let state = source.reminderState { return state }
        var state = ReminderState()
        if source.ledger.lowBalanceNotified || source.migratedNotificationAt != nil {
            state.lowNotified = true
            state.lowLastAcceptedAt = source.migratedNotificationAt ?? date
        }
        return state
    }
}
