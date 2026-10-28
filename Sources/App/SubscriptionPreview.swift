import Combine
import Foundation
#if SWIFT_PACKAGE
import TrafficCore
#endif

/// Temporary connection draft. The view owner retains this object while visiting
/// settings; hiding the view is not cancellation. No credentials, history,
/// airport models or notifications are created by this service.
@MainActor
final class SubscriptionPreview: ObservableObject {
    struct Result: Equatable {
        let url: URL
        let subscription: Subscription
        let readAt: Date
    }

    enum State: Equatable {
        case idle
        case reading
        case ready(Result)
        case failed(String)
        case cancelled
    }

    @Published private(set) var input = ""
    @Published private(set) var state: State = .idle
    private let fetch: (URL) async throws -> Subscription
    private let now: () -> Date
    private var readLifecycle = SubscriptionReadLifecycle()

    init(fetch: @escaping (URL) async throws -> Subscription = { try await SubscriptionClient().fetch($0) },
         now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    /// Changing a link invalidates a result even if the old request ignores cancellation.
    func setInput(_ value: String) {
        guard value != input else { return }
        invalidate()
        input = value
        state = .idle
    }

    /// A failed read retains the input. Calling read again explicitly retries it.
    /// A ready result is stable until the link changes or the user cancels.
    func read() async {
        if case .reading = state { return }
        if case .ready = state { return }
        guard !Task.isCancelled else { state = .cancelled; return }
        let url: URL
        do { url = try Subscription.validatedURL(input) }
        catch { state = .failed(TrafficError.invalidURL.localizedDescription); return }
        guard let token = readLifecycle.begin() else { return }
        state = .reading
        let task = Task { [fetch] in try await fetch(url) }
        guard readLifecycle.attach(task, to: token) else { return }
        await withTaskCancellationHandler {
            do {
                let subscription = try await task.value
                guard readLifecycle.finish(token) else { return }
                guard !Task.isCancelled, !task.isCancelled else { state = .cancelled; return }
                state = .ready(Result(url: url, subscription: subscription, readAt: now()))
            } catch {
                guard readLifecycle.finish(token) else { return }
                if Task.isCancelled || task.isCancelled || error is CancellationError {
                    state = .cancelled
                } else {
                    // Never expose arbitrary provider errors: they may include the secret URL.
                    state = .failed(Self.message(for: error))
                }
            }
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                guard let self, self.readLifecycle.isLatest(token) else { return }
                self.invalidate()
                // Cancelling the caller stops the read but retains the draft;
                // only the explicit cancel action clears the input.
                self.state = .cancelled
            }
        }
    }

    /// Explicit cancellation ends the draft and removes the secret from memory.
    func cancel() {
        invalidate()
        input = ""
        state = .cancelled
    }

    /// Only an explicit confirmation may pass this payload to the workspace save
    /// operation. Keep the preview on save failure so the user can retry.
    var confirmation: Result? {
        guard case .ready(let result) = state else { return nil }
        return result
    }

    private func invalidate() {
        readLifecycle.invalidate()
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let cooldown as SubscriptionCooldown:
            return cooldown.localizedDescription
        case TrafficError.missingHeader:
            return "服务器未返回流量信息，请确认订阅链接是否支持查询。"
        case TrafficError.invalidHeader:
            return "服务器返回的流量信息格式无效，请稍后重试。"
        case TrafficError.status(let code):
            return "读取失败（HTTP \(code)），请检查订阅链接或稍后重试。"
        case TrafficError.invalidURL:
            return TrafficError.invalidURL.localizedDescription
        default:
            return "读取失败，请检查网络和订阅链接后重试。"
        }
    }
}
