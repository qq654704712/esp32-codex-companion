import Foundation

public struct KeyboardModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let shift = Self(rawValue: 1 << 3)
    public static let fn = Self(rawValue: 1 << 4)
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: KeyboardModifiers
    public let modifierOnly: Bool

    public init(
        keyCode: UInt16,
        modifiers: KeyboardModifiers = [],
        modifierOnly: Bool = false
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.modifierOnly = modifierOnly
    }

    /// macOS virtual key code for Return on the main keyboard.
    public static let returnKey = KeyboardShortcut(keyCode: 36)
}

public enum VoiceProfileMatchPolicy: String, Codable, Sendable {
    case activeInputSource
    case always
}

public enum VoiceTriggerMode: String, Codable, Sendable {
    case hold
    case togglePair
    case separate
}

public struct VoiceShortcutProfile: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var displayName: String
    public var matchPolicy: VoiceProfileMatchPolicy
    public var inputSourceIDs: [String]
    public var triggerMode: VoiceTriggerMode
    public var startShortcut: KeyboardShortcut
    public var stopShortcut: KeyboardShortcut?
    public var preRollMs: UInt32
    public var postRollMs: UInt32
    public var commitGraceMs: UInt32
    public var restoreInputSource: Bool
    public var isEnabled: Bool

    public init(
        id: String,
        displayName: String,
        matchPolicy: VoiceProfileMatchPolicy,
        inputSourceIDs: [String] = [],
        triggerMode: VoiceTriggerMode,
        startShortcut: KeyboardShortcut,
        stopShortcut: KeyboardShortcut? = nil,
        preRollMs: UInt32 = 300,
        postRollMs: UInt32 = 200,
        commitGraceMs: UInt32 = 2_500,
        restoreInputSource: Bool = true,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.matchPolicy = matchPolicy
        self.inputSourceIDs = inputSourceIDs
        self.triggerMode = triggerMode
        self.startShortcut = startShortcut
        self.stopShortcut = stopShortcut
        self.preRollMs = preRollMs
        self.postRollMs = postRollMs
        self.commitGraceMs = commitGraceMs
        self.restoreInputSource = restoreInputSource
        self.isEnabled = isEnabled
    }

    /// Safe out-of-the-box physical mapping for the device BOOT button. A
    /// saved user profile always takes precedence, so input methods that do
    /// not accept synthesized Fn can use an ordinary shortcut instead.
    public static let bootFnDefault = VoiceShortcutProfile(
        id: "boot-fn-default",
        displayName: "BOOT → Fn",
        matchPolicy: .always,
        triggerMode: .hold,
        startShortcut: KeyboardShortcut(
            keyCode: 63,
            modifiers: [.fn],
            modifierOnly: true
        ),
        preRollMs: 0,
        postRollMs: 200,
        restoreInputSource: false
    )

    private enum CodingKeys: String, CodingKey {
        case id, displayName, matchPolicy, inputSourceIDs, triggerMode
        case startShortcut, stopShortcut, preRollMs, postRollMs, commitGraceMs
        case restoreInputSource, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        matchPolicy = try container.decode(VoiceProfileMatchPolicy.self, forKey: .matchPolicy)
        inputSourceIDs = try container.decodeIfPresent([String].self, forKey: .inputSourceIDs) ?? []
        triggerMode = try container.decode(VoiceTriggerMode.self, forKey: .triggerMode)
        startShortcut = try container.decode(KeyboardShortcut.self, forKey: .startShortcut)
        stopShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .stopShortcut)
        preRollMs = try container.decodeIfPresent(UInt32.self, forKey: .preRollMs) ?? 300
        postRollMs = try container.decodeIfPresent(UInt32.self, forKey: .postRollMs) ?? 200
        commitGraceMs = try container.decodeIfPresent(UInt32.self, forKey: .commitGraceMs) ?? 2_500
        restoreInputSource = try container.decodeIfPresent(Bool.self, forKey: .restoreInputSource) ?? true
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public struct VoiceProfileResolver: Sendable {
    public init() {}

    public func resolve(
        profiles: [VoiceShortcutProfile],
        activeInputSourceID: String?
    ) -> VoiceShortcutProfile? {
        let enabled = profiles.filter(\.isEnabled)
        if let activeInputSourceID,
           let exact = enabled.first(where: {
               $0.matchPolicy == .activeInputSource
                   && $0.inputSourceIDs.contains(activeInputSourceID)
           }) {
            return exact
        }
        return enabled.first(where: { $0.matchPolicy == .always })
    }
}
