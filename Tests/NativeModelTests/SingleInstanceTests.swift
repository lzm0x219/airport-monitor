import Foundation
import Testing
@testable import NativeModels

@Suite @MainActor
struct SingleInstanceTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SingleInstanceTests-\(UUID())")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }

    @Test func duplicateLaunchesWakeTheOwnerAndDoNotAcquireTheLease() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var reopens = 0
        let owner = try #require(SingleInstanceCoordinator.start(directory: root) { reopens += 1 })
        defer { withExtendedLifetime(owner) {} }

        // This request can arrive before the owner's file observer is registered.
        let first = try SingleInstanceCoordinator.start(directory: root) { Issue.record("Duplicate became owner") }
        #expect(first == nil)
        try await waitUntil { reopens == 1 }

        // This request arrives after registration and exercises the live observer.
        let second = try SingleInstanceCoordinator.start(directory: root) { Issue.record("Duplicate became owner") }
        #expect(second == nil)
        try await waitUntil { reopens == 2 }
    }

    @Test func pendingRequestIsHandledAfterRegistration() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("instance-reopen.signal"))
        var reopens = 0
        let owner = try #require(SingleInstanceCoordinator.start(directory: root) { reopens += 1 })
        defer { withExtendedLifetime(owner) {} }
        try await waitUntil { reopens == 1 }
        #expect(try Data(contentsOf: root.appendingPathComponent("instance-reopen.signal")).isEmpty)
    }

    @Test func releasingOwnerAllowsAnotherLaunch() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        var owner = try SingleInstanceCoordinator.start(directory: root) {}
        try #require(owner != nil)
        withExtendedLifetime(owner) {}
        owner = nil
        let next = try SingleInstanceCoordinator.start(directory: root) {}
        #expect(next != nil)
    }

    @Test func inaccessibleDirectoryFailsClosed() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        #expect(throws: (any Error).self) {
            _ = try SingleInstanceCoordinator.start(directory: root) {}
        }
    }

    @Test func anotherProcessHoldsTheLeaseUntilItExits() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let holder = Process(), ready = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        holder.arguments = ["swift", "-e", """
            import Darwin
            let fd = open(CommandLine.arguments[1], O_CREAT | O_RDWR, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { _exit(2) }
            var byte: UInt8 = 1
            _ = write(STDOUT_FILENO, &byte, 1)
            pause()
            """, root.appendingPathComponent("instance.lock").path]
        holder.standardOutput = ready
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        try #require(ready.fileHandleForReading.read(upToCount: 1) == Data([1]))
        #expect(try SingleInstanceCoordinator.start(directory: root) {} == nil)
        holder.terminate(); holder.waitUntilExit()
        #expect(try SingleInstanceCoordinator.start(directory: root) {} != nil)
    }
}
