# 设备到货后的验证清单

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
9. 只有 BLE 音频的实测 P95 无法达标时，才实现局域网 UDP 音频备用通道；状态、审批
   与 PTT 控制须同时覆盖 Wi-Fi 日常链路和 BLE 恢复链路。
10. 在已配对状态长按设备 Connection Center 的 `RESET BLE PAIRING`，验证旧 bond 与
    应用密钥都被删除、Mac 自动重新扫描，并在必要时忽略 macOS 侧旧 bond 后重新完成
    加密配对。
