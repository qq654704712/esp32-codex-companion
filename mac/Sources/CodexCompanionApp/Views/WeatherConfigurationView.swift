import SwiftUI

struct WeatherConfigurationView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("天气同步")
                        .font(.largeTitle.weight(.semibold))
                    Text("设置城市后，Mac 会获取实时天气，并通过当前可用的 USB、蓝牙或 Wi‑Fi 连接同步到设备。")
                        .foregroundStyle(.secondary)
                }

                WeatherConfigurationForm(model: model)
                    .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("天气同步")
        .onAppear { model.refresh() }
    }
}

struct WeatherConfigurationForm: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        Form {
            Section("位置") {
                TextField("城市", text: $model.weatherCity, prompt: Text("例如：上海、北京、深圳"))
                Text("支持中文或英文城市名；城市信息只保存在本机。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("同步选项") {
                Toggle("同步天气", isOn: $model.weatherEnabled)
                Picker("温度单位", selection: $model.weatherUsesCelsius) {
                    Text("摄氏 °C").tag(true)
                    Text("华氏 °F").tag(false)
                }
                Picker("更新频率", selection: $model.weatherRefreshMinutes) {
                    Text("15 分钟").tag(UInt8(15))
                    Text("30 分钟").tag(UInt8(30))
                    Text("60 分钟").tag(UInt8(60))
                }
            }

            Section("状态") {
                LabeledContent("天气服务") {
                    Text(model.service.weatherStatus)
                        .foregroundStyle(.secondary)
                }
                Button("保存并立即同步") {
                    model.saveWeatherConfiguration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.weatherEnabled &&
                          model.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("保存后，后台 Companion 服务会立即刷新天气；设备当前通过 Wi‑Fi 连接时不需要重新插拔 USB。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
