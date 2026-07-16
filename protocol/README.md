# Codex Companion Protocol v1

The wire protocol is shared by the ESP-IDF firmware and macOS Companion.
Control data uses canonical CBOR plus a 16-byte truncated HMAC-SHA256 tag.
Audio uses independent IMA-ADPCM blocks so one lost BLE notification cannot
poison later frames.

- [Wire specification](specification.md)
- [Golden control envelope](golden/control-envelope-v1.hex)

The Swift and C test suites both assert the golden envelope bytes. BLE control
packets up to 512 bytes are split into MTU-safe 244-byte GATT values and are
reassembled before CBOR/HMAC verification.
