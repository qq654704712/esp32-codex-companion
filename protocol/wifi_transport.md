# Codex Companion Wi-Fi Transport v2

This document defines the encrypted transport used after a device and a Mac
have completed recovery pairing. It does **not** replace the BLE v1 control
protocol: BLE remains the recovery transport until both peers advertise v2.

## Session keys

Recovery pairing stores a 32-byte `pairingSecret` on both peers. TCP begins
with two fixed 54-byte `CCH2` records: device role
`1` then host role `2`. Each record is `magic[4] || version[1] || role[1] ||
nonce[32] || HMAC-SHA256(pairingSecret, preceding bytes)[0..15]`. The salt is
`SHA256("codex-wifi-session-v2" || deviceNonce || hostNonce)`. Both nonces are
fresh random 32-byte values. Any malformed record, role mismatch, or bad tag
terminates the connection before control frames are accepted.

The peers derive two different 32-byte keys with HKDF-SHA256:

```
salt = sessionNonce
IKM  = pairingSecret
controlKey = HKDF-Expand(HKDF-Extract(salt, IKM), "codex-control-v2", 32)
audioKey   = HKDF-Expand(HKDF-Extract(salt, IKM), "codex-audio-v2", 32)
```

The nonce exchange is authenticated by the pairing session. mDNS TXT identity
data is only a discovery hint; the HMAC handshake is authoritative. A future
SAS/identity record may improve the recovery-pairing UX, but it is never used
as key material.

## Encrypted frame

All multi-byte integers are big endian. `AAD` is the 42-byte header exactly
as received. Ciphertext is followed by the 16-byte ChaCha20-Poly1305 tag.

| Offset | Size | Field |
| --- | ---: | --- |
| 0 | 4 | ASCII magic `CCW2` |
| 4 | 1 | Version `2` |
| 5 | 1 | Kind: `1` control, `2` audio |
| 6 | 1 | Flags, currently zero |
| 7 | 1 | Header size `42` |
| 8 | 8 | Session ID |
| 16 | 4 | Per-session sequence |
| 20 | 8 | Sender monotonic timestamp in milliseconds |
| 28 | 2 | Plaintext length |
| 30 | 12 | ChaCha20-Poly1305 nonce |
| 42 | N | Ciphertext |
| 42+N | 16 | Authentication tag |

Control plaintext is an existing authenticated v1 `ControlEnvelope` payload.
Its message type identifiers are unchanged. Audio plaintext is exactly 640
bytes of `PCM16LE[320]` (16 kHz, mono, 20 ms).

For streaming, a sender derives the frame nonce as `sessionID[8] ||
sequence[4]`. The sequence must not repeat for a session/key. An explicit
nonce is permitted only for deterministic test vectors and handshake frames.

## Replay and failure rules

Each receiver owns a replay window per session. It accepts a new high sequence
and up to 63 not-yet-seen earlier packets, and rejects duplicates or packets
more than 63 behind the high watermark. A new session ID resets its window.
Malformed, wrong-version, wrong-kind, oversized, nonce-length, authentication,
and replay errors are terminal for the individual frame; they never alter
audio routing or grant an approval action.

Wi-Fi control is sent over an authenticated TCP connection using the same
payload/sequence semantics. `CCW2` already provides application-layer
confidentiality and integrity, so this implementation does not claim TLS; a
future TLS layer may be added without changing the inner wire format.

## UDP audio transport

After the TCP handshake succeeds, the device sends audio datagrams to UDP port
`49154` on the authenticated TCP peer IPv4 address. The Mac binds that port
before advertising the TCP service and accepts packets only from the current
peer address, session ID and audio key. Failure to create either UDP endpoint
keeps Wi-Fi out of the microphone route so the next PTT can use BLE instead.

Each datagram contains exactly one encrypted 20 ms PCM frame and is 698 bytes,
which stays below the normal LAN MTU. Audio has its own session-wide UInt32
sequence. It does not reset at PTT boundaries because doing so would reuse the
`sessionID || sequence` AEAD nonce; reconnecting and deriving a fresh audio key
is required before it may reset.

The Mac buffers 60 ms for reordering, retains at most 100 ms of authenticated
audio that races ahead of PTT_DOWN, and accepts the 200 ms post-release tail.
A missing frame becomes 20 ms of silence. Duplicate, replayed, late, wrong-peer
and unauthenticated datagrams are dropped. A 500 ms interval without any valid
frame aborts the active Wi-Fi voice session.

For the initial TCP implementation, each CCW2 control packet is preceded by a
2-byte big-endian packet length. Length zero or a length above 826 bytes closes
the TCP connection. This prefix only resolves TCP stream boundaries; the CCW2
header length is still authenticated and authoritative.
