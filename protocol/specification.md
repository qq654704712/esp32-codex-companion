# Wire specification

## GATT

Service UUID: `4F50454E-4149-434F-4445-584D49430001`

| Characteristic | UUID suffix | Direction | Protection |
|---|---:|---|---|
| Control | `0002` | bidirectional | encrypted write, notify, HMAC |
| Audio | `0003` | device to Mac | notify over bonded link |
| Provision | `0004` | Mac to device once | encrypted write |

The device uses BLE Secure Connections and bonding. On a factory-new device,
the Mac creates 32 random bytes in Keychain and writes them to Provision after
link encryption is established. The device stores the first key in NVS,
accepts the same value idempotently on bonded reconnects, and rejects any
replacement. This key authenticates control envelopes; it is never compiled
into either binary.

## BLE control fragmentation

Every Control characteristic value begins with five bytes:

```text
0xCC | frameID u16 big-endian | fragmentIndex u8 | fragmentCount u8 | data
```

The GATT value is at most 244 bytes at MTU 247, leaving 239 data bytes per
fragment. Fragments must be sequential and a reassembled packet cannot exceed
512 bytes. Malformed, duplicated, skipped, or reordered fragments reset the
current reassembly.

## Signed envelope

The envelope is a canonical CBOR map with integer keys:

```text
0: version u8 (1)
1: sequence u32
2: messageType u16
3: timestampMs u64
4: payload bstr containing CBOR
5: HMAC-SHA256(first five map entries), truncated to 16 bytes
```

Each direction has an independent monotonically increasing sequence guard.
Sequences that repeat or move backwards are rejected. Heartbeats are sent every
2 seconds; 6 seconds without an authenticated message marks the peer offline.
Both guards reset only when a new encrypted BLE connection session becomes
ready, so either endpoint may reboot without permanently desynchronizing the
other.

## Payloads

State IDs are stable and are not derived from display strings:

| ID | State |
|---:|---|
| 0 | disconnected |
| 1 | idle |
| 2 | sessionStarting |
| 3 | working |
| 4 | completed |
| 5 | error |
| 6 | approvalRequired |
| 7 | inputRequired |
| 8 | confirmationRequired |
| 9 | listening |
| 10 | voiceError |

- `stateUpdate`: `{0: stateID}`
- `quotaUpdate`: `{0: fiveHourRemaining, 1: weekRemaining}` where `0...100`
  is a percentage and `255` is the unavailable sentinel.
- `heartbeat`: `{0: quotaFresh}`. This keeps the device's stale marker accurate
  without retransmitting unchanged quota values; the flag is true only when the
  Mac completed a quota refresh within the previous 120 seconds.
- `pttDown`, `pttUp`, `ack`, `promptClose`: `{}`.
- `promptOpen`: `{0: promptID, 1: [{0: AXIdentifier, 1: title,
  2: requiresLongPress}, ...]}`. Maximum eight scrollable options. Options without a stable
  Accessibility identifier, and Other/free-text/secret choices, are not sent.
- `optionSelect` and `longPressConfirm`: `{0: promptID, 1: optionIndex}`.

The Mac re-enumerates the live Accessibility dialog and matches both identifier
and title before invoking `AXPress`. A high-risk option is rejected unless it
arrives as `longPressConfirm` after a device hold of at least 1.5 seconds.

## Audio blocks

Each 20 ms frame contains 320 mono samples at 16 kHz and is encoded to 166
bytes:

```text
sequence u16 BE | initial predictor i16 BE | step index u8 | reserved u8 |
160 bytes IMA-ADPCM, low nibble first
```

The predictor and step index reset for every block. A missing sequence is
concealed independently and does not affect later decoding. The Mac resamples
to 48 kHz Float32 mono before writing to the private `Codex Mic` HAL socket.
