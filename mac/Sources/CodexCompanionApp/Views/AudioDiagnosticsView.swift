import CodexCompanionCore
import SwiftUI

struct AudioDiagnosticsView: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject private var service: CompanionService

    init(model: CompanionAppModel) {
        self.model = model
        _service = ObservedObject(wrappedValue: model.service)
    }

    var body: some View {
        Form {
            Section("无线音频桥") {
                LabeledContent("设备") { Text("Codex Mic") }
                LabeledContent("格式") { Text("48 kHz · Float32 · 单声道") }
                LabeledContent("HAL 驱动") {
                    Label(service.codexMicAvailable ? "已安装" : "未安装",
                          systemImage: service.codexMicAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(service.codexMicAvailable ? .green : .red)
                }
                LabeledContent("BLE") { Text(bleStateText(service.bleState)) }
            }

            Section("故障信息") {
                if let error = service.lastVoiceError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("尚无语音错误")
                        .foregroundStyle(.secondary)
                }
            }

            Section("恢复") {
                Button("重新扫描并连接设备") { service.reconnect() }
                Button("重新检查音频与辅助功能权限") { model.refresh() }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle("音频诊断")
    }
}
