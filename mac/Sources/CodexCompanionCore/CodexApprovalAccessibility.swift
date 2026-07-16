#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

public struct CodexPromptOption: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let requiresLongPress: Bool

    public init(id: String, title: String, requiresLongPress: Bool) {
        self.id = id
        self.title = title
        self.requiresLongPress = requiresLongPress
    }
}

public struct ApprovalRiskPolicy: Sendable {
    public init() {}

    public func isDeviceSelectable(identifier: String) -> Bool {
        isDeviceSelectable(identifier: identifier, title: "")
    }

    public func isDeviceSelectable(identifier: String, title: String) -> Bool {
        let value = "\(identifier) \(title)".lowercased()
        return !["other", "free_text", "secret", "password", "custom",
                 "其他", "其它", "自定义", "密码"].contains {
            value.contains($0)
        }
    }

    public func requiresLongPress(identifier: String, title: String) -> Bool {
        let value = "\(identifier) \(title)".lowercased()
        if ["deny", "reject", "cancel", "allow_once", "approve_once", "仅一次", "拒绝", "取消"]
            .contains(where: value.contains) {
            return false
        }
        return true
    }
}

public enum CodexApprovalError: Error, Equatable {
    case codexNotFrontmost
    case dialogNotFound
    case optionNotFound
    case confirmationRequired
    case actionFailed(AXError)
}

public struct CodexApprovalAccessibilityBridge {
    private let policy = ApprovalRiskPolicy()

    public init() {}

    public func options() throws -> [CodexPromptOption] {
        let (_, dialog) = try currentDialog()
        return buttonElements(in: dialog).compactMap { element in
            guard let identifier = stringAttribute(kAXIdentifierAttribute, from: element),
                  !identifier.isEmpty,
                  let title = stringAttribute(kAXTitleAttribute, from: element),
                  !title.isEmpty,
                  policy.isDeviceSelectable(identifier: identifier, title: title) else { return nil }
            return CodexPromptOption(
                id: identifier,
                title: title,
                requiresLongPress: policy.requiresLongPress(
                    identifier: identifier,
                    title: title
                )
            )
        }
    }

    public func press(option expected: CodexPromptOption, confirmedLongPress: Bool) throws {
        if expected.requiresLongPress && !confirmedLongPress {
            throw CodexApprovalError.confirmationRequired
        }
        let (_, dialog) = try currentDialog()
        guard let element = buttonElements(in: dialog).first(where: {
            stringAttribute(kAXIdentifierAttribute, from: $0) == expected.id &&
            stringAttribute(kAXTitleAttribute, from: $0) == expected.title
        }) else {
            throw CodexApprovalError.optionNotFound
        }
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success else { throw CodexApprovalError.actionFailed(status) }
    }

    private func currentDialog() throws -> (NSRunningApplication, AXUIElement) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == CodexInteractionGate.bundleIdentifier else {
            throw CodexApprovalError.codexNotFrontmost
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
              let windowValue else { throw CodexApprovalError.dialogNotFound }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
        guard let dialog = breadthFirst(from: window, limit: 500).first(where: isDialog) else {
            throw CodexApprovalError.dialogNotFound
        }
        return (app, dialog)
    }

    private func isDialog(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        return role == kAXSheetRole as String || role == "AXDialog" ||
            subrole == "AXDialog" || subrole == "AXSystemDialog"
    }

    private func buttonElements(in root: AXUIElement) -> [AXUIElement] {
        breadthFirst(from: root, limit: 200).filter {
            stringAttribute(kAXRoleAttribute, from: $0) == kAXButtonRole as String
        }
    }

    private func breadthFirst(from root: AXUIElement, limit: Int) -> [AXUIElement] {
        var queue = [root]
        var result: [AXUIElement] = []
        while !queue.isEmpty && result.count < limit {
            let current = queue.removeFirst()
            result.append(current)
            var childrenValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                current,
                kAXChildrenAttribute as CFString,
                &childrenValue
            ) == .success,
               let children = childrenValue as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return result
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
#endif
