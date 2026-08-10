# Security policy

## Scope

本项目涉及 BLE 配对、Wi-Fi 控制/音频、CoreAudio、Keychain 和设备 NVS。以下问题属于安全漏洞：认证绕过、未授权控制或音频接收、配对密钥泄露、重放/篡改导致状态改变、凭据明文意外提交，以及可导致权限边界失效的安装脚本问题。

当前开发固件**不是量产安全配置**：普通 NVS、Flash Encryption、Secure Boot、OTA 和安全回滚仍需在目标硬件上独立验证。请不要把开发构建用于保存高价值凭据或生产部署。

## Reporting

请不要在公开 Issue 中粘贴密钥、完整设备日志或可利用细节。优先使用 GitHub 的私有漏洞报告入口：

<https://github.com/qq654704712/esp32-codex-companion/security/advisories/new>

报告请包含：影响范围、复现步骤、最小化日志/代码、受影响的提交或版本，以及你希望的署名方式。若私有入口不可用，请先开一个不包含细节的 Issue，注明“security report requested”，不要公开漏洞证明。

维护者会先确认收件，再协调修复、回归测试和公开公告。请给出合理的修复窗口，不要在补丁发布前公开零日细节。
