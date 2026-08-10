# ESP32-S3 Codex Companion

面向 Waveshare `ESP32-S3-Touch-LCD-1.85B` 的 Codex 桌面伴侣。项目没有绑定任何
输入法 SDK：设备提供 Wi-Fi/BLE 无线音频与 PTT 事件，macOS 暴露标准 `Codex Mic`
输入设备，并按用户录制的物理键码快捷键启动或停止当前第三方输入法的语音功能。

当前日常模式是 **Wi-Fi 状态/审批/PTT 控制 + 加密 UDP 麦克风 + 严格输入法兼容标识 + USB 原生备用**：
设备经局域网自动发现已配对的 Mac，控制和音频帧使用 CCH2 握手派生的独立 CCW2
ChaCha20-Poly1305 密钥；Wi-Fi 不可用时，下一次 PTT 会回退到 BLE ADPCM。需要
Mac 端 `Codex Mic` 使用已实测的 USB 兼容 transport 元数据，但音频仍全程来自
Wi-Fi，手持设备无须接线。真实 USB UAC 只作为其他不兼容应用的硬件备用。

## 模块

- `firmware/`：ESP-IDF 5.5.3 固件、LVGL 设备界面、BLE、音频和主机测试。
- `mac/`：Swift Companion、通用快捷键配置、Codex Hooks、额度读取、HAL 驱动和
  360×360 SwiftUI 模拟器。
- `protocol/`：CBOR/HMAC、BLE 分片、提示选项和 ADPCM 的稳定线协议。

Waveshare BSP 以源码形式固定在 `firmware/components/waveshare_bsp/`，来自官方
仓库提交 `139e6db584f3737fcfc6a958ee83b79fb69d317c`。上游目录携带了与
该开发板不匹配的 Component Manager 校验元数据，因此本地副本只移除了无效
校验文件并修正描述字段；准确来源和差异见 `firmware/components/waveshare_bsp/ORIGIN.md`。
业务代码调用官方
`bsp_display_start()`、`bsp_audio_codec_microphone_init()` 和
`bsp_audio_codec_speaker_init()`，不复制或猜测屏幕、触摸、ES7210/ES8311 初始化。

## 当前可运行内容

```bash
cd mac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run codex-companion quota
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run codex-companion doctor
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run codex-companion profile record
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run codex-companion daemon
```

运行模拟器可使用 Codex 的 Run 按钮，或执行：

```bash
./script/build_and_run.sh --verify
```

固件主机测试：

```bash
./firmware/host_tests/run.sh
```

连接实机前可先运行只读预检（不会刷写、复位或改变系统麦克风）：

```bash
./script/hardware_preflight.sh
```

HAL 驱动的构建、安装和移除脚本位于 `mac/Driver/scripts/`。安装需要管理员权限，
本仓库不会自动安装或重启 CoreAudio。Codex Hooks 插件位于 `mac/CodexPlugin/`，
也必须由用户安装并在 Codex 中审核信任：

```bash
codex plugin marketplace add /path/to/esp32-codex-companion
codex plugin add codex-companion-hooks@codex-companion-local
```

上述本地 marketplace 与插件清单已经通过隔离的 `CODEX_HOME` 做过实际安装解析验证；
这里不会替用户写入当前 Codex 配置。

设备到货并准备长期运行时，可手动执行 `mac/scripts/install-companion.sh` 安装用户级
常驻服务；卸载使用 `mac/scripts/uninstall-companion.sh`。脚本不会安装 HAL 驱动，
两项安装保持独立，便于回滚。

## Wi-Fi 与 USB 使用

1. 打开 Mac 的 `CodexCompanion.app`。首次使用时，若 macOS 询问“允许 Codex Companion
   查找并连接本地网络设备”，请选择允许；连接中心会显示“Wi-Fi 日常连接：等待设备”，
   并在同一行给出可选的 Mac IPv4 备用地址。
2. 在设备顶部点 `LINK`，点 `WI-FI SETUP (PHONE / MAC)`；屏幕会显示一次性热点名、
   密码及 `192.168.4.1`。用手机或 Mac 连入该热点，打开该地址并输入 2.4 GHz Wi-Fi
   的 SSID/密码。
3. 设备取得 IP 后，会通过 `_codex-companion._tcp` 自动发现 Mac 并完成已配对密钥
   握手。若路由器禁用组播、或 Mac 尚未授权本地网络，请把连接中心显示的 Mac IPv4
   填入网页的 `Mac IPv4 fallback`；设备会保存这个备用端点，并且仍以已配对密钥认证。
   Mac 连接中心显示“已连接”才表示控制和 UDP `49154` 音频端点均可用。正常无线使用
   时按住 BOOT 即通过 `Codex Mic` 输入；一次按住期间不会在 Wi-Fi/BLE 之间切换。
   松开 BOOT 后设备保留 8 秒待发送窗口；在窗口内短按两次 BOOT 才会让 Mac 注入
   Return 提交文字。第一次短按只进入确认态，第二次可在原 8 秒窗口结束前完成；
   长按会开始下一次语音，不会误发。
4. 产品驱动默认使用严格输入法兼容标识；豆包输入法 0.9.4 已实测能在设备
   不接 USB 时通过 `Codex Mic` 识别并转成文字。如其他应用仍拒绝该输入，
   才在设备 `LINK` 内启用 `USB MIC` 硬件备用。
5. 更换 Mac、配对密钥失效或 BLE 长期无法恢复时，在设备 `LINK` 内长按
   `RESET BLE PAIRING` 1.5 秒。设备会删除旧 BLE bond 与应用配对密钥并重新广播；
   保持 Companion 常驻运行即可重新配对。若 macOS 仍保留旧系统 bond，请在系统蓝牙
   设置中忽略旧的 `Codex Companion` 后等待自动扫描。

USB 麦克风模式占用同一 USB PHY，不能同时作为常规串口烧录/日志口。恢复刷机时必须：
**先断电 → 按住 BOOT → 插入数据线 → 插入后立即松开 BOOT**。不要等“刷完后”才松键。

> 安全边界：当前 SoftAP 热点使用每次触发生成的 WPA2 密码，局域网控制链路已加密；
> 但 Wi-Fi 凭据仍由 ESP-IDF 的普通 NVS 存储。量产前必须完成 secure-NVS / Flash
> Encryption / Secure Boot 迁移和实机验证，不能把当前构建视为量产安全配置。

## 硬件验证边界

构建与协议测试并不等于实机验收。仍需按 `docs/hardware-validation.md` 验证屏幕、
触摸、双麦克风、USB UAC 枚举、mDNS、BLE MTU、不同输入法和端到端延迟；在设备未
连接到本机时，不应把这些项目标记为已验证。
