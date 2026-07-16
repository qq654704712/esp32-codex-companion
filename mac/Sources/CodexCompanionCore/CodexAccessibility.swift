#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

public struct FocusedElementSnapshot: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let role: String?
    public let isEditable: Bool
    public let isSecure: Bool

    public init(
        bundleIdentifier: String?,
        role: String?,
        isEditable: Bool,
        isSecure: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.isEditable = isEditable
        self.isSecure = isSecure
    }
}

public struct CodexInteractionGate: Sendable {
    public static let bundleIdentifier = "com.openai.codex"

    public init() {}

    public func allowsVoiceInput(_ snapshot: FocusedElementSnapshot) -> Bool {
        guard snapshot.bundleIdentifier == Self.bundleIdentifier,
              snapshot.isEditable,
              !snapshot.isSecure else { return false }
        return snapshot.role == kAXTextAreaRole as String
            || snapshot.role == kAXTextFieldRole as String
    }
}

public struct CodexAccessibilityInspector {
    public init() {}

    public func focusedElement() -> FocusedElementSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return .init(bundleIdentifier: nil, role: nil, isEditable: false, isSecure: false)
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue else {
            return .init(bundleIdentifier: bundleID, role: nil, isEditable: false, isSecure: false)
        }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        let role = stringAttribute(kAXRoleAttribute, element: element)
        let subrole = stringAttribute(kAXSubroleAttribute, element: element)
        var editable = DarwinBoolean(false)
        let editableStatus = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &editable
        )
        // Chromium/Electron contenteditables (including the Codex composer)
        // expose AXTextArea and AXEditableAncestor but do not advertise AXValue
        // as directly settable. Treat that ancestor as editable while retaining
        // the frontmost-app and secure-field gates below.
        let hasEditableAncestor = hasAttribute("AXEditableAncestor", element: element)
            || hasAttribute("AXHighestEditableAncestor", element: element)
        return .init(
            bundleIdentifier: bundleID,
            role: role,
            isEditable: Self.isEditable(
                valueIsSettable: editableStatus == .success && editable.boolValue,
                hasEditableAncestor: hasEditableAncestor
            ),
            isSecure: subrole == kAXSecureTextFieldSubrole as String
        )
    }

    static func isEditable(valueIsSettable: Bool, hasEditableAncestor: Bool) -> Bool {
        valueIsSettable || hasEditableAncestor
    }

    public func canStartVoiceInput() -> Bool {
        CodexInteractionGate().allowsVoiceInput(focusedElement())
    }

    private func stringAttribute(_ name: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func hasAttribute(_ name: String, element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            && value != nil
    }
}
#endif
