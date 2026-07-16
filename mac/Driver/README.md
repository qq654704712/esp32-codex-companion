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
