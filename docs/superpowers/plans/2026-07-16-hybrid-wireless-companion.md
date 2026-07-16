# Hybrid Wireless Codex Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a self-service ESP32-S3 companion with Wi-Fi-first state/control/audio, USB UAC compatibility mode, BLE recovery pairing, and a macOS background agent plus GUI.

**Architecture:** Preserve the current authenticated BLE implementation as a regression transport while adding transport-neutral control/audio interfaces. A launchd-owned macOS agent owns hooks, audio routing and device sessions; the GUI configures and observes it. Wi-Fi becomes the preferred LAN transport after secure provisioning/pairing, and USB UAC is an explicit reboot-and-re-enumerate compatibility path.

**Tech Stack:** ESP-IDF 5.5 C, ESP Wi-Fi provisioning/mDNS/lwIP/TinyUSB, Swift 6/macOS 14, CoreBluetooth, Network.framework, CryptoKit, CoreAudio HAL, XCTest, CTest.

## Global Constraints

- Do not implement input-method brand detection, private preference reads, private SDKs, or direct text injection.
- Wi-Fi does not change the fact that `Codex Mic` is virtual; never claim it fixes an IME that rejects virtual microphones.
- SAS is only a human comparison code; pair with long-lived public keys and derive unique AEAD session keys.
- UDP audio uses 16 kHz, 16-bit, mono PCM, 20 ms frames, AEAD, sequence/replay checks and bounded jitter buffering in its first release.
- USB UAC is a controlled reboot/re-enumeration mode; do not burn permanent USB PHY-selection eFuses and retain BOOT + power-on recovery flashing.
- BLE carries recovery pairing only after V2; do not advertise it as HFP or BLE Audio.
- GUI closure must not stop the background agent, hooks, audio routing or connected device session.
- Preserve existing user work; do not run destructive git commands or create commits in this workspace.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `protocol/wifi_transport.md` | Wire frame, key derivation, sequence, replay and failure contract shared by C and Swift |
| `protocol/pairing.md` | Host identity, SAS and BLE recovery pairing contract |
| `firmware/main/wifi_manager.[ch]` | STA, SoftAP provisioning, connection state and mDNS discovery |
| `firmware/main/wifi_transport.[ch]` | Reliable-control and UDP audio endpoints, authenticated session lifecycle |
| `firmware/main/pairing_manager.[ch]` | NVS host identities, SAS confirmation and BLE recovery transfer |
| `firmware/main/usb_uac_mode.[ch]` | Boot-selected UAC mode and safe reboot/exit state machine |
| `firmware/main/connection_center.[ch]` | Touch-driven LINK CENTER state/data model and actions |
| `firmware/main/device_ui.[ch]` | Existing round-screen rendering extended with connection-center states and new work animations |
| `mac/Sources/CodexCompanionCore/CompanionAgent.swift` | Agent-owned lifecycle composition independent of SwiftUI windows |
| `mac/Sources/CodexCompanionCore/WiFiDeviceTransport.swift` | mDNS discovery, authenticated control and UDP audio receive path |
| `mac/Sources/CodexCompanionCore/PairingCoordinator.swift` | SAS comparison, host keys and BLE recovery pairing state machine |
| `mac/Sources/CodexCompanionCore/USBCompatibilityRouter.swift` | UAC enumeration, temporary routing and restore diagnostics |
| `mac/Sources/CodexCompanionCore/CompanionControlReducer.swift` | Current-state/revision/expiry handling for hooks, prompts and reconnect replay |
| `mac/Sources/CodexCompanionApp/Views/ConnectionCenter*.swift` | Mac-side pairing/network/audio diagnostics UI |
| `mac/scripts/install-companion.sh` | Login agent installation; GUI is not the daemon |
| `mac/Tests/CodexCompanionCoreTests/*` | TDD coverage for all new Swift state machines and transport codecs |
| `firmware/host_tests/*` | Deterministic protocol, replay and state-machine tests |

## Task 1: Freeze the secure wire and pairing contracts

