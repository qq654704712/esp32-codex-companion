# Codex Companion Recovery Pairing v2

Pairing binds a particular ESP32-S3 companion and Mac agent without trusting
local Wi-Fi discovery alone.

1. The person opens **LINK CENTER → Recovery Pairing** on the device and
   chooses the device from the Companion app.
2. Both sides create fresh ephemeral exchange material, exchange their
   long-lived public identity, and display the same short SAS.
3. The person confirms the SAS on both sides. The SAS only detects an active
   interception; it is not a password and is not persisted as a credential.
4. The authenticated exchange produces a 32-byte `pairingSecret`. Device and
   Mac store it with the peer identity and a stable host ID. Only this record
   can create Wi-Fi session keys described in `wifi_transport.md`.

BLE is allowed to carry this recovery exchange and an encrypted Wi-Fi endpoint
handoff. It is not presented as BLE Audio or HFP. mDNS is merely a candidate
discovery mechanism: a discovered host must already be paired or complete this
flow before it can control the device or receive audio.

The device can list, unpair, and revoke individual host records in LINK CENTER.
Resetting network credentials never silently removes a paired host; factory
reset requires a local confirmation and removes both classes of secrets.
