import Foundation

public struct HookInbox: Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexCompanion/Hooks", isDirectory: true)
        }
    }

    public func enqueue(_ payload: Data) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let stamp = String(format: "%020llu", DispatchTime.now().uptimeNanoseconds)
        let target = directoryURL.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
        // macOS test and launch-agent files live in the user's Application
        // Support directory. Applying iOS file-protection classes there can
        // leave a just-written hook unreadable under TCC/sandboxed test
        // runners, so only request that protection on platforms which support
        // it as intended.
        #if os(iOS)
        let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
        let writeOptions: Data.WritingOptions = [.atomic]
        #endif
        try payload.write(to: target, options: writeOptions)
    }

    public func drain() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [Data] = []
        for file in files {
            let data = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            result.append(data)
        }
        return result
    }
}