**Files:**
- Create: `protocol/wifi_transport.md`
- Create: `protocol/pairing.md`
- Create: `mac/Sources/CodexCompanionCore/WiFiWireCodec.swift`
- Create: `mac/Tests/CodexCompanionCoreTests/WiFiWireCodecTests.swift`
- Create: `firmware/components/wifi_wire/include/wifi_wire.h`
- Create: `firmware/components/wifi_wire/wifi_wire.c`
- Create: `firmware/host_tests/test_wifi_wire.c`

**Interfaces:**
- Produces `WiFiControlEnvelope`, `WiFiAudioFrame`, `PairingIdentity`, `SessionKeyDeriver` on Swift.
- Produces `cc_wifi_control_envelope_t`, `cc_wifi_audio_frame_t` and encode/decode functions on firmware.
- Consumes existing `ControlEnvelope` fields and keeps the message type identifiers stable.

- [ ] **Step 1: Write failing Swift and C codec tests**

```swift
func testAudioFrameRejectsDuplicateSequenceWithinSession() throws {
    var guarder = WiFiReplayWindow()
    XCTAssertTrue(try guarder.accept(sequence: 7, sessionID: 42))
    XCTAssertThrowsError(try guarder.accept(sequence: 7, sessionID: 42))
}
```

```c
assert(cc_wifi_audio_decode(packet, packet_len, key, &out) == CC_WIFI_WIRE_OK);
assert(cc_wifi_replay_accept(&window, 42, 7) == CC_WIFI_WIRE_OK);
assert(cc_wifi_replay_accept(&window, 42, 7) == CC_WIFI_WIRE_REPLAY);
```

- [ ] **Step 2: Run tests to verify red**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac --filter WiFiWireCodecTests`

Run: `cmake -S firmware/host_tests -B firmware/host_tests/build && cmake --build firmware/host_tests/build && ctest --test-dir firmware/host_tests/build --output-on-failure`

Expected: Swift target/test and C symbols are absent.

- [ ] **Step 3: Implement minimum wire contract**

Document exact binary fields: version, kind, session ID, sequence, timestamp, plaintext payload length, ChaCha20-Poly1305 nonce and tag. Encode audio only as `PCM16LE[320]`; reject oversized payloads, nonce reuse and sequence outside the replay window. Derive `controlKey` and `audioKey` from a long-lived pairing secret plus a fresh 32-byte session nonce using HKDF-SHA256 labels `codex-control-v2` and `codex-audio-v2`.

- [ ] **Step 4: Run green tests and format checks**

Run both Step 2 commands.

Expected: all new tests pass; malformed, replayed and tampered packets are rejected.

- [ ] **Step 5: Inspect changes without committing**

Run: `git diff --check -- protocol firmware mac`

Expected: no whitespace errors. Do not commit in this workspace.

## Task 2: Create the persistent macOS Companion agent boundary

**Files:**
- Create: `mac/Sources/CodexCompanionCore/CompanionAgent.swift`
- Create: `mac/Sources/CodexCompanionCore/AgentStatusStore.swift`
- Modify: `mac/Sources/CodexCompanionCore/CompanionService.swift`
- Modify: `mac/Sources/CodexCompanionCLI/main.swift`
- Modify: `mac/scripts/install-companion.sh`
- Test: `mac/Tests/CodexCompanionCoreTests/CompanionAgentTests.swift`

**Interfaces:**
- `CompanionAgent.start()`, `stop()`, `statusSnapshot()` own a single device session.
- GUI reads `AgentStatusStore`; it never creates a competing BLE/Wi-Fi session.
- CLI `daemon` instantiates `CompanionAgent` and remains launchd-owned.

- [ ] **Step 1: Write failing lifecycle tests**

```swift
func testClosingObserverDoesNotStopRunningAgent() {
    let agent = CompanionAgent(dependencies: .test)
    agent.start()
    agent.detachGUIObserver()
    XCTAssertEqual(agent.statusSnapshot().lifecycle, .running)
}
```

- [ ] **Step 2: Verify red**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac --filter CompanionAgentTests`

Expected: `CompanionAgent` does not exist.

- [ ] **Step 3: Implement minimal agent extraction**

Move timers, hook inbox draining, quota refresh, PTT coordination and active transport ownership out of the SwiftUI-created `CompanionService`. Give `CompanionService` a thin client facade that subscribes to the agent status store. Update the launch agent to run `codex-companion daemon` and install only one process.

