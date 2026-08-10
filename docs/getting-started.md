# Getting Started

本文把 README 的快速路径展开为可复制的安装、配对、运行和恢复步骤。当前项目面向 macOS + Waveshare ESP32-S3-Touch-LCD-1.85B；Linux/Windows 可以复用 `protocol/`，但仓库没有提供对应的 Companion 客户端。

## 1. 安装开发工具

### macOS Companion

安装 Xcode（包含 Swift 6 工具链）和命令行工具，确认：

```bash
xcode-select -p
swift --version
```

`mac/Package.swift` 要求 macOS 14.0。第一次构建只需要 Swift 依赖，不会自动下载或安装驱动。

### ESP32 固件

安装 ESP-IDF 6.0.2 及其工具链。可以把 IDF 和工具链放在仓库外的任意位置：

```bash
export IDF_PATH=/opt/esp-idf-v6.0.2
export IDF_TOOLS_PATH=/opt/idf-tools-v6
source "$IDF_PATH/export.sh"
```

仓库中的 `firmware/build.sh` 只负责配置并构建，不替用户安装 SDK、下载工具或选择串口。

## 2. 先验证不接硬件的部分

```bash
./firmware/host_tests/run.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path mac
```

这两步覆盖协议编码、配对状态机、音频路由、连接中心模型、Swift 集成测试和 UI 布局静态检查。通过它们不等于真实设备验收。

## 3. 运行 macOS Companion

### 只读诊断

```bash
swift run --package-path mac codex-companion doctor
```

诊断会显示 Accessibility、`Codex Mic`、快捷键配置数量和当前焦点是否像 Codex composer。没有连接设备时，`NOT INSTALLED` 或 `MISSING` 是预期结果。

### 构建 GUI 和 daemon

```bash
./script/build_and_run.sh run
```

脚本会构建 `CodexCompanion.app` 和 CLI、安装用户级 LaunchAgent 并启动应用。首次使用时按 macOS 提示授予：

- Bluetooth：扫描和连接已配对 ESP32；
- Local Network：Bonjour 发现 Mac 和设备；
- Microphone：访问音频输入链路；
- Accessibility：发送用户录制的语音快捷键；
- Keychain：保存应用层配对密钥。

关闭 daemon 和保留配置：

```bash
./mac/scripts/uninstall-companion.sh
```

卸载脚本不会删除 Voice Profile 或 Keychain 配对密钥；换机或撤销密钥应在 Connection Center 中完成。

## 4. 构建、刷写和监视固件

```bash
export IDF_PATH=/opt/esp-idf-v6.0.2
export IDF_TOOLS_PATH=/opt/idf-tools-v6
./firmware/build.sh
```

构建成功后，根据你的串口运行：

```bash
source "$IDF_PATH/export.sh"
idf.py -C firmware -B build-v6.0.2 -p /dev/cu.usbmodemXXXX flash monitor
```

USB MIC 模式会占用同一 USB PHY。若设备不再出现串口，使用硬件恢复路径：

1. 断开设备电源；
2. 按住 BOOT；
3. 插入数据线；
4. 插入后立即松开 BOOT；
5. 重新运行 `idf.py ... flash monitor`。

不要等到刷写开始后才松开 BOOT，也不要在未退出 USB MIC 模式时假定串口一定存在。

## 5. Wi-Fi 配网和恢复配对

1. 打开设备 `LINK`，选择 `WI-FI SETUP (PHONE / MAC)`。
2. 用手机或 Mac 连接屏幕显示的一次性 WPA2 SoftAP。
3. 打开 `http://192.168.4.1`，填写 2.4 GHz Wi-Fi SSID/密码；如果局域网阻止组播，填写 Companion 显示的 Mac IPv4 fallback。
4. 回到 Companion 的 Connection Center，搜索附近设备并选择目标。
5. 两端显示短 SAS 后人工核对并确认；SAS 只用于检测中间人，不是可重复使用的密码。
6. 等待 Connection Center 同时显示主机、认证、麦克风和 Wi-Fi 状态为可用，再开始 PTT。

发现到的 mDNS 主机没有配对密钥时不能控制设备或接收音频。换 Mac、密钥失效或 BLE bond 异常时，在设备端长按 `RESET BLE PAIRING` 1.5 秒，再从步骤 4 重新配对。

## 6. 录制输入法快捷键

```bash
swift run --package-path mac codex-companion profile record
```

向导会让你选择输入来源、录制启动键并依次尝试 `hold`、`togglePair`、`separate`。请把光标放进不会造成破坏的测试文本框；确认输入法已经启动、停止和提交后再输入 `YES`。

配置管理：

```bash
swift run --package-path mac codex-companion profile list
swift run --package-path mac codex-companion profile export /tmp/voice-profiles.json
swift run --package-path mac codex-companion profile import /tmp/voice-profiles.json
```

导出文件包含快捷键和输入来源标识，只应保存在你信任的机器上，不要提交到公共仓库。

## 7. 可选：安装 Codex Hooks

Hooks 是可选集成，不影响设备作为普通无线麦克风使用。构建 CLI 后，把仓库作为本地 marketplace：

```bash
codex plugin marketplace add /path/to/esp32-codex-companion
codex plugin add codex-companion-hooks@codex-companion-local
```

重启 Codex 桌面应用，在 `/hooks` 中审核并信任 Hook 定义。若 `codex-companion` 不在 `PATH`，设置 `CODEX_COMPANION_BIN` 为构建出的绝对路径。Hook 转发失败时会安全退出，不应中断 Codex 工作。

## 常见问题

| 症状 | 处理 |
| --- | --- |
| `Codex Mic: NOT INSTALLED` | 先运行 `./script/build_and_run.sh run`，确认应用构建成功并重新运行 `doctor`。 |
| Connection Center 找不到设备 | 确认 Mac Local Network 权限、设备与 Mac 在同一局域网；在设备网页填写 Mac IPv4 fallback。 |
| Wi-Fi 显示已发现但不变成 `CONNECTED` | 重新完成恢复配对；发现本身不代表已认证。 |
| 输入法没有响应快捷键 | 在 Accessibility 中允许 Companion；重新运行 `profile record`，改用输入法明确支持的组合键。 |
| USB MIC 后没有串口 | 退出 USB MIC 并重启；仍无串口时执行上面的 BOOT 上电恢复流程。 |
| C 主机测试缺少 OpenSSL | 安装 OpenSSL 和 `pkg-config`，确认 `pkg-config --libs openssl` 能返回库参数。 |

更多硬件验收步骤见 [hardware-validation.md](hardware-validation.md)，协议实现见 [../protocol/README.md](../protocol/README.md)。
