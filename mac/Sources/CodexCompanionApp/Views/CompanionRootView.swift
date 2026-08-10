import CodexCompanionCore
import SwiftUI

struct CompanionRootView: View {
    @ObservedObject var model: CompanionAppModel
    @State private var selection: AppSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Codex Companion") {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                Section("运行状态") {
                    Label(
                        model.isAnyRuntimeRunning ? "Companion 正在运行" : "Companion 未运行",
                        systemImage: model.isAnyRuntimeRunning ? "checkmark.circle.fill" : "xmark.circle"
                    )
                    .foregroundStyle(model.isAnyRuntimeRunning ? .green : .secondary)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Codex Companion")
        } detail: {
            Group {
                switch selection ?? .dashboard {
                case .dashboard:
                    CompanionDashboardView(model: model)
                case .weather:
                    WeatherConfigurationView(model: model)
                case .keyMappings:
                    KeyMappingsView(model: model)
                case .audio:
                    AudioDiagnosticsView(model: model)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.refresh()
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                    Button {
                        model.service.reconnect()
                    } label: {
                        Label("重新连接", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .disabled(!model.isAnyRuntimeRunning)
                }
            }
        }
        .alert("Codex Companion", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