- [ ] **Step 4: Verify green and process installation script**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac`

Run: `zsh -n mac/scripts/install-companion.sh`

Expected: all current tests pass; script is syntactically valid.

## Task 3: Add transport-neutral status/action reducer

**Files:**
- Create: `mac/Sources/CodexCompanionCore/CompanionControlReducer.swift`
- Modify: `mac/Sources/CodexCompanionCore/CodexHookEvent.swift`
- Modify: `mac/Sources/CodexCompanionCore/CompanionService.swift`
- Modify: `mac/CodexPlugin/hooks/hooks.json`
- Test: `mac/Tests/CodexCompanionCoreTests/CompanionControlReducerTests.swift`

**Interfaces:**
- `reduce(hook:) -> RevisionedDeviceState` includes session ID, turn ID, revision and expiry.
- `ApprovalAction` requires `actionID`, expiry and risk validation before accessibility click.
- Device transport receives current state snapshot after reconnect.

- [ ] **Step 1: Write failing stale-state and tool-state tests**

```swift
func testOlderRevisionCannotReplaceCurrentApproval() {
    var reducer = CompanionControlReducer(clock: .fixed)
    _ = reducer.reduce(hook: .approval(session: "s", turn: "2"))
    XCTAssertNil(reducer.applyRemoteAcknowledgement(revision: 1))
}

func testApplyPatchUsesWritingState() {
    XCTAssertEqual(CodexHookEventParser.parse(preTool("apply_patch"))?.state, .writing)
}
```

- [ ] **Step 2: Verify red**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac --filter CompanionControlReducerTests`

Expected: `writing`, revisions and action IDs are absent.

- [ ] **Step 3: Implement reducer and protocol identifiers**

Add `writing` and `running` to `DeviceState`, `DevicePayloadCodec` and firmware model identifiers. Map file-mutating tools (`apply_patch`, `write_file`, `replace_file`) to writing; all other PreToolUse tools to running. Preserve the previous state only while the same session/turn is active and expire stale prompts.

