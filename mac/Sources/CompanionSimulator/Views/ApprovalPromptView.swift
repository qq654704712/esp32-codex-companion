import SwiftUI

struct ApprovalPromptView: View {
    let options: [String]
    let selected: Int

    var body: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(ArcadePalette.amber)
                .frame(width: 28, height: 6)
                .overlay(Rectangle().fill(ArcadePalette.teal).frame(width: 8, height: 6).offset(x: -10))
            Text("需要审批")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.2)
            ScrollView(.vertical) {
                VStack(spacing: 5) {
                    ForEach(Array(options.prefix(8).enumerated()), id: \.offset) { index, option in
                        Text(option)
                            .font(.system(size: 12, weight: index == selected ? .bold : .regular))
                            .lineLimit(1)
                            .frame(width: 176, height: 27)
                            .background(index == selected ? ArcadePalette.forest : ArcadePalette.navy)
                            .overlay(Rectangle().stroke(index == selected ? ArcadePalette.magenta : ArcadePalette.inactive, lineWidth: 2))
                    }
                }
            }
            .frame(height: 96)
            Text("高风险选项长按 1.5 秒")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(ArcadePalette.violet.opacity(0.9))
        }
        .foregroundStyle(.white)
    }
}
