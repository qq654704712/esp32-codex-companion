import SwiftUI

struct CompanionSettingsView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        TabView {
            Form {
                LabeledContent("辅助功能") {
                    Text(model.service.accessibilityAvailable ? "已授权" : "需要在系统设置中授权")
                }
                LabeledContent("Codex Mic") {
                    Text(model.service.codexMicAvailable ? "已安装" : "未安装")
                }
                Text("本应用只在 Codex 输入框可访问时才会模拟快捷键，避免向其他应用误输入。")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("常规", systemImage: "gearshape") }

            Form {
                Text("设备通过自定义 BLE 控制和音频流连接；Codex Mic 是 macOS 的虚拟输入设备。按键映射请在主窗口的“按键映射”中设置。")
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding()
            .tabItem { Label("连接说明", systemImage: "info.circle") }
        }
    }
}
