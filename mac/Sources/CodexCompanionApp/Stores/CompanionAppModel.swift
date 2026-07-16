import CodexCompanionCore
import Combine
import Foundation
import SwiftUI

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published var profiles: [VoiceShortcutProfile] = []
    @Published var inputSources: [InputSourceDescriptor] = []
    @Published var activeInputSourceID: String?
    @Published var errorMessage: String?
    @Published var isRecordingShortcut = false
    @Published var backgroundAgentStatus: CompanionRuntimeStatus?

    let service: CompanionService
    private let profileStore: VoiceProfileStore
    private let inputSourceCatalog: InputSourceCatalog
    private var statusPoller: Timer?

    init(
        service: CompanionService = CompanionService(),
        profileStore: VoiceProfileStore = VoiceProfileStore(),
        inputSourceCatalog: InputSourceCatalog = InputSourceCatalog()
    ) {
        self.service = service
        self.profileStore = profileStore
        self.inputSourceCatalog = inputSourceCatalog
        refresh()
    }

    func start() {
        service.start()
        refresh()
        refreshBackgroundAgentStatus()
        guard statusPoller == nil else { return }
        statusPoller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBackgroundAgentStatus() }
        }
    }

    func refresh() {
        inputSources = inputSourceCatalog.installed()
        activeInputSourceID = inputSourceCatalog.currentInputSourceID()
        service.refreshHostStatus()
        do {
            profiles = try profileStore.load().sorted { $0.displayName < $1.displayName }
            if profiles.isEmpty {
                profiles = [VoiceShortcutProfile(
                    id: UUID().uuidString,
                    displayName: "BOOT → Fn",
                    matchPolicy: .always,
                    triggerMode: .hold,
                    startShortcut: VoiceShortcutProfile.bootFnDefault.startShortcut,
                    preRollMs: 0,
                    postRollMs: 200,
                    restoreInputSource: false
                )]
                persist()
            }
            errorMessage = nil
        } catch {
            errorMessage = "无法读取按键配置：\(error.localizedDescription)"
        }
    }

    var isAnyRuntimeRunning: Bool {
        service.isRunning || backgroundAgentStatus?.lifecycle == .running
    }

    func refreshBackgroundAgentStatus() {
        backgroundAgentStatus = try? AgentStatusFile.read()
    }

    func profileBinding(for id: String) -> Binding<VoiceShortcutProfile>? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                guard let self,
                      let profile = self.profiles.first(where: { $0.id == id }) else {
                    return VoiceShortcutProfile.bootFnDefault
                }
                return profile
            },
            set: { [weak self] profile in self?.update(profile) }
        )
    }

    func addProfile() -> String {
        let profile = VoiceShortcutProfile(
            id: UUID().uuidString,
            displayName: "新语音快捷键",
            matchPolicy: .always,
            triggerMode: .hold,
            startShortcut: VoiceShortcutProfile.bootFnDefault.startShortcut,
            restoreInputSource: false
        )
        profiles.append(profile)
        update(profile)
        return profile.id
    }

    func removeProfile(id: String) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    func update(_ profile: VoiceShortcutProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    func recordStartShortcut(for id: String) {
        recordShortcut(for: id, isStop: false)
    }

    func recordStopShortcut(for id: String) {
        recordShortcut(for: id, isStop: true)
    }

    private func recordShortcut(for id: String, isStop: Bool) {
        isRecordingShortcut = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isRecordingShortcut = false }
            do {
                let shortcut = try ShortcutRecorder().record()
                guard var profile = self.profiles.first(where: { $0.id == id }) else { return }
                if isStop {
                    profile.stopShortcut = shortcut
                } else {
                    profile.startShortcut = shortcut
                }
                self.update(profile)
            } catch {
                self.errorMessage = "快捷键录制失败：\(error.localizedDescription)"
            }
        }
    }

    private func persist() {
        do {
            try profileStore.save(profiles)
            errorMessage = nil
        } catch {
            errorMessage = "保存配置失败：\(error.localizedDescription)"
        }
    }
}
