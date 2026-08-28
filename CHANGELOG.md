## Unreleased

* Repurposed this fork of DiveNote/dive_computer as the dive-computer sync
  bridge for the Petousis/Nautilus Dive Log app; README rewritten to reflect
  that purpose, current platform support, and the Bluetooth/BLE transport
  gap (only USB/serial is implemented so far).
* BLE: recognise Mares (BlueLink Pro dongle / Genius) and Cressi (Goa
  family) dive computers during a scan. GATT service UUIDs and advertised
  name patterns are derived from Subsurface and not yet hardware-verified.

## 0.0.1

* Initial release
