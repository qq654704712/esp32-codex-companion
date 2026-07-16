import CodexCompanionCore
import SwiftUI

struct SimulatorRootView: View {
    @State private var model = SimulatorModel()

    var body: some View {
        HStack(spacing: 24) {
            DeviceDisplayView(model: model)
                .frame(width: 360, height: 360)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

            Form {
                Picker("状态", selection: $model.deviceState) {
                    ForEach(DeviceState.allCases, id: \.self) { state in
                        Text(state.rawValue).tag(state)
                    }
                }
                Toggle("5 小时额度可用", isOn: $model.fiveHourAvailable)
                Slider(value: $model.fiveHourPercent, in: 0...100) {
                    Text("5 小时剩余")
                }
                Toggle("一周额度可用", isOn: $model.weekAvailable)
                Slider(value: $model.weekPercent, in: 0...100) {
                    Text("一周剩余")
                }
                Toggle("额度已过期", isOn: $model.stale)
                Slider(value: $model.audioLevel, in: 0...1) {
                    Text("麦克风 RMS")
                }
            }
            .formStyle(.grouped)
            .frame(width: 250)
        }
        .padding(24)
    }
}
