# Architecture

## Components

| Component | Responsibility | Main paths |
| --- | --- | --- |
| ESP32 firmware | Device UI, BOOT/PTT, battery, Wi-Fi provisioning, BLE pairing, audio capture and USB UAC fallback | `firmware/main/`, `firmware/components/` |
| macOS Core | Pairing, Bonjour discovery, encrypted control/audio, CoreAudio input, shortcut emission and task state | `mac/Sources/CodexCompanionCore/` |
| macOS App | Connection Center, dashboard, weather/status/settings and simulator UI | `mac/Sources/CodexCompanionApp/`, `mac/Sources/CompanionSimulator/` |
| CLI/daemon | Headless agent, quota/profile/doctor commands and Hook ingestion | `mac/Sources/CodexCompanionCLI/` |
| Protocol | Stable CBOR/HMAC envelopes, CCH2/CCW2 handshake, BLE fragmentation and audio framing | `protocol/`, matching C/Swift codecs |

## Runtime flow

1. The device starts a short-lived SoftAP only when the user enters Wi-Fi setup. Credentials are written through the normal ESP-IDF NVS path.
2. Recovery pairing exchanges fresh ephemeral material, the long-lived public identity and a short SAS. Both sides must confirm the SAS before storing the 32-byte application secret.
3. Bonjour is a discovery hint, not an authorization decision. A host must already have a matching pairing record before it can establish CCH2/CCW2 control and audio sessions.
4. Wi-Fi is the normal path for status, approvals, PTT and PCM audio. If Wi-Fi is unavailable before a PTT session starts, the next session may use BLE ADPCM; a session never mixes the two paths.
5. The macOS service writes decoded audio to the `Codex Mic` CoreAudio device and emits the user-calibrated shortcut. The input method remains outside this repository and is never selected by vendor-specific code.
6. Codex Hook events enter the same bounded control reducer as device events. Task audio/animation is scoped to the Codex app, while the watch face keeps global connection, battery and weather state.

## Trust boundaries

- **Pairing boundary:** short SAS confirmation is required on both endpoints; mDNS, device name and IP address are not trusted credentials.
- **Transport boundary:** control and audio derive separate session keys from the pairing secret; replay, source and authentication checks happen before state mutation or audio playback.
- **OS boundary:** macOS Accessibility, Bluetooth, Local Network, Microphone and Keychain permissions are user decisions. The installer requests no permission silently.
- **Firmware storage boundary:** the current developer build uses ordinary NVS. Secure NVS, Flash Encryption, Secure Boot and OTA policy are release blockers for production hardware.

## Extension points

- Implement another host by following `protocol/` and using the same pairing record, host ID and capability fields.
- Add another input method by recording a user-selected shortcut profile; do not add brand-name detection to the transport layer.
- Add another device UI state through the bounded payload codec and update both C/Swift tests plus the golden protocol vectors.
- Add another board only after documenting its GPIO, display, audio codec, USB PHY and recovery-flash differences in `docs/`.
