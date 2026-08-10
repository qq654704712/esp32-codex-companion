# 设备到货后的验证清单

## 2026-07-17 PWR 按键硬件结论

- 已核对微雪官方 Rev1.1 原理图：`PWR`/Key1 接入独立电源开关芯片 U6 的
  `PWR_IN`，U6 的 `PWR_EN` 直接控制板级供电；该按键没有连接到 ESP32-S3 GPIO。
- 因此现有 PCB 上，固件无法读取 PWR 短按、无法把它安全映射为回车，也无法在
  短按到达电源芯片后再用软件阻止关机。为避免语音提交时误断电，本版不占用未知
  GPIO、不伪造 PWR 事件。
- 如需“BOOT 录音、PWR 发送”，硬件改版必须把一个独立按键信号接到可用 GPIO，
  或增加能向 ESP32 报告短按且由固件控制关机阈值的电源管理器；之后可复用现有
  加密控制链路发送 Return。
- 当前 PCB 的安全替代交互为：BOOT 长按录音，松开后进入 8 秒待发送窗口，再短按
  两次 BOOT 才通过加密控制链路发送 Return。第一下只显示“再按一次发送”，单次
  误触、超时或 PWR 操作都不会提交；按住 600 ms 才开始新的语音输入。第一次
  短按后的确认态保持到原 8 秒窗口结束，便于看清提示后再按第二次，但不会延长
  整体提交窗口。
- 依据：[官方产品页](https://docs.waveshare.com/ESP32-S3-Touch-LCD-1.85B)、
  [官方 Rev1.1 原理图](https://github.com/waveshareteam/ESP32-S3-Touch-LCD-1.85B/blob/main/hardware/ESP32-S3-Touch-LCD-1.85B%20Rev1.1.pdf)。

## 2026-07-17 多任务生命周期与提示音验收

- 活动数按用户可见 rollout 中尚未闭合的 `turn_context` 统计；`task_complete` 和
  `turn_aborted` 均结束活动计数，内部 subagent rollout 不计为独立对话。
- 启动与完成使用独立有界 FIFO，不被持续的 running/approval 状态吞掉；每个事件
  显示 4 秒动画后恢复聚合状态。
- 扬声器使用两组不同的 16 kHz 方波琶音：开始为上行 C5/E5/G5，完成为
  G5/C6/E6/C6。麦克风采集期间仍禁止播放，避免争用 ES7210/ES8311 共享 I2S。
- `working`、`running` 和历史兼容的 `writing` 在圆屏上统一显示为“正在工作”并
  共用扫描动画，避免状态来源切换造成文字跳变或静止画面；协议 ID 继续保留，任务
  开始/完成的独立动画和音效仍按 FIFO 播放，不会被聚合工作状态覆盖。

## 2026-07-17 麦克风兼容性实测

- 微信（微信客户端，不是微信输入法）能从无线 `Codex Mic` 完成语音输入，
  证明 Wi-Fi PCM、Mac 音频网关和 HAL 输入整体可用。
- 豆包输入法 `0.9.4` 已获得 macOS 麦克风权限，且 AVFoundation 能枚举
  `Codex Mic` （UID `com.codexcompanion.mic.device`）为已连接的默认输入。豆包仍在
  创建语音面板后提示“无可用麦克风”，期间没有打开 `Codex Mic` IO。
- 同次 PTT 的 Mac 网关分别收到 161/153 帧，两次均为 `lost=0`、`late=0`，
  首次输出约 147/126 ms；因此豆包失败发生在应用选择/打开输入设备之前，
  不是无线断流、默认设备切换或麦克风权限失败。
- 当时 Mac Studio 没有可用的内置麦克风，断开蓝牙音箱后，AVFoundation 只枚举
  到 `Codex Mic` 和另一个虚拟输入；豆包将它们都判定为不可用。这是本机版本
  的实测行为，豆包官方页面未说明虚拟麦克风支持范围。
- 启用可回退的 `CODEX_MIC_COMPAT_USB_TRANSPORT` 后，macOS 报告 `Codex Mic` 为 USB
  transport，但手持设备未接 USB，音频仍经 Wi-Fi 进入 Companion 本地 socket。
- 豆包随后将 `Codex Mic` 加入 `AVCaptureSession`、启动采集，并把 48 kHz Float32
  转换为 16 kHz PCM16。同次无线 PTT 收到 171 帧，`lost=0`、`late=0`、
  `firstOutputMs=71.5`；用户确认识别成功并转成文字。该兼容标识升级为产品默认，
  `CODEX_MIC_COMPAT_USB_TRANSPORT=0` 保留为标准 virtual transport 回归路径。
- 真实 USB UAC 仍单独保留作为硬件对照组，不再作为豆包无线使用的前置条件。

1. 确认 Rev1.1、360×360 ST77916、CST816、GPIO0 BOOT、PSRAM 和电池供电。
2. 分别验证 ES7210 两个物理麦克风通道及 RMNM 槽位 1/3，下混前检查相位和增益。
3. 连接 8Ω、约 1W 扬声器，验证 ES8311 提示音；录音门开启时必须静音输出。
4. 确认协商 MTU 247、加密 pairing、bonding、NVS/Keychain HMAC 密钥一致。
5. 测量 BOOT→波纹、首音频包、输入法语音启动、Codex→设备和设备审批→Mac 的
   P50/P95；原始时间戳应保留在测试日志。
6. 用至少两种用户选择的第三方输入法完成 `hold`、`togglePair` 或 `separate`
   校准，不增加任何按品牌判断的代码。
7. 连续执行 100 次 PTT，并注入 BLE 断开、Mac 睡眠、输入法退出与 Codex 重启。
   每次失败都必须释放合成按键、停止音频并恢复默认麦克风和输入来源。
8. 验证 Wi-Fi 日常控制的两条发现路径：允许 macOS Local Network 后的 Bonjour 自动
   发现，以及在设备网页填入连接中心给出的 Mac IPv4 备用地址后的直连。两者都必须
   完成 CCH2/CCW2 认证；错误地址或错误配对密钥不得改变设备状态。
9. 验证 UDP `49154` PCM 音频：连续 10 次 PTT 均只启动一次，按住 30 秒不中断，
   PTT→Mac 首次输出 P95 小于 250 ms；注入 1%–5% 丢包时补静音但不中止，连续
   500 ms 断流时必须释放快捷键并显示麦克风错误。随后断开 Wi-Fi，确认下一次 PTT
   使用 BLE；按住期间断网不得在同一会话内切换或混合两路音频。
10. 在已配对状态长按设备 Connection Center 的 `RESET BLE PAIRING`，验证旧 bond 与
    应用密钥都被删除、Mac 自动重新扫描，并在必要时忽略 macOS 侧旧 bond 后重新完成
    加密配对。
