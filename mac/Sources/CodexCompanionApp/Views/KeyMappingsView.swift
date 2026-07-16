import CodexCompanionCore
import SwiftUI

struct KeyMappingsView: View {
    @ObservedObject var model: CompanionAppModel
    @State private var selectedID: String?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                        Text(shortcutText(profile.startShortcut))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(profile.id)
                }
            }
            .frame(width: 250)
            .toolbar {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        selectedID = model.addProfile()
                    } label: {
                        Label("添加配置", systemImage: "plus")
                    }
                    Button(role: .destructive) {
                        if let selectedID { model.removeProfile(id: selectedID) }
                        selectedID = model.profiles.first?.id
                    } label: {
                        Label("删除配置", systemImage: "trash")
                    }
                    .disabled(selectedID == nil)
                }
            }

            Divider()

            if let selectedID, let binding = model.profileBinding(for: selectedID) {
                VoiceProfileEditor(
                    profile: binding,
                    inputSources: model.inputSources,
                    isRecording: model.isRecordingShortcut,
                    onRecordStart: { model.recordStartShortcut(for: selectedID) },
                    onRecordStop: { model.recordStopShortcut(for: selectedID) }
                )
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "没有按键配置",
                    systemImage: "keyboard",
                    description: Text("添加一个配置，或使用默认的 BOOT → Fn 映射。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = model.profiles.first?.id }
        }
        .navigationTitle("按键映射")
    }
}

private struct VoiceProfileEditor: View {
    @Binding var profile: VoiceShortcutProfile
    let inputSources: [InputSourceDescriptor]
    let isRecording: Bool
    let onRecordStart: () -> Void
    let onRecordStop: () -> Void

    var body: some View {
        ScrollView {
            Form {
                Section("配置") {
                    TextField("名称", text: $profile.displayName)
                    Toggle("启用此配置", isOn: $profile.isEnabled)
                    Picker("触发方式", selection: $profile.triggerMode) {
                        Text("按住").tag(VoiceTriggerMode.hold)
                        Text("按下/松开各触发一次").tag(VoiceTriggerMode.togglePair)
                        Text("独立停止快捷键").tag(VoiceTriggerMode.separate)
                    }
                    Picker("匹配规则", selection: $profile.matchPolicy) {
                        Text("始终使用").tag(VoiceProfileMatchPolicy.always)
                        Text("仅当前输入法").tag(VoiceProfileMatchPolicy.activeInputSource)
                    }
                }
                
                Section("输入法") {
                    Picker("绑定输入法", selection: inputSourceBinding) {
                        Text("不切换输入法").tag("")
                        ForEach(inputSources, id: \.id) { source in
                            Text(source.localizedName).tag(source.id)
                        }
                    }
                    Toggle("结束后恢复原输入法", isOn: $profile.restoreInputSource)
                }

                Section("快捷键") {
                    LabeledContent("开始") { Text(shortcutText(profile.startShortcut)) }
                    Button(isRecording ? "请按下快捷键…" : "录制开始快捷键", action: onRecordStart)
                        .disabled(isRecording)
                    if profile.triggerMode == .separate {
                        LabeledContent("停止") { Text(shortcutText(profile.stopShortcut)) }
                        Button(isRecording ? "请按下快捷键…" : "录制停止快捷键", action: onRecordStop)
                            .disabled(isRecording)
                    }
                }

                Section("时序") {
                    Stepper("预录 \(profile.preRollMs) ms", value: $profile.preRollMs, in: 0...2_000, step: 50)
                    Stepper("尾音 \(profile.postRollMs) ms", value: $profile.postRollMs, in: 0...2_000, step: 50)
                    Stepper("提交宽限 \(profile.commitGraceMs) ms", value: $profile.commitGraceMs, in: 0...10_000, step: 250)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
            .padding(18)
        }
        .scrollIndicators(.automatic)
    }

    private var inputSourceBinding: Binding<String> {
        Binding(
            get: { profile.inputSourceIDs.first ?? "" },
            set: { profile.inputSourceIDs = $0.isEmpty ? [] : [$0] }
        )
    }
}