- [ ] **Step 4: Verify green**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac`

Expected: state codec, hooks and reducer test suites pass.

## Task 4: Implement self-service Wi-Fi provisioning and host discovery

**Files:**
- Create: `firmware/main/wifi_manager.c`
- Create: `firmware/main/wifi_manager.h`
- Modify: `firmware/main/CMakeLists.txt`
- Modify: `firmware/main/app_main.c`
- Modify: `firmware/partitions.csv`
- Create: `firmware/host_tests/test_wifi_manager.c`
- Create: `mac/Sources/CodexCompanionCore/CompanionBonjourAdvertiser.swift`
- Test: `mac/Tests/CodexCompanionCoreTests/CompanionBonjourAdvertiserTests.swift`

**Interfaces:**
- Firmware: `cc_wifi_start()`, `cc_wifi_begin_provisioning()`, `cc_wifi_status()`, `cc_wifi_clear_credentials()`.
- Mac: `CompanionBonjourAdvertiser.start(hostIdentity:)` advertises only when enabled.
- Firmware uses mDNS discovery as a candidate list only; pairing remains separate.

- [ ] **Step 1: Write failing deterministic Wi-Fi state tests**

```c
cc_wifi_model_t model = cc_wifi_model_initial();
assert(cc_wifi_event(&model, CC_WIFI_BEGIN_PROVISIONING) == CC_WIFI_SOFTAP_ACTIVE);
assert(model.setup_password_is_ephemeral);
assert(cc_wifi_event(&model, CC_WIFI_PROVISION_TIMEOUT) == CC_WIFI_UNCONFIGURED);
```

```swift
func testAdvertiserDoesNotPublishWhenDiscoveryDisabled() {
    let advertiser = CompanionBonjourAdvertiser(enabled: false)
    XCTAssertFalse(advertiser.start(hostIdentity: .test))
}
```

- [ ] **Step 2: Verify red**

Run CTest and the filtered XCTest suite from Task 1/2.

Expected: Wi-Fi state machine and Bonjour advertiser do not exist.

- [ ] **Step 3: Implement provisioning safely**

Use ESP-IDF provisioning with a physical touch/long-press start, an ephemeral `Codex-Setup-XXXX` SSID/password, timeout and rate limit. Prefer Security 2; if unavailable in the pinned IDF configuration, fail closed until a documented Security 1 strong-PoP implementation passes tests. Restrict selectable SSIDs to 2.4 GHz compatible networks. Change the partition/security configuration only after its encrypted NVS/boot/OTA prerequisites are validated in an isolated flash test.

- [ ] **Step 4: Implement companion service advertisement**

Publish `_codex-companion._tcp` with host label, port, protocol version and public-key fingerprint. Disable publishing by default on untrusted networks and surface macOS firewall/local-network permission failures in the GUI.

- [ ] **Step 5: Verify green**

Run host tests, `idf.py -C firmware build`, and `swift test --package-path mac`.

Expected: clean firmware build and all state tests pass; no real password is logged.

## Task 5: Implement BLE recovery pairing and connection-center data model

**Files:**
- Create: `firmware/main/pairing_manager.c`
- Create: `firmware/main/pairing_manager.h`
- Create: `firmware/main/connection_center.c`
- Create: `firmware/main/connection_center.h`
- Modify: `firmware/main/ble_transport.[ch]`
- Modify: `firmware/main/device_ui.[ch]`
- Create: `mac/Sources/CodexCompanionCore/PairingCoordinator.swift`
- Create: `mac/Tests/CodexCompanionCoreTests/PairingCoordinatorTests.swift`
- Create: `firmware/host_tests/test_pairing_manager.c`

**Interfaces:**
- Firmware `cc_pairing_begin_recovery()`, `cc_pairing_confirm_sas()`, `cc_pairing_unpair(hostID)`.
- Mac `PairingCoordinator.beginRecovery(device:)`, `confirm(sas:)`, `cancel()`.
- Connection center exposes network, host and audio pages without granting arbitrary remote control.

- [ ] **Step 1: Write failing pairing tests**

```swift
func testSASMismatchNeverPersistsHostIdentity() throws {
    var pairing = PairingCoordinator.test
    try pairing.beginRecovery(device: .test)
    XCTAssertThrowsError(try pairing.confirm(deviceSAS: "123456", macSAS: "654321"))
    XCTAssertNil(pairing.boundHost)
}
```

```c
assert(cc_pairing_confirm_sas(&pairing, false) == CC_PAIRING_REJECTED);
assert(!cc_pairing_has_primary_host(&pairing));
```

- [ ] **Step 2: Verify red**

Run filtered XCTest and CTest; expect missing coordinator/manager symbols.

- [ ] **Step 3: Implement recovery and UI model**

Use an encrypted BLE session only to move the Mac endpoint and public-key binding after both sides compare SAS. Never use BLE to transmit daily audio. Add LINK CENTER pages for Wi-Fi status/configure/reset, nearby host candidates/select/switch/unpair, and audio mode/diagnostics. Require a 1.5-second touch confirmation for unpair and host switch.

- [ ] **Step 4: Verify green**

Run CTest, XCTest and `idf.py -C firmware build`.

## Task 6: Implement authenticated Wi-Fi control and reconnect replay

**Files:**
- Create: `firmware/main/wifi_transport.c`
- Create: `firmware/main/wifi_transport.h`
- Modify: `firmware/main/app_main.c`
- Create: `mac/Sources/CodexCompanionCore/WiFiDeviceTransport.swift`
- Modify: `mac/Sources/CodexCompanionCore/CompanionAgent.swift`
- Test: `mac/Tests/CodexCompanionCoreTests/WiFiDeviceTransportTests.swift`
- Test: `firmware/host_tests/test_wifi_transport.c`

**Interfaces:**
- `WiFiDeviceTransport` conforms to a common `CompanionDeviceTransport` interface with `sendControl`, `onControl`, `connectionState` and `replayCurrentState`.
- Firmware mirrors it with `cc_wifi_transport_send_control` and callbacks for authenticated control payloads.

- [ ] **Step 1: Write failing reconnect tests**

```swift
func testReconnectReplaysOnlyUnexpiredCurrentState() async throws {
    let transport = WiFiDeviceTransport.test
    let state = RevisionedDeviceState.working(sessionID: "s", revision: 9, expiresAt: .distantFuture)
    await transport.setCurrent(state)
    await transport.simulateReconnect()
    XCTAssertEqual(await transport.sentStates, [state])
}
```

- [ ] **Step 2: Verify red**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac --filter WiFiDeviceTransportTests`

