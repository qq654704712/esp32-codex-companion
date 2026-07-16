import CodexCompanionCore
import Foundation

private enum CLIError: LocalizedError {
    case usage(String)
    case cancelled
    case unknownProfile(String)
    case unsupportedHook

    var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .cancelled: "操作已取消"
        case .unknownProfile(let id): "未找到配置档：\(id)"
        case .unsupportedHook: "Hook 事件无效或当前不支持"
        }
    }
}

private let encoder: JSONEncoder = {
    let value = JSONEncoder()
    value.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return value
}()

private func printJSON<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func prompt(_ text: String) throws -> String {
    FileHandle.standardError.write(Data(text.utf8))
    guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !line.isEmpty else { throw CLIError.cancelled }
    return line
}

private func recordProfile() throws {
    let catalog = InputSourceCatalog()
    let sources = catalog.installed()
    print("0: 全局配置（不绑定输入来源）")
    for (index, source) in sources.enumerated() {
        print("\(index + 1): \(source.localizedName) [\(source.id)]")
    }
    let selection = Int(try prompt("选择输入来源编号: ")) ?? -1
    guard selection >= 0, selection <= sources.count else {
        throw CLIError.usage("输入来源编号无效")
    }
    let name = try prompt("配置档名称: ")
    print("请按下输入法的语音启动快捷键…")
    let start = try ShortcutRecorder().record()
    let selectedSource = selection == 0 ? nil : sources[selection - 1]
    let useAsDefault: Bool
    if selectedSource != nil {
        useAsDefault = try prompt("无精确匹配时是否切换到此输入法作为默认档案？YES / NO: ").uppercased() == "YES"
    } else {
        useAsDefault = false
    }
    var profile = VoiceShortcutProfile(
        id: UUID().uuidString,
        displayName: name,
        matchPolicy: selectedSource == nil || useAsDefault ? .always : .activeInputSource,
        inputSourceIDs: selectedSource.map { [$0.id] } ?? [],
        triggerMode: .hold,
        startShortcut: start
    )
    try calibrateProfile(&profile)
    let store = VoiceProfileStore()
    var profiles = try store.load()
    profiles.append(profile)
    try store.save(profiles)
    try printJSON(profile)
    print("配置已保存且校准通过。")
}

private func calibrateProfile(_ profile: inout VoiceShortcutProfile) throws {
    profile.triggerMode = .hold
    profile.stopShortcut = nil
    print("向导先测试 hold。")
    try exerciseShortcut(profile)
    var calibrated = try prompt("是否已开始、停止并提交？YES / NO: ").uppercased() == "YES"
    if !calibrated {
        profile.triggerMode = .togglePair
        print("继续测试 togglePair。")
        try exerciseShortcut(profile)
        calibrated = try prompt("当前模式是否成功？YES / NO: ").uppercased() == "YES"
    }
    if !calibrated {
        profile.triggerMode = .separate
        print("请按下输入法的语音停止快捷键…")
        profile.stopShortcut = try ShortcutRecorder().record()
        print("最后测试 separate。")
        try exerciseShortcut(profile)
        guard try prompt("独立停止快捷键是否成功？输入 YES 确认: ") == "YES" else {
            throw CLIError.cancelled
        }
    }
}

private func editProfile(id: String) throws {
    let store = VoiceProfileStore()
    var profiles = try store.load()
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        throw CLIError.unknownProfile(id)
    }
    var profile = profiles[index]
    print("重新录制 \(profile.displayName) 的语音启动快捷键…")
    profile.startShortcut = try ShortcutRecorder().record()
    try calibrateProfile(&profile)
    profiles[index] = profile
    try store.save(profiles)
    try printJSON(profile)
    print("配置已更新且校准通过。")
}

private func exerciseShortcut(_ profile: VoiceShortcutProfile) throws {
    let emitter = CGEventShortcutEmitter()
    print("3 秒后发送启动快捷键，请把光标放到安全的测试文本框。")
    Thread.sleep(forTimeInterval: 3)
    switch profile.triggerMode {
    case .hold:
        try emitter.press(profile.startShortcut)
        Thread.sleep(forTimeInterval: 1.5)
        try emitter.release(profile.startShortcut)
    case .togglePair:
        try emitter.tap(profile.startShortcut)
        Thread.sleep(forTimeInterval: 1.5)
        try emitter.tap(profile.startShortcut)
    case .separate:
        guard let stop = profile.stopShortcut else { throw CLIError.usage("缺少停止快捷键") }
        try emitter.tap(profile.startShortcut)
        Thread.sleep(forTimeInterval: 1.5)
        try emitter.tap(stop)
    }
}

private func testProfile(id: String) throws {
    let profile = try VoiceProfileStore().load().first { $0.id == id }
    guard let profile else { throw CLIError.unknownProfile(id) }
    try exerciseShortcut(profile)
    let confirmation = try prompt("输入法是否已成功开始、停止并提交？输入 YES 确认: ")
    guard confirmation == "YES" else { throw CLIError.cancelled }
    print("校准通过。若独立 Fn 无法被输入法接收，请在输入法中改用普通组合键后重新录制。")
}

