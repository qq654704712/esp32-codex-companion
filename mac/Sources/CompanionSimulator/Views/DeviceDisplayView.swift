import CodexCompanionCore
import Foundation
import SwiftUI

enum ArcadePalette {
    // A high-saturation spectrum on a genuinely near-black base. These colors
    // are assigned by meaning, so the display stays legible at a glance.
    static let ink = Color(red: 0.004, green: 0.006, blue: 0.008)
    static let navy = Color(red: 0.014, green: 0.075, blue: 0.13)
    static let forest = Color(red: 0.025, green: 0.19, blue: 0.075)
    static let teal = Color(red: 0.0, green: 0.82, blue: 0.72)
    static let blue = Color(red: 0.10, green: 0.58, blue: 1.0)
    static let mint = Color(red: 0.62, green: 0.94, blue: 0.20)
    static let amber = Color(red: 1.0, green: 0.40, blue: 0.12)
    static let alarm = Color(red: 1.0, green: 0.22, blue: 0.28)
    static let magenta = Color(red: 0.86, green: 0.18, blue: 0.84)
    static let violet = Color(red: 0.42, green: 0.27, blue: 1.0)
    static let inactive = Color(red: 0.09, green: 0.16, blue: 0.22)
    // The companion itself is deliberately neutral and compact: the saturated
    // telemetry remains in the surrounding HUD rather than turning it into a
    // neon robot.
    static let graphite = Color(red: 0.20, green: 0.25, blue: 0.28)
    static let shell = Color(red: 0.055, green: 0.071, blue: 0.082)
    static let screen = Color(red: 0.006, green: 0.012, blue: 0.015)
    static let signal = Color(red: 1.0, green: 0.25, blue: 0.33)
}

struct DeviceDisplayView: View {
    let model: SimulatorModel

    var body: some View {
        ZStack {
            ArcadePalette.ink
            ArcadeBackdrop()
            HUDReticle()
            RingMarkers(radius: 151, color: ArcadePalette.blue)
            RingMarkers(radius: 141, color: ArcadePalette.mint)
            quotaRing(radius: 175, percent: model.fiveHourAvailable ? model.fiveHourPercent : nil, color: ArcadePalette.blue)
            quotaRing(radius: 166, percent: model.weekAvailable ? model.weekPercent : nil, color: ArcadePalette.mint)
            TelemetryReadout(model: model)

            if model.deviceState == .listening {
                AudioWaveView(level: model.audioLevel)
            } else if model.deviceState == .approvalRequired {
                ApprovalPromptView(options: model.promptOptions, selected: model.selectedOption)
            } else {
                PixelCodexCharacterView(state: model.deviceState)
            }

            if model.stale {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(ArcadePalette.amber)
                    .font(.system(size: 13, weight: .bold))
                    .offset(y: 132)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("360 by 360 Codex Companion display")
    }

    private func quotaRing(radius: CGFloat, percent: Double?, color: Color) -> some View {
        ZStack {
            if let percent {
                Circle()
                    .stroke(ArcadePalette.inactive, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(percent / 100, 0), 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.72), radius: 5)
            } else {
                Circle()
                    .stroke(
                        ArcadePalette.inactive.opacity(0.95),
                        style: StrokeStyle(lineWidth: 5, dash: [3, 6])
                    )
            }
        }
        .frame(width: radius * 2, height: radius * 2)
        .opacity(model.stale ? 0.48 : 1)
    }
}

private struct TelemetryReadout: View {
    let model: SimulatorModel

    var body: some View {
        VStack(spacing: 0) {
            Text("CODEX // CONTEXT LINK")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(ArcadePalette.teal.opacity(0.86))
                .offset(y: -119)
            Spacer()
            HStack(spacing: 16) {
                metric("05H", model.fiveHourAvailable ? model.fiveHourPercent : nil, ArcadePalette.blue)
                metric("07D", model.weekAvailable ? model.weekPercent : nil, ArcadePalette.mint)
            }
            .offset(y: 110)
        }
        .frame(width: 310, height: 310)
        .allowsHitTesting(false)
    }

    private func metric(_ title: String, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 4, height: 4)
            Text("\(title) \(value.map { String(format: "%02d", Int($0)) } ?? "--")")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(color.opacity(0.9))
        }
    }
}

private struct RingMarkers: View {
    let radius: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                Rectangle()
                    .fill(color.opacity(index.isMultiple(of: 3) ? 0.64 : 0.25))
                    .frame(width: 2, height: index.isMultiple(of: 3) ? 7 : 4)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(index) * 30))
            }
        }
    }
}

private struct HUDReticle: View {
    var body: some View {
        ZStack {
            corner(x: -117, y: -72, flipX: false, flipY: false)
            corner(x: 117, y: -72, flipX: true, flipY: false)
            corner(x: -117, y: 72, flipX: false, flipY: true)
            corner(x: 117, y: 72, flipX: true, flipY: true)
        }
        .allowsHitTesting(false)
    }

    private func corner(x: CGFloat, y: CGFloat, flipX: Bool, flipY: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(ArcadePalette.teal.opacity(0.48)).frame(width: 14, height: 2)
            Rectangle().fill(ArcadePalette.blue.opacity(0.48)).frame(width: 2, height: 14)
        }
        .scaleEffect(x: flipX ? -1 : 1, y: flipY ? -1 : 1, anchor: .topLeading)
        .offset(x: x, y: y)
    }
}

private struct ArcadeBackdrop: View {
    // Sparse, fixed pixels are deliberately quieter than a color wash. They
    // give the black display a little depth without competing with the rings.
    private let points = (0..<12).map { index in
        let x = CGFloat((index * 67) % 259) - 129
        let y = CGFloat((index * 91) % 241) - 120
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(ArcadePalette.ink)
                .frame(width: 300, height: 300)
            Circle()
                .stroke(ArcadePalette.navy.opacity(0.72), lineWidth: 1)
                .frame(width: 300, height: 300)
            ForEach(points.indices, id: \.self) { index in
                Rectangle()
                    .fill(index.isMultiple(of: 4) ? ArcadePalette.blue.opacity(0.32) : ArcadePalette.teal.opacity(0.15))
                    .frame(width: index.isMultiple(of: 5) ? 3 : 2, height: index.isMultiple(of: 5) ? 3 : 2)
                    .offset(x: points[index].x, y: points[index].y)
            }
        }
        .mask(Circle().frame(width: 338, height: 338))
    }
}