Expected: transport and state replay API are absent.

- [ ] **Step 3: Implement reliable control**

Implement authenticated control connection setup, heartbeats, ACKs, quotas, state/prompt/reply envelopes and reconnect replay. Reject unpaired peers, expired messages, mismatched sessions and replay sequences. Keep BLE transport behind the same interface as regression fallback.

- [ ] **Step 4: Verify green**

Run full Swift and firmware host tests. Simulate host sleep, agent restart and network change in deterministic tests.

## Task 7: Implement Wi-Fi UDP audio gateway and diagnostics

**Files:**
- Create: `firmware/main/wifi_audio_stream.c`
- Create: `firmware/main/wifi_audio_stream.h`
- Create: `mac/Sources/CodexCompanionCore/WiFiAudioGateway.swift`
- Modify: `mac/Sources/CodexCompanionCore/CodexMicSocketClient.swift`
- Modify: `mac/Sources/CodexCompanionApp/Views/AudioDiagnosticsView.swift`
- Test: `mac/Tests/CodexCompanionCoreTests/WiFiAudioGatewayTests.swift`
- Test: `firmware/host_tests/test_wifi_audio_stream.c`

**Interfaces:**
- `WiFiAudioGateway.ingest(datagram:)` decrypts, orders and writes PCM frames to `FloatAudioSink`.
- `WiFiAudioMetrics` reports received, lost, late, replayed and one-way-delay estimates.
- Firmware uses PTT session ID from control before emitting audio.

- [ ] **Step 1: Write failing audio ordering tests**

```swift
func testLatePacketDoesNotBlockFollowingPCMFrame() throws {
    var gateway = WiFiAudioGateway.test
    try gateway.ingest(frame(session: 3, sequence: 1))
    try gateway.ingest(frame(session: 3, sequence: 3))
    XCTAssertEqual(gateway.metrics.lostFrames, 1)
    XCTAssertEqual(gateway.sink.samples.count, 960)
}
```

