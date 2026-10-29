import Foundation
import TrafficCore
import UserNotifications
@testable import NativeModels

@MainActor final class ReminderDeliveryFixture {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var sends = [String]()
    var sentReasons = [[ReminderReason.Kind]]()
    var fail = false
    var authorization = UNAuthorizationStatus.authorized
    var query = ReminderAcceptance.unknown
    var onAuthorization: (() async -> Void)?
    var onSend: (() async -> Void)?
    var services: ReminderServices {
        ReminderServices(authorizationStatus: {
            await self.onAuthorization?(); return self.authorization
        }, send: { id, _, reasons in
            self.sends.append(id); self.sentReasons.append(reasons.map(\.kind)); await self.onSend?()
            if self.fail { throw TrafficError.network(-1009) }
        }, queryAcceptance: { _ in self.query }, now: { self.date })
    }
    var input: ReminderInput {
        ReminderInput(now: date, sampleID: UUID(uuidString: "40000000-0000-0000-0000-000000000001"),
                      observedAt: date, remainingBytes: 5, totalBytes: 100, usageFresh: true, globalEnabled: true)
    }
}
