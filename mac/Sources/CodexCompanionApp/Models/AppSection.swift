import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case keyMappings
    case audio

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "连接中心"
        case .keyMappings: "按键映射"
        case .audio: "音频诊断"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "dot.radiowaves.left.and.right"
        case .keyMappings: "keyboard"
        case .audio: "waveform"
        }
    }
}
