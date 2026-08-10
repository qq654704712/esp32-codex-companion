# Contributing

感谢参与 ESP32-S3 Codex Companion。这个仓库同时包含嵌入式 C、Swift/macOS、协议和硬件验证文档；小而可审阅的变更最容易合并。

## 开始之前

1. 先阅读 [README.md](README.md)、[docs/architecture.md](docs/architecture.md) 和相关协议文档。
2. 对硬件行为变更，先在 Issue 中说明板卡版本、固件版本和复现步骤。
3. 不要提交 Wi-Fi 凭据、配对密钥、Keychain 导出、快捷键 profile、真实设备日志或本机绝对路径。

## 本地检查

```bash
./firmware/host_tests/run.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path mac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path mac --product CodexCompanion
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path mac --product companion-simulator
git diff --check
```

固件完整构建需要你本机安装 ESP-IDF；实机行为必须按照 [docs/hardware-validation.md](docs/hardware-validation.md) 单独记录，不能用主机测试结果替代。

## 提交规范

- 一个提交只解决一个主题；提交消息使用动词开头，例如 `fix: reject replayed audio frame`。
- C 代码保持 `-Wall -Wextra -Werror` 主机测试可通过；Swift 代码补充 XCTest。
- 协议字段变更必须同时更新 C/Swift 编解码、`protocol/` 文档、golden vector 和回归测试。
- UI 或硬件交互变更请说明触摸尺寸、按键时序、USB PHY/刷机影响和回滚方式。
- 只在确认用户可见行为后更新 README；仍未完成的实机项目写入验证边界，而不是标记为“已支持”。

## Pull Request

PR 描述请包含：背景、变更、测试命令及输出、硬件验证（若有）、安全影响和未完成项目。CI 通过只是合并门槛，不代表硬件验收或量产安全通过。

维护者会优先处理能在干净环境重现、包含测试或文档、并明确证据边界的贡献。
