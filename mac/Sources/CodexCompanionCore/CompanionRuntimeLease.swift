#if os(macOS)
import Darwin
import Foundation

/// An advisory cross-process lease. The launchd agent owns it for normal
/// operation, so opening the GUI cannot start a competing CoreBluetooth scan.
public final class CompanionRuntimeLease {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { release() }

    public static func acquire(lockURL: URL? = nil) -> CompanionRuntimeLease? {
        let lockURL = lockURL ?? defaultLockURL
        let directory = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return CompanionRuntimeLease(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    private static var defaultLockURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return root.appendingPathComponent("CodexCompanion", isDirectory: true)
            .appendingPathComponent("runtime.lock")
    }
}
#endif
