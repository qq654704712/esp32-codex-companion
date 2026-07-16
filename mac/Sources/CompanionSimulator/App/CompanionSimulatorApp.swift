import AppKit
import SwiftUI

final class SimulatorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct CompanionSimulatorApp: App {
    @NSApplicationDelegateAdaptor(SimulatorAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Codex Companion Simulator", id: "simulator") {
            SimulatorRootView()
                .frame(minWidth: 650, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}