- [ ] **Step 2: Verify red**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac --filter WiFiAudioGatewayTests`

Expected: gateway is absent.

- [ ] **Step 3: Implement bounded real-time behavior**

Use independent UDP send/receive tasks, fixed 20 ms PCM frames, nonce/key creation after PTT_DOWN and zero-allocation hot paths where possible. On loss insert one silent PLC frame; on excessive jitter/loss end the session safely and emit a distinct network-audio error. Do not let audio processing block control/shortcut release.

- [ ] **Step 4: Verify green**

Run full Swift/C host tests; replay prerecorded PCM through the socket and capture `Codex Mic` at 48 kHz mono.

## Task 8: Implement USB UAC compatibility mode and host routing

**Files:**
- Create: `firmware/main/usb_uac_mode.c`
- Create: `firmware/main/usb_uac_mode.h`
- Modify: `firmware/main/app_main.c`
- Modify: `firmware/main/CMakeLists.txt`
- Create: `mac/Sources/CodexCompanionCore/USBCompatibilityRouter.swift`
- Test: `mac/Tests/CodexCompanionCoreTests/USBCompatibilityRouterTests.swift`
- Test: `firmware/host_tests/test_usb_uac_mode.c`

**Interfaces:**
- `cc_usb_mode_request(CC_USB_MODE_UAC)` persists a pending boot mode and triggers controlled reboot.
- `USBCompatibilityRouter.prepare(device:)`, `restore()` return typed states `.notEnumerated`, `.routeFailed`, `.ready`.

- [ ] **Step 1: Write failing mode transition and routing tests**

```swift
func testPrepareRestoresOriginalDefaultInputOnFailure() throws {
    let router = USBCompatibilityRouter(api: .failingAfterRoute)
    XCTAssertThrowsError(try router.prepare(device: .test))
    XCTAssertEqual(router.api.defaultInputUID, "original")
}
```

```c
assert(cc_usb_mode_request(&mode, CC_USB_MODE_UAC) == CC_USB_REBOOT_REQUIRED);
assert(mode.pending == CC_USB_MODE_UAC);
```

- [ ] **Step 2: Verify red**

Run filtered XCTest and firmware host tests; expect missing UAC mode symbols.

- [ ] **Step 3: Implement UAC state machine**

Integrate ESP-IDF TinyUSB UAC device support on USB-OTG, select the USB PHY at boot, route existing PCM capture into UAC, and publish stable VID/PID/serial. Enter/exit only by reboot. On Mac, wait for enumeration, set temporary default input, confirm it, then execute PTT and restore afterward. Display each distinct failure in connection center.

- [ ] **Step 4: Verify green and hardware-gated acceptance**

Run firmware build and all unit tests. On hardware, verify: Audio MIDI Setup enumeration, recording, UAC re-enumeration after both transitions, BOOT+power-on recovery flashing, and each target IME. Do not claim Doubao compatibility before the last test succeeds.

## Task 9: Finish connection-center UI, animation coverage and end-to-end validation

**Files:**
- Modify: `firmware/main/device_ui.[ch]`
- Modify: `firmware/main/device_model.[ch]`
- Modify: `mac/Sources/CodexCompanionApp/Views/CompanionDashboardView.swift`
- Create: `mac/Sources/CodexCompanionApp/Views/ConnectionCenterDiagnosticsView.swift`
- Modify: `mac/Sources/CompanionSimulator/Views/PixelCodexCharacterView.swift`
- Test: `mac/Tests/CodexCompanionCoreTests/ConnectionCenterStateTests.swift`
- Test: `firmware/host_tests/test_connection_center.c`

**Interfaces:**
- Device model exposes network, pairing, audio mode and diagnostic state required for rendering.
- UI actions produce typed requests only; they never bypass pairing/risk validation.

- [ ] **Step 1: Write failing UI-state tests**

```swift
func testLinkCenterShowsUSBEnumerationFailureWithoutClaimingMicrophoneReady() {
    let state = ConnectionCenterState(audio: .usbNotEnumerated)
    XCTAssertEqual(state.headline, "USB MIC NOT FOUND")
    XCTAssertFalse(state.canStartVoice)
}
```

- [ ] **Step 2: Verify red**

Run the filtered XCTest suite and firmware CTest; expect state model absent.

- [ ] **Step 3: Implement final visual/state coverage**

Add network, host and audio pages; implement disconnected/provisioning/pairing/working/writing/running/completed/error/approval/listening/UAC-reboot visual states. Keep the established dark high-saturation green/cyan palette and ensure all display regions fit the real 360x360 screen.

- [ ] **Step 4: Run complete validation**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path mac
cmake --build mac/Driver/build && ctest --test-dir mac/Driver/build --output-on-failure
cmake -S firmware/host_tests -B firmware/host_tests/build && cmake --build firmware/host_tests/build && ctest --test-dir firmware/host_tests/build --output-on-failure
export IDF_PATH="$PWD/work/esp-idf" IDF_TOOLS_PATH="$PWD/work/idf-tools" IDF_PYTHON_ENV_PATH="$PWD/work/idf-tools/python_env/idf5.5_py3.12_env" IDF_SKIP_CHECK_SUBMODULES=1
"$IDF_PYTHON_ENV_PATH/bin/python" "$IDF_PATH/tools/idf.py" -C firmware build
```

Expected: all host tests and firmware build pass. Hardware-only claims remain marked unverified until physical tests are completed.

## Self-Review

- Security and NVS/OTA gates are Task 1 and Task 4 prerequisites, not post-launch cleanup.
- Self-service Wi-Fi, host selection, dual confirmation and BLE recovery are Tasks 4 and 5.
- Wi-Fi audio, state and approval transport are Tasks 3, 6 and 7.
- USB UAC is an independently tested reboot/re-enumeration task, not a fallback assertion.
- GUI/agent separation is Task 2.
- The plan intentionally does not promise a third-party IME until physical validation is complete.
