# Connection Center

设备端的 Connection Center 是 Wi-Fi 配网、USB 麦克风兼容和 BLE 配对恢复入口。它不是
通用蓝牙设备列表：ESP32-S3 是 BLE 外设，Mac Companion 是 central，扫描、系统配对弹窗
与选择旧设备的操作由 macOS 负责。

## 打开方式与当前布局

点 360×360 屏幕顶部的 `LINK` 把手，打开 316×320 px 的不透明面板；再点 `LINK` 或面板
底部 `TAP LINK TO CLOSE` 即可关闭。面板打开时始终显示四种真实状态：

| 行 | 含义 | 典型值 |
| --- | --- | --- |
| `MAC` | 已认证控制链路 | `CONNECTED`、`WAITING`、`LINK LOST` |
| `AUTH` | 当前认证状态 | `ENCRYPTED`、`PAIRING` |
| `MIC` | 当前音频路径 | `Codex Mic`、`USB UAC ACTIVE`、驱动提示 |
| `WI-FI` | Wi-Fi 或配网页状态 | `NOT CONFIGURED`、热点提示、已连接提示 |

`KEY` 固定显示默认 BOOT→Fn 按住映射；实际快捷键档案在 Mac 的 Codex Companion 应用中录制和
保存，设备只发送 PTT 按下/松开事件。

## 可操作项

### Wi-Fi 配网

点 `WI-FI SETUP (PHONE / MAC)` 后，设备启动带一次性 WPA2 密码的 SoftAP，并在面板显示热点
名称、密码和 `192.168.4.1`。手机或 Mac 连入热点后打开该地址，输入 2.4 GHz Wi-Fi 的 SSID、
密码，以及可选的 Mac IPv4 备用地址。

保存成功后，设备优先以 `_codex-companion._tcp` 发现 Mac；组播不可用时使用保存的 IPv4 地址。
无论走哪条路径都必须完成 CCH2/CCW2 已配对密钥认证，面板显示 `MAC CONNECTED` 才表示控制
链路可用。

### USB MIC

面板显示 `USB MIC: OFF / TAP TO ENABLE + RESTART` 时，点按会把下一次启动模式保存为 USB UAC，
随后设备重启并在 macOS 中枚举为 `Codex Companion USB Mic`。这条路径是给拒绝虚拟 `Codex Mic`
的第三方输入法使用的标准硬件麦克风兼容模式。

启用后按钮变成 `USB MIC: ON / TAP TO EXIT + RESTART`。再次点按会重启回普通模式。UAC 与串口烧录
共用 USB PHY；退出 UAC 或重新刷机时使用：**断电 → 按住 BOOT → 插入数据线 → 插入后立即松开
BOOT**。

### 恢复 BLE 配对

长按 `RESET BLE PAIRING` 1.5 秒会同时删除设备端 BLE bond 与应用层 HMAC 配对密钥，然后断开
当前连接并重新广播。这样不会留下“macOS 看似已配对、应用密钥却已失效”的半配对状态。

如果 Mac 还持有旧系统 bond，请在 macOS 蓝牙设置中忽略旧 `Codex Companion`，保持后台 Companion
运行，等待它重新扫描并显示系统配对确认。

## 边界

- ESP32-S3 没有 Bluetooth Classic HFP，也没有 BLE Audio 标准麦克风 profile；它不会在 macOS
  蓝牙列表中作为原生“蓝牙麦克风 + 键盘”复合设备出现。
- 非 USB 音频为自定义 BLE 音频流，经 Mac 的 `Codex Mic` CoreAudio 输入设备提供给应用；按键映射
  由 Mac 合成事件完成。
- Wi-Fi 是日常状态、审批和 PTT 控制的优先路径；USB UAC 只解决应用不接受虚拟麦克风的问题，
  不替代认证控制链路。
