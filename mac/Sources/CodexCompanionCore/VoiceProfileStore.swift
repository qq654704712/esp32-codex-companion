import Foundation

public enum VoiceProfileValidationError: Error, Equatable {
    case emptyIdentifier
    case emptyDisplayName
    case missingInputSource
    case missingStopShortcut
    case invalidTiming
}

public enum VoiceProfileValidator {
    public static func validate(_ profile: VoiceShortcutProfile) throws {
        guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceProfileValidationError.emptyIdentifier
        }
        guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceProfileValidationError.emptyDisplayName
        }
        if profile.matchPolicy == .activeInputSource && profile.inputSourceIDs.isEmpty {
            throw VoiceProfileValidationError.missingInputSource
        }
        if profile.triggerMode == .separate && profile.stopShortcut == nil {
            throw VoiceProfileValidationError.missingStopShortcut
        }
        guard profile.preRollMs <= 2_000, profile.postRollMs <= 2_000,
              profile.commitGraceMs <= 10_000 else {
            throw VoiceProfileValidationError.invalidTiming
        }
    }
}

public struct VoiceProfileStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CodexCompanion", isDirectory: true)
                .appendingPathComponent("voice-profiles.json")
        }
    }

    public func load() throws -> [VoiceShortcutProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let profiles = try JSONDecoder().decode([VoiceShortcutProfile].self, from: data)
        try profiles.forEach(VoiceProfileValidator.validate)
        return profiles
    }

    public func save(_ profiles: [VoiceShortcutProfile]) throws {
        try profiles.forEach(VoiceProfileValidator.validate)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profiles).write(to: fileURL, options: [.atomic])
    }
}
