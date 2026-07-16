import CodexCompanionCore
import SwiftUI

/// An original compact terminal pet for Codex. Its screen carries a tiny `>_`
/// prompt, so it reads as a companion for coding and conversation rather than
/// a humanoid robot or a copied product mark.
struct PixelCodexCharacterView: View {
    let state: DeviceState

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.083)) { timeline in
            let scene = CodexTerminalPetScene(state: state, frame: Int(timeline.date.timeIntervalSinceReferenceDate * 12) % 12)
            VStack(spacing: 7) {
                PixelPet(blocks: scene.blocks)
                    .offset(x: scene.offset.width, y: scene.offset.height)
                Text(scene.label)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.45)
                    .foregroundStyle(scene.labelColor)
                    .shadow(color: scene.labelColor.opacity(0.72), radius: 3)
            }
        }
        .accessibilityLabel("Codex pocket pet animation: \(state.rawValue)")
    }
}

private struct PixelPet: View {
    let blocks: [PixelBlock]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                Rectangle()
                    .fill(block.color)
                    .frame(width: CGFloat(block.width * 6), height: CGFloat(block.height * 6))
                    .offset(x: CGFloat(block.x * 6), y: CGFloat(block.y * 6))
            }
        }
        .frame(width: 144, height: 144, alignment: .topLeading)
    }
}

private struct PixelBlock {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let color: Color

    init(_ x: Int, _ y: Int, _ width: Int = 1, _ height: Int = 1, _ color: Color) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
    }
}

private struct CodexTerminalPetScene {
    let state: DeviceState
    let frame: Int

    private var pulse: Bool { frame.isMultiple(of: 2) }
    private var blink: Bool { state == .idle && frame == 10 }

    var label: String {
        switch state {
        case .disconnected: "LINK LOST"
        case .idle: "CODEX READY"
        case .sessionStarting: "BOOTING"
        case .working: "WORKING"
        case .writing: "WRITING"
        case .running: "RUNNING"
        case .completed: "PATCHED"
        case .error: "SYSTEM FAULT"
        case .approvalRequired: "REVIEW NEEDED"
        case .inputRequired: "NEED INPUT"
        case .confirmationRequired: "HOLD TO APPLY"
        case .listening: "LISTENING"
        case .voiceError: "MIC FAULT"
        }
    }

    var labelColor: Color {
        switch state {
        case .completed: ArcadePalette.mint
        case .error, .voiceError: ArcadePalette.alarm
        case .approvalRequired: ArcadePalette.amber
        case .inputRequired: ArcadePalette.magenta
        case .confirmationRequired: ArcadePalette.violet
        case .disconnected: ArcadePalette.inactive
        default: ArcadePalette.teal
        }
    }

    var offset: CGSize {
        switch state {
        case .idle: CGSize(width: 0, height: pulse ? -1 : 0)
        case .sessionStarting: CGSize(width: 0, height: frame < 5 ? 4 - frame : 0)
        case .working: CGSize(width: 0, height: pulse ? -2 : 0)
        case .writing: CGSize(width: pulse ? -1 : 1, height: 0)
        case .running: CGSize(width: 0, height: pulse ? -1 : 1)
        case .completed: CGSize(width: 0, height: frame < 4 ? -6 : 0)
        case .error, .voiceError: CGSize(width: pulse ? -3 : 3, height: 0)
        case .disconnected: CGSize(width: pulse ? -1 : 1, height: 1)
        default: .zero
        }
    }

    var blocks: [PixelBlock] {
        var pixels = terminal
        switch state {
        case .disconnected: pixels += disconnected
        case .idle: pixels += idle
        case .sessionStarting: pixels += hello
        case .working: pixels += thinking
        case .writing: pixels += thinking + writing
        case .running: pixels += thinking
        case .completed: pixels += completed
        case .error: pixels += error
        case .approvalRequired: pixels += approval
        case .inputRequired: pixels += input
        case .confirmationRequired: pixels += confirmation
        case .listening: break
        case .voiceError: pixels += voiceError
        }
        return pixels
    }

