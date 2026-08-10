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

    public func isInlinePromptButton(identifier: String, title: String) -> Bool {
        let value = "\(identifier) \(title)".lowercased()
        return ["request_user_input", "ask_user", "approval", "permission",
                "prompt-option", "prompt_option", "choice", "allow", "deny",
                "approve", "reject", "仅一次", "允许", "拒绝", "确认", "取消"]
            .contains(where: value.contains)
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
        let (_, root, isDialog) = try currentPromptRoot()
        return buttonElements(in: root).compactMap { element in
            let identifier = stringAttribute(kAXIdentifierAttribute, from: element) ?? ""
            guard let title = stringAttribute(kAXTitleAttribute, from: element),
                  !title.isEmpty,
                  isDialog || policy.isInlinePromptButton(
                    identifier: identifier, title: title
                  ),
                  policy.isDeviceSelectable(identifier: identifier, title: title) else { return nil }
            return CodexPromptOption(
                id: identifier.isEmpty ? "title:\(title)" : identifier,
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
        let (_, root, _) = try currentPromptRoot()
        guard let element = buttonElements(in: root).first(where: {
            let identifier = stringAttribute(kAXIdentifierAttribute, from: $0) ?? ""
            let identifierMatches = expected.id.hasPrefix("title:") || identifier == expected.id
            return identifierMatches && stringAttribute(kAXTitleAttribute, from: $0) == expected.title
        }) else {
            throw CodexApprovalError.optionNotFound
        }
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard status == .success else { throw CodexApprovalError.actionFailed(status) }
    }

    private func currentPromptRoot() throws -> (NSRunningApplication, AXUIElement, Bool) {
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
        if let dialog = breadthFirst(from: window, limit: 500).first(where: isDialog) {
            return (app, dialog, true)
        }
        // Plan-mode questions and request_user_input choices are rendered
        // inline rather than as AXDialog sheets. The caller only reaches this
        // fallback while the rollout journal reports an actionable prompt,
        // and options() further restricts buttons to prompt-like identifiers.
        return (app, window, false)
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
