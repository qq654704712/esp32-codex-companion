import AppKit
import CodexCompanionCore
import SwiftUI

struct CompanionDashboardView: View {
    @ObservedObject var model: CompanionAppModel
    @ObservedObject private var service: CompanionService

    init(model: CompanionAppModel) {
        self.model = model
        _service = ObservedObject(wrappedValue: model.service)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("连接中心")
                        .font(.largeTitle.weight(.semibold))
                    Text("可在不同电脑之间切换。USB 提供标准麦克风；BLE/Wi-Fi 通过 Companion 协议提供控制、状态和无线语音。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("选择 Companion 设备") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("搜索附近设备") {
                                service.discoverCompanionDevices()
                            }
                            Button("忘记当前选择") {
                                service.forgetSelectedCompanionDevice()
                            }
                            .disabled(service.selectedBLEDeviceID == nil)
                            Spacer()
                            Text(service.selectedBLEDeviceID == nil ? "未选择" : "已记住设备")
                                .foregroundStyle(.secondary)
                        }
                        if service.discoveredBLEDevices.isEmpty {
                            Text("点击搜索后，在设备上进入“连接 → 配对其他设备”，再从列表中选择。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(service.discoveredBLEDevices) { device in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                        Text("\(device.id.uuidString) · RSSI \(device.rssi)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(
                                        service.selectedBLEDeviceID == device.id ? "已选择" : "选择并连接"
                                    ) {
                                        service.selectCompanionDevice(id: device.id)
                                    }
                                    .disabled(service.selectedBLEDeviceID == device.id && service.bleState == .connected)
                                }
                                Divider()
                            }
                        }
                        Text("更换电脑时，需要在设备端长按“配对其他设备”清除旧主机密钥；USB 音频可直接连接任何支持标准 UAC 麦克风的主机，Codex 状态与快捷键需要对应平台的 Companion 客户端。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    StatusCard(
                        title: "USB（当前优先）",
                        value: model.backgroundAgentStatus?.usbDescription ?? service.usbControlState.displayName,
                        symbol: "cable.connector",
                        healthy: {
                            (model.backgroundAgentStatus?.usbDescription ?? service.usbControlState.displayName)
                                .hasPrefix("已连接")
                        }()
                    )
                    StatusCard(
                        title: "BLE",
                        value: model.backgroundAgentStatus?.bleDescription ?? bleStateText(service.bleState),
                        symbol: "dot.radiowaves.left.and.right",
                        healthy: model.backgroundAgentStatus?.bleDescription == "已连接" || service.bleState == .connected
                    )
                    StatusCard(
                        title: "Wi-Fi 日常连接",
                        value: model.backgroundAgentStatus?.wifiDescription ?? "后台状态读取中",
                        symbol: "wifi",
                        healthy: model.backgroundAgentStatus?.wifiDescription == "已连接"
                    )
                    StatusCard(
                        title: "后台代理",
                        value: model.backgroundAgentStatus?.lifecycle == .running ? "正在运行" : "未检测到",
                        symbol: "bolt.horizontal.circle",
                        healthy: model.backgroundAgentStatus?.lifecycle == .running
                    )
                    StatusCard(
                        title: "Codex Mic",
                        value: service.codexMicAvailable ? "可用" : "未安装",
                        symbol: "mic.fill",
                        healthy: service.codexMicAvailable
                    )
                    StatusCard(
                        title: "Codex 输入框（最近检测）",
                        value: service.codexComposerAvailable ? "可触发" : "未聚焦",
                        symbol: "text.cursor",
                        healthy: service.codexComposerAvailable
                    )
                }

                GroupBox("本次语音") {
                    LabeledContent("活动配置") {
                        Text(service.activeVoiceProfileName ?? "等待 BOOT")
                    }
                    LabeledContent("当前输入法") {
                        Text(model.inputSources.first(where: { $0.id == model.activeInputSourceID })?.localizedName ?? "未知")
                    }
                    LabeledContent("辅助功能") {
                        Text(service.accessibilityAvailable ? "已授权" : "需要授权")
                    }
                    if !service.accessibilityAvailable {
                        Button("请求辅助功能授权") {
                            service.requestAccessibilityPermission()
                        }
                    }
                    LabeledContent("输入框检测时间") {
                        Text(composerCheckText)
                    }
                    if let error = service.lastVoiceError {
                        Divider()
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                GroupBox("Codex 工作状态（本机日志）") {
                    LabeledContent("状态") {
                        Text(stateText(model.backgroundAgentStatus?.codexState ?? service.observedCodexState))
                    }
                    LabeledContent("详情") {
                        Text(model.backgroundAgentStatus?.codexDetail ?? service.observedCodexDetail)
                    }
                    Text("直接读取本机 Codex Rollout 日志；无需安装 Hook，Companion 启动后会恢复当前会话状态。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                GroupBox("使用方式") {
                    Text("将第三方输入法的语音快捷键配置为 Fn，或在“按键映射”中录制该输入法要求的普通组合键。USB 模式下，长按 BOOT 会选择“Codex Companion USB Mic”并按住该快捷键。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Wi-Fi 配网备用路径") {
                    Text("设备网页会优先自动发现所选主机。若网络禁用 Bonjour 组播，可把下面地址填入设备网页的主机 IPv4 备用地址。")
                        .foregroundStyle(.secondary)
                    if let address = CompanionLANEndpoint.preferredIPv4Address() {
                        HStack {
                            Text("\(address):\(WiFiControlServer.defaultPort)")
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    address,
                                    forType: .string
                                )
                            }
                        }
                    } else {
                        Text("未找到可用的局域网 IPv4 地址")
                            .foregroundStyle(.orange)
                    }
                    Button("打开本地网络授权") {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("连接中心")
    }

    private var composerCheckText: String {
        guard let date = service.codexComposerCheckedAt else { return "尚未在 Codex 前台检测" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func stateText(_ state: DeviceState) -> String {
        switch state {
        case .idle: "空闲"
        case .sessionStarting: "会话开始"
        case .working: "思考中"
        case .writing: "回复中"
        case .running: "执行工具"
        case .completed: "已完成"
        case .error, .voiceError: "错误"
        case .approvalRequired: "等待审批"
        case .inputRequired: "等待输入"
        case .confirmationRequired: "等待确认"
        case .listening: "语音输入"
        case .disconnected: "未连接"
        }
    }
}

private struct StatusCard: View {
    let title: String
    let value: String
    let symbol: String
    let healthy: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(healthy ? .green : .orange)
                Text(title).font(.headline)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }
}