    private var terminal: [PixelBlock] {
        let outline = state == .disconnected ? ArcadePalette.inactive : ArcadePalette.graphite
        let casing = state == .disconnected ? ArcadePalette.navy : ArcadePalette.shell
        let signal = state == .disconnected ? ArcadePalette.inactive : ArcadePalette.signal
        let screenEdge = state == .disconnected ? ArcadePalette.inactive : ArcadePalette.graphite
        return [
            // Compact, screen-first shell: a pet-sized terminal, not a body.
            PixelBlock(10, 1, 1, 2, outline), PixelBlock(11, 0, 2, 1, outline),
            PixelBlock(12, 1, 1, 2, outline), PixelBlock(11, 2, 2, 1, casing),
            PixelBlock(7, 3, 10, 1, outline), PixelBlock(5, 4, 14, 1, outline),
            PixelBlock(4, 5, 16, 10, outline), PixelBlock(5, 15, 14, 2, outline), PixelBlock(7, 17, 10, 1, outline),
            PixelBlock(5, 5, 14, 10, casing), PixelBlock(6, 15, 12, 1, casing),
            PixelBlock(3, 8, 1, 4, outline), PixelBlock(20, 8, 1, 4, outline),
            // Soft little underframe pads make it a pet without giving it a humanoid body.
            PixelBlock(7, 18, 3, 2, outline), PixelBlock(14, 18, 3, 2, outline),
            PixelBlock(8, 18, 1, 1, casing), PixelBlock(15, 18, 1, 1, casing),
            // Recessed dark display and a single warm status point.
            PixelBlock(6, 6, 12, 7, screenEdge), PixelBlock(7, 7, 10, 5, ArcadePalette.screen),
            PixelBlock(17, 14, 1, 1, signal), PixelBlock(6, 14, 2, 1, outline)
        ]
    }

    private var idle: [PixelBlock] {
        // A blinking `>_` gives the otherwise still pet a small, familiar life sign.
        [
            PixelBlock(8, 8, 1, 1, ArcadePalette.signal), PixelBlock(9, 9, 1, 1, ArcadePalette.signal),
            PixelBlock(8, 10, 1, 1, ArcadePalette.signal),
            PixelBlock(11, 10, pulse ? 3 : 1, 1, ArcadePalette.signal)
        ]
    }

    private var writing: [PixelBlock] {
        // Alternating cursor strokes make file-changing tool calls distinct
        // from ordinary command execution on the tiny terminal screen.
        [
            PixelBlock(8, 8, pulse ? 5 : 3, 1, ArcadePalette.mint),
            PixelBlock(8, 10, pulse ? 2 : 5, 1, ArcadePalette.signal)
        ]
    }

    private var hello: [PixelBlock] {
        [
            PixelBlock(10, 1, 1, 1, ArcadePalette.mint), PixelBlock(12, 1, 1, 1, ArcadePalette.mint),
            PixelBlock(2, 5, 1, 1, ArcadePalette.teal), PixelBlock(21, 5, 1, 1, ArcadePalette.teal),
            PixelBlock(1, 16, 1, 1, ArcadePalette.blue), PixelBlock(22, 16, 1, 1, ArcadePalette.blue),
            bootGlyph(color: ArcadePalette.mint)
        ]
    }

    private var thinking: [PixelBlock] {
        let scanX = 7 + (frame % 8)
        return [
            PixelBlock(8, 8, 1, 1, ArcadePalette.signal), PixelBlock(9, 9, 1, 1, ArcadePalette.signal),
            PixelBlock(8, 10, 1, 1, ArcadePalette.signal), PixelBlock(11, 10, 3, 1, ArcadePalette.signal),
            PixelBlock(scanX, 8, 2, 1, ArcadePalette.signal.opacity(0.72)),
            PixelBlock(scanX, 10, 1, 1, ArcadePalette.signal.opacity(0.45)),
            PixelBlock(21, 8 + (frame % 3), 1, 1, ArcadePalette.teal)
        ]
    }

