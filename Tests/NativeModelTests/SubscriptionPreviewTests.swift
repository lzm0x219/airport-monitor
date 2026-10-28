import Foundation
import Testing
import TrafficCore
@testable import NativeModels

@Suite @MainActor
struct SubscriptionPreviewTests {
    @MainActor final class Reader {
        var urls: [URL] = []
        var pending: [Int: CheckedContinuation<TrafficCore.Subscription, Error>] = [:]

        func fetch(_ url: URL) async throws -> TrafficCore.Subscription {
            let index = urls.count
            urls.append(url)
            return try await withCheckedThrowingContinuation { pending[index] = $0 }
        }

        func waitFor(_ count: Int) async throws {
            for _ in 0..<1_000 {
                if urls.count == count { return }
                await Task.yield()
            }
            try #require(urls.count == count)
        }

        func succeed(_ index: Int, used: UInt64 = 10) throws {
            pending.removeValue(forKey: index)?.resume(returning: try TrafficCore.Subscription(upload: 0, download: used, total: 100))
        }

        func fail(_ index: Int, error: Error = TrafficError.network(-1009)) {
            pending.removeValue(forKey: index)?.resume(throwing: error)
        }
    }

    @Test func invalidInputDoesNotReadOrOfferConfirmation() async {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        preview.setInput("http://example.invalid/token")
        await preview.read()
        #expect(reader.urls.isEmpty)
        #expect(preview.confirmation == nil)
        #expect(preview.input == "http://example.invalid/token")
        guard case .failed = preview.state else { Issue.record("Expected validation failure"); return }
    }

    @Test func duplicateReadsAreCoalescedAndReadyResultRequiresExplicitConfirmation() async throws {
        let reader = Reader(), date = Date(timeIntervalSince1970: 123)
        let preview = SubscriptionPreview(fetch: { try await reader.fetch($0) }, now: { date })
        preview.setInput("https://example.invalid/token")
        let first = Task { await preview.read() }
        try await reader.waitFor(1)
        await preview.read()
        #expect(reader.urls.count == 1)
        #expect(preview.confirmation == nil)
        try reader.succeed(0)
        await first.value
        let result = try #require(preview.confirmation)
        #expect(result.subscription.used == 10)
        #expect(result.subscription.expiry == nil) // Missing optional metadata does not prevent adding.
        #expect(result.readAt == date)
        await preview.read()
        #expect(reader.urls.count == 1)
        // Retrieving the explicit save payload never consumes or persists it.
        #expect(preview.confirmation == result)
    }

    @Test(arguments: [true, false])
    func cancellationRejectsLateSuccessAndFailure(succeeds: Bool) async throws {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        preview.setInput("https://example.invalid/token")
        let first = Task { await preview.read() }
        try await reader.waitFor(1)
        preview.cancel()
        if succeeds { try reader.succeed(0) } else { reader.fail(0) }
        await first.value
        #expect(preview.state == .cancelled)
        #expect(preview.input.isEmpty)
        #expect(preview.confirmation == nil)
    }

    @Test(arguments: [true, false])
    func replacedInputKeepsNewResultWhenOldRequestCompletes(succeeds: Bool) async throws {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        preview.setInput("https://old.invalid/token")
        let first = Task { await preview.read() }
        try await reader.waitFor(1)
        preview.setInput("https://new.invalid/token")
        let second = Task { await preview.read() }
        try await reader.waitFor(2)
        try reader.succeed(1, used: 30)
        await second.value
        if succeeds { try reader.succeed(0) } else { reader.fail(0) }
        await first.value
        #expect(preview.confirmation?.url.host == "new.invalid")
        #expect(preview.confirmation?.subscription.used == 30)
    }

    @Test(arguments: [true, false], [true, false])
    func cancellingOldCallerCannotDiscardNewPreview(succeeds: Bool, currentCompletesFirst: Bool) async throws {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        preview.setInput("https://old.invalid/token")
        let old = Task { await preview.read() }
        try await reader.waitFor(1)
        preview.setInput("https://new.invalid/token")
        let current = Task { await preview.read() }
        try await reader.waitFor(2)
        if currentCompletesFirst {
            try reader.succeed(1, used: 30)
            await current.value
        }
        old.cancel()
        if succeeds { try reader.succeed(0) } else { reader.fail(0) }
        await old.value
        for _ in 0..<10 { await Task.yield() }
        if !currentCompletesFirst {
            #expect(preview.state == .reading)
            try reader.succeed(1, used: 30)
            await current.value
        }
        #expect(preview.confirmation?.url.host == "new.invalid")
        #expect(preview.confirmation?.subscription.used == 30)
    }

    @Test func failedReadCanRetryWithSameInputAndDoesNotExposeSecret() async throws {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        let input = "https://example.invalid/private-token"
        preview.setInput(input)
        let first = Task { await preview.read() }
        try await reader.waitFor(1)
        reader.fail(0, error: NSError(domain: "provider", code: 1, userInfo: [NSLocalizedDescriptionKey: input]))
        await first.value
        guard case .failed(let message) = preview.state else { Issue.record("Expected failure"); return }
        #expect(!message.contains("private-token"))
        #expect(preview.input == input)
        let retry = Task { await preview.read() }
        try await reader.waitFor(2)
        try reader.succeed(1)
        await retry.value
        #expect(preview.confirmation != nil)
    }

    @Test(arguments: [true, false])
    func callerCancellationRejectsUncooperativeTransportAndRetainsDraft(succeeds: Bool) async throws {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        let input = "https://example.invalid/token"
        preview.setInput(input)
        let caller = Task { await preview.read() }
        try await reader.waitFor(1)
        caller.cancel()
        for _ in 0..<1_000 {
            if preview.state == .cancelled { break }
            await Task.yield()
        }
        #expect(preview.state == .cancelled)
        #expect(preview.confirmation == nil)
        // This fake transport deliberately ignores cancellation and finishes late.
        if succeeds { try reader.succeed(0) } else { reader.fail(0) }
        await caller.value
        #expect(preview.state == .cancelled)
        #expect(preview.input == input)
        #expect(preview.confirmation == nil)
        let retry = Task { await preview.read() }
        try await reader.waitFor(2)
        try reader.succeed(1)
        await retry.value
        #expect(preview.confirmation != nil)
    }

    @Test func retainedDraftCanFinishWhileViewIsAwayAndCancelStillInvalidatesIt() async throws {
        let reader = Reader(), preview = SubscriptionPreview(fetch: { try await reader.fetch($0) })
        preview.setInput("https://example.invalid/token")
        let read = Task { await preview.read() }
        try await reader.waitFor(1)
        // The owner holds the draft across a settings round-trip. No view
        // lifecycle callback is needed, and completion cannot navigate any UI.
        let retainedDraft = preview
        try reader.succeed(0)
        await read.value
        #expect(retainedDraft.confirmation != nil)
        retainedDraft.cancel()
        #expect(preview.state == .cancelled)
        #expect(preview.confirmation == nil)
    }
}
