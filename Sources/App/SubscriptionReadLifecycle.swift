import Foundation
#if SWIFT_PACKAGE
import TrafficCore
#endif

/// Owns one subscription read and rejects completions from superseded reads.
/// A completed token remains the latest token until a new read or invalidation,
/// so a cancellation already queued by the caller can still be recognized.
@MainActor
struct SubscriptionReadLifecycle {
    struct Token: Equatable {
        fileprivate let generation: UUID
        fileprivate let id: UUID
    }

    private struct ActiveRead {
        let token: Token
        var task: Task<Subscription, Error>?
    }

    private(set) var generation = UUID()
    private var active: ActiveRead?
    private var latest: Token?

    mutating func begin() -> Token? {
        guard active == nil else { return nil }
        let token = Token(generation: generation, id: UUID())
        active = ActiveRead(token: token)
        latest = token
        return token
    }

    mutating func attach(_ task: Task<Subscription, Error>, to token: Token) -> Bool {
        guard isActive(token) else { task.cancel(); return false }
        active?.task = task
        return true
    }

    func isActive(_ token: Token) -> Bool { active?.token == token && generation == token.generation }
    func isLatest(_ token: Token) -> Bool { latest == token && generation == token.generation }
    func taskIsCancelled(_ token: Token) -> Bool { isActive(token) && active?.task?.isCancelled == true }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard isActive(token) else { return false }
        active = nil
        return true
    }

    mutating func invalidate() {
        generation = UUID()
        active?.task?.cancel()
        active = nil
        latest = nil
    }
}