    private var completed: [PixelBlock] {
        let sparkle = pulse ? ArcadePalette.mint : ArcadePalette.blue
        return [
            PixelBlock(9, 9, 1, 1, ArcadePalette.mint), PixelBlock(10, 10, 1, 1, ArcadePalette.mint),
            PixelBlock(11, 11, 1, 1, ArcadePalette.mint), PixelBlock(12, 10, 2, 1, ArcadePalette.mint),
            PixelBlock(1, 6, 1, 1, sparkle), PixelBlock(22, 7, 1, 1, sparkle),
            PixelBlock(3, 17, 1, 1, ArcadePalette.teal), PixelBlock(20, 17, 1, 1, ArcadePalette.teal)
        ]
    }

    private var error: [PixelBlock] {
        let glitch = pulse ? ArcadePalette.signal : ArcadePalette.blue
        return [
            PixelBlock(8, 8, 2, 1, ArcadePalette.signal), PixelBlock(13, 8, 2, 1, ArcadePalette.signal),
            PixelBlock(9, 10, 1, 1, ArcadePalette.signal), PixelBlock(12, 10, 1, 1, ArcadePalette.signal),
            PixelBlock(6, 12, 12, 1, ArcadePalette.signal), PixelBlock(2, 11, 3, 1, glitch),
            PixelBlock(20, 13, 3, 1, glitch)
        ]
    }

    private var approval: [PixelBlock] {
        let scan = 7 + (frame % 7)
        return [
            PixelBlock(10, 8, 4, 1, ArcadePalette.amber), PixelBlock(10, 9, 1, 2, ArcadePalette.amber),
            PixelBlock(13, 9, 1, 2, ArcadePalette.amber), PixelBlock(scan, 11, 2, 1, ArcadePalette.amber),
            PixelBlock(2, 9, 1, 1, ArcadePalette.amber), PixelBlock(21, 9, 1, 1, ArcadePalette.amber)
        ]
    }

    private var input: [PixelBlock] {
        [
            PixelBlock(8, 8, 1, 1, ArcadePalette.magenta), PixelBlock(9, 9, 1, 1, ArcadePalette.magenta),
            PixelBlock(8, 10, 1, 1, ArcadePalette.magenta), PixelBlock(11, 10, 3, 1, ArcadePalette.magenta),
            PixelBlock(18, 4, 4, 3, ArcadePalette.magenta), PixelBlock(19, 7, 1, 1, ArcadePalette.magenta),
            PixelBlock(19, 5, 1, 1, ArcadePalette.screen)
        ]
    }

    private var confirmation: [PixelBlock] {
        let seal = pulse ? ArcadePalette.violet : ArcadePalette.mint
        return [
            PixelBlock(9, 8, 6, 1, seal), PixelBlock(9, 9, 1, 3, seal), PixelBlock(14, 9, 1, 3, seal),
            PixelBlock(10, 10, 1, 1, seal), PixelBlock(11, 11, 1, 1, seal), PixelBlock(12, 10, 2, 1, seal)
        ]
    }

    private var disconnected: [PixelBlock] {
        let flicker = pulse ? ArcadePalette.inactive : ArcadePalette.blue.opacity(0.4)
        return [PixelBlock(7, 9, 10, 1, flicker), PixelBlock(11, 10, 2, 1, flicker), PixelBlock(2, 8, 1, 1, flicker)]
    }

    private var voiceError: [PixelBlock] {
        [PixelBlock(9, 8, 2, 1, ArcadePalette.signal), PixelBlock(13, 8, 2, 1, ArcadePalette.signal),
         PixelBlock(11, 10, 2, 2, ArcadePalette.signal), PixelBlock(10, 1, 3, 1, ArcadePalette.signal)]
    }

    private func bootGlyph(color: Color) -> PixelBlock {
        PixelBlock(8, 8, 8, 1, color)
    }
}
