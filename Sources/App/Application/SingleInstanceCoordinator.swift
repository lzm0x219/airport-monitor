import Foundation
import Darwin

/// Holds one process-wide lease and forwards later launches to its owner.
@MainActor
final class SingleInstanceCoordinator {
    private let lockDescriptor: Int32
    private var signalSource: DispatchSourceFileSystemObject?
    private let onReopen: () -> Void

    private init(lockDescriptor: Int32, onReopen: @escaping () -> Void) {
        self.lockDescriptor = lockDescriptor
        self.onReopen = onReopen
    }

    /// Returns nil after signalling the existing process. The lock is released by
    /// the OS even if its owner crashes; neither file must be unlinked while in use.
    static func start(directory: URL, onReopen: @escaping () -> Void) throws -> SingleInstanceCoordinator? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("instance.lock")
        let signalURL = directory.appendingPathComponent("instance-reopen.signal")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(descriptor)
            guard reason == EWOULDBLOCK || reason == EAGAIN else { throw posixError(reason) }
            try signalOwner(at: signalURL)
            return nil
        }

        let coordinator = SingleInstanceCoordinator(lockDescriptor: descriptor, onReopen: onReopen)
        let signalDescriptor = open(signalURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard signalDescriptor >= 0 else { throw posixError() }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: signalDescriptor,
                                                               eventMask: .write, queue: .main)
        source.setEventHandler { [weak coordinator] in coordinator?.consumeSignal(signalDescriptor) }
        // A second process can signal between acquiring the lock and registering
        // the source. Inspect the file after registration so that request survives.
        source.setRegistrationHandler { [weak coordinator] in coordinator?.consumeSignal(signalDescriptor) }
        source.setCancelHandler { close(signalDescriptor) }
        coordinator.signalSource = source
        source.resume()
        return coordinator
    }

    private static func signalOwner(at url: URL) throws {
        let descriptor = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var byte: UInt8 = 1
        var result: Int
        repeat { result = write(descriptor, &byte, 1) } while result < 0 && errno == EINTR
        guard result == 1 else { throw posixError(result < 0 ? errno : EIO) }
    }

    private func consumeSignal(_ descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return }
        // If several requests arrive together, one reopening satisfies them all.
        _ = ftruncate(descriptor, 0)
        onReopen()
    }

    private static func posixError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    deinit {
        signalSource?.cancel()
        close(lockDescriptor)
    }
}
