import AppKit
import CodexCompanionCore
import Network
import SwiftUI

@main
enum CodexCompanionEntry {
    static func main() {
        // The launch agent executes the binary inside this very App Bundle.
        // macOS therefore evaluates Accessibility consent against the same
        // bundle the user sees in System Settings, rather than against an
        // unrelated helper executable under Application Support.
        if CommandLine.arguments.contains("--daemon") {
            // NetService publication is subject to macOS local-network privacy
            // policy. A launch agent still needs an NSApplication instance so
            // the signed bundle can own that permission and Bonjour callbacks.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let agent = MainActor.assumeIsolated {
                let agent = CompanionAgent.live()
                agent.start()
                return agent
            }
            withExtendedLifetime(agent) { RunLoop.main.run() }
            return
        }
        CodexCompanionApp.main()
    }
}

@MainActor
final class CodexCompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var localNetworkProbe: NWBrowser?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        requestLocalNetworkAuthorization()
    }

    /// A launchd agent is intentionally not allowed to put a consent alert in
    /// front of the user. The visible app performs a harmless Bonjour browse
    /// instead, which lets macOS present and persist Local Network consent for
    /// the same signed bundle before the device needs Wi-Fi discovery.
    private func requestLocalNetworkAuthorization() {
        let browser = NWBrowser(
            for: .bonjour(type: "_codex-companion._tcp", domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { state in
            if case .waiting(let error) = state {
                FileHandle.standardError.write(
                    Data("[Codex Wi-Fi] local-network permission pending: \(error)\\n".utf8)
                )
            }
        }
        localNetworkProbe = browser
        browser.start(queue: .main)
    }
}

struct CodexCompanionApp: App {
    @NSApplicationDelegateAdaptor(CodexCompanionAppDelegate.self) private var appDelegate
    @StateObject private var model = CompanionAppModel()

    var body: some Scene {
        WindowGroup("Codex Companion", id: "companion") {
            CompanionRootView(model: model)
                .frame(minWidth: 900, minHeight: 620)
                .task { model.start() }
        }
        .windowResizability(.contentSize)

        Settings {
            CompanionSettingsView(model: model)
                .frame(width: 500, height: 310)
        }
    }
}
