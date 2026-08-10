# Release checklist

这是维护者在创建公开版本、打标签或发布二进制前使用的清单。每项都应留下命令输出、日志或硬件记录；没有证据就标记为 `NOT RUN`，不要用推测填充。

## Repository hygiene

- [ ] `git status --short` 只包含本次发布范围。
- [ ] `git diff --check` 通过；第三方 vendored 文件的原始格式例外已注明。
- [ ] 扫描绝对路径、凭据、私钥、个人导出文件和生成目录。
- [ ] README、许可证、贡献指南、安全政策和行为准则链接可用。
- [ ] 版本、变更日志和 GitHub Release 说明互相一致。

## Automated validation

- [ ] `./firmware/host_tests/run.sh`
- [ ] `swift test --package-path mac`
- [ ] `swift build --package-path mac --product CodexCompanion`
- [ ] `swift build --package-path mac --product companion-simulator`
- [ ] 在目标 ESP-IDF 版本执行 `./firmware/build.sh`
- [ ] CI 在干净的 macOS runner 上通过。

## Physical-device validation

- [ ] 屏幕、触摸、BOOT、双麦克风、扬声器、电量和待机。
- [ ] Wi-Fi SoftAP、2.4 GHz 配网、Bonjour 和 IPv4 fallback。
- [ ] 恢复配对、错误 SAS、撤销主机和旧 bond 清理。
- [ ] Wi-Fi UDP 音频丢包/断流，BLE 回退，以及同一 PTT 会话不混路。
- [ ] USB UAC 枚举、退出和 BOOT 上电恢复刷机。
- [ ] 至少两种输入法的快捷键校准与权限恢复。
- [ ] 100 次 PTT、睡眠/重启/断网/输入法退出等异常流程。

## Security and release boundary

- [ ] 不把 Wi-Fi 密码、配对密钥、Keychain 导出、profile JSON 或真实设备日志提交到仓库。
- [ ] 量产硬件单独验证 secure NVS、Flash Encryption、Secure Boot、OTA 和回滚路径。
- [ ] 公开说明仍区分本地构建、主机测试、实机验证和生产证明。
- [ ] 第三方 BSP、字体、音频和图片的许可证与来源已随版本归档。
