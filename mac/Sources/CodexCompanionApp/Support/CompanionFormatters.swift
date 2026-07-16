import CodexCompanionCore
import Foundation

func bleStateText(_ state: CompanionBLECentral.State) -> String {
    switch state {
    case .unavailable: "蓝牙不可用"
    case .scanning: "正在扫描"
    case .connecting: "正在连接"
    case .connected: "已连接"
    case .disconnected: "未连接"
    case .failed(let reason): "失败：\(reason)"
    }
}

func shortcutText(_ shortcut: KeyboardShortcut?) -> String {
    guard let shortcut else { return "未设置" }
    var parts: [String] = []
    if shortcut.modifiers.contains(.control) { parts.append("⌃") }
    if shortcut.modifiers.contains(.option) { parts.append("⌥") }
    if shortcut.modifiers.contains(.shift) { parts.append("⇧") }
    if shortcut.modifiers.contains(.command) { parts.append("⌘") }
    if shortcut.modifiers.contains(.fn) { parts.append("Fn") }
    if !shortcut.modifierOnly { parts.append("键码 \(shortcut.keyCode)") }
    return parts.isEmpty ? "键码 \(shortcut.keyCode)" : parts.joined(separator: " ")
}
