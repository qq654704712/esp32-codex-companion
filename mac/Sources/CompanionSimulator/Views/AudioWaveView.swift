import SwiftUI

struct AudioWaveView: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<19, id: \.self) { index in
                    let oscillation = (sin(time * 9 + Double(index) * 0.67) + 1) / 2
                    Rectangle()
                        .fill(index.isMultiple(of: 4) ? ArcadePalette.magenta : (index.isMultiple(of: 3) ? ArcadePalette.blue : ArcadePalette.teal))
                        .frame(width: 6, height: 10 + 94 * level * oscillation)
                }
            }
            .shadow(color: ArcadePalette.blue.opacity(0.70), radius: 6)
        }
    }
}
