import Foundation
import TrafficCore

/// Deliberately ignores cancellation: eligibility must protect data even with an uncooperative transport.
@MainActor final class UncooperativeTransport {
    var pending: [CheckedContinuation<TrafficCore.Subscription, Error>] = []
    func fetch(_ url: URL) async throws -> TrafficCore.Subscription {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func waitFor(_ count: Int) async throws {
        for _ in 0..<10000 {
            if pending.count >= count { return }
            await Task.yield()
        }
        throw TrafficError.network(-1001)
    }
    func succeed(_ index: Int, used: UInt64 = 700) throws {
        pending[index].resume(returning: try TrafficCore.Subscription(upload: 120, download: used, total: 10000))
    }
    func fail(_ index: Int) { pending[index].resume(throwing: TrafficError.network(-1009)) }
}
