import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case weather
    case keyMappings
    case audio

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "连接中心"
        case .weather: "天气同步"
        case .keyMappings: "按键映射"
        case .audio: "音频诊断"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "dot.radiowaves.left.and.right"
        case .weather: "cloud.sun"
        case .keyMappings: "keyboard"
        case .audio: "waveform"
        }
    }
}
