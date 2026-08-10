# Codex Mic HAL driver

`CodexMic.driver` is a 48 kHz, mono, Float32 input-only Audio Server plug-in.
It exposes the device UID `com.codexcompanion.mic.device` and accepts local
audio frames on `/tmp/codex-mic-<uid>.sock` using an 8-byte `CMIC` header,
a big-endian UInt32 sample count, and native little-endian Float32 samples.

The implementation follows Apple's current [Creating an Audio Server Driver
Plug-in](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
sample but publishes only the input device required by this project.

Build with `scripts/build-driver.sh`. Installation and removal require an
administrator and intentionally live in separate scripts. Do not install the
driver until the Mac-side tests and signature verification pass.

The product build reports USB-compatible transport metadata because Doubao
Input Method 0.9.4 was physically observed to enumerate and record wireless
audio only after that metadata change. The audio path itself remains ESP32 →
Wi-Fi → Companion socket → HAL; the handheld device is not cabled.

Build and test the deployed compatibility driver with:

```sh
scripts/build-driver.sh
```

To restore the standards-oriented CoreAudio `virtual` transport for regression
testing, use the explicit reversible override:

```sh
CODEX_MIC_COMPAT_USB_TRANSPORT=0 scripts/build-driver.sh
```

Do not generalize the Doubao result to every application. WeChat and Doubao are
the two physically observed clients; each additional target still needs an
actual recording test.
