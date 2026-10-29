import Foundation
import Testing
import TrafficCore

@MainActor final class ControlledFetches {
    var requests: [CheckedContinuation<Subscription, any Error>] = []
    var resolved = Set<Int>()
    func fetch(_ url: URL) async throws -> Subscription {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func succeed(_ index: Int, used: UInt64 = 500) throws {
        guard resolved.insert(index).inserted else { return }
        requests[index].resume(returning: try Subscription(upload: 120, download: used, total: 10000))
    }
    func fail(_ index: Int) {
        guard resolved.insert(index).inserted else { return }
        requests[index].resume(throwing: TrafficError.network(-1009))
    }
    func finish() { for index in requests.indices where !resolved.contains(index) { fail(index) } }
    func waitFor(_ count: Int) async throws {
        for _ in 0..<1000 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected \(count) requests, observed \(requests.count)")
        throw TrafficError.storage
    }
}