private func profileCommand(_ arguments: ArraySlice<String>) throws {
    guard let action = arguments.first else { throw CLIError.usage(help) }
    let store = VoiceProfileStore()
    switch action {
    case "list": try printJSON(store.load())
    case "record": try recordProfile()
    case "test":
        guard let id = arguments.dropFirst().first else { throw CLIError.usage("缺少配置档 ID") }
        try testProfile(id: id)
    case "edit":
        guard let id = arguments.dropFirst().first else { throw CLIError.usage("缺少配置档 ID") }
        try editProfile(id: id)
    case "enable", "disable":
        guard let id = arguments.dropFirst().first else { throw CLIError.usage("缺少配置档 ID") }
        var profiles = try store.load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CLIError.unknownProfile(id)
        }
        profiles[index].isEnabled = action == "enable"
        try store.save(profiles)
    case "rename":
        let values = arguments.dropFirst()
        guard let id = values.first, let name = values.dropFirst().first else {
            throw CLIError.usage("用法：profile rename <id> <name>")
        }
        var profiles = try store.load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw CLIError.unknownProfile(id)
        }
        profiles[index].displayName = name
        try store.save(profiles)
    case "remove":
        guard let id = arguments.dropFirst().first else { throw CLIError.usage("缺少配置档 ID") }
        var profiles = try store.load()
        let originalCount = profiles.count
        profiles.removeAll { $0.id == id }
        guard profiles.count != originalCount else { throw CLIError.unknownProfile(id) }
        try store.save(profiles)
    case "export":
        guard let path = arguments.dropFirst().first else { throw CLIError.usage("缺少导出路径") }
        try encoder.encode(store.load()).write(to: URL(fileURLWithPath: path), options: .atomic)
    case "import":
        guard let path = arguments.dropFirst().first else { throw CLIError.usage("缺少导入路径") }
        let imported = try JSONDecoder().decode(
            [VoiceShortcutProfile].self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        try imported.forEach(VoiceProfileValidator.validate)
        var byID = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.id, $0) })
        imported.forEach { byID[$0.id] = $0 }
        try store.save(byID.values.sorted { $0.displayName < $1.displayName })
    default: throw CLIError.usage("未知 profile 子命令：\(action)")
    }
}

private func doctor() {
    print("Accessibility: \(CGEventShortcutEmitter.isAccessibilityTrusted ? "OK" : "MISSING")")
    let audio = SystemCoreAudioRoutingAPI()
    let micFound = (try? audio.deviceID(named: CodexMicRouteManager.usbMicrophoneName)) != nil ||
        (try? audio.deviceID(uid: CodexMicRouteManager.deviceUID)) != nil
    print("Codex Mic: \(micFound ? "OK" : "NOT INSTALLED")")
    let count = (try? VoiceProfileStore().load().count) ?? 0
    print("Voice profiles: \(count)")
    let snapshot = CodexAccessibilityInspector().focusedElement()
    print("Codex composer focused: \(CodexInteractionGate().allowsVoiceInput(snapshot) ? "YES" : "NO")")
}

private let help = """
Codex Companion

  codex-companion quota
  codex-companion input-sources
  codex-companion profile list
  codex-companion profile record
  codex-companion profile test <id>
  codex-companion profile edit <id>
  codex-companion profile enable|disable <id>
  codex-companion profile rename <id> <name>
  codex-companion profile remove <id>
  codex-companion profile import <json>
  codex-companion profile export <json>
  codex-companion hook            # Codex Hook JSON from stdin
  codex-companion daemon          # BLE、额度、Hooks 与 PTT 常驻服务
  codex-companion doctor
"""

do {
    let arguments = CommandLine.arguments.dropFirst()
    guard let command = arguments.first else { throw CLIError.usage(help) }
    switch command {
    case "quota": try printJSON(CodexAppServerClient().readQuota())
    case "input-sources": try printJSON(InputSourceCatalog().installed())
    case "profile": try profileCommand(arguments.dropFirst())
    case "hook":
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard CodexHookEventParser.parse(data) != nil else { throw CLIError.unsupportedHook }
        try HookInbox().enqueue(data)
    case "daemon":
        // A command-line executable has no application event loop. Scheduling
        // this setup in an unowned Task and immediately calling dispatchMain()
        // can leave the task unrun, so CoreBluetooth never begins scanning.
        // The CLI starts on the main thread; create the main-actor service
        // synchronously, then keep that same main run loop alive.
        let agent = MainActor.assumeIsolated { () -> CompanionAgent in
            let agent = CompanionAgent.live()
            agent.start()
            return agent
        }
        FileHandle.standardError.write(Data("[Codex Companion] daemon started\n".utf8))
        withExtendedLifetime(agent) { RunLoop.main.run() }
    case "doctor": doctor()
    case "help", "--help", "-h": print(help)
    default: throw CLIError.usage("未知命令：\(command)\n\n\(help)")
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8))
    exit(1)
}
