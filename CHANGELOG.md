## Unreleased

* Repurposed this fork of DiveNote/dive_computer as the dive-computer sync
  bridge for the Petousis/Nautilus Dive Log app; README rewritten to reflect
  that purpose, current platform support, and the Bluetooth/BLE transport
  gap (only USB/serial is implemented so far).
* BLE: recognise Mares (BlueLink Pro dongle / Genius), Cressi (Goa
  family) and Shearwater (Petrel 2, Perdix / AI / 2, NERD 2, Teric,
  Peregrine, Petrel 3, Tern, plus a separate Perdix 3 profile) dive
  computers during a scan. GATT service UUIDs and advertised name
  patterns are derived from Subsurface and not yet hardware-verified.
  The Bluetooth-Classic-only Shearwaters (original Predator / Petrel /
  NERD) are recognised but still need `ComputerTransport.bluetooth`,
  which is unimplemented; the Perdix 3 has no descriptor in the bundled
  libdivecomputer build yet, so its download can't resolve a backend.
* `download()` now returns the dive computer's complete log in all build
  modes. Debug builds previously stopped after 5 dives.
* Serial: `download()` takes an optional `serialPort` and a new
  `serialPorts(computer)` lists the ports libdivecomputer enumerates for a
  descriptor. Previously `_connectSerial` always opened the *first*
  enumerated COM port, which on Windows is non-deterministic and picks the
  wrong port when a Bluetooth-Classic dive computer (e.g. a Shearwater
  Petrel) is paired as a virtual COM port. The example app's "Serial /
  Bluetooth" tab now prompts for the port. `serialPorts` results are
  deduplicated (the iterator can report the same port twice).
* Bluetooth Classic (RFCOMM / SPP) transport — `ComputerTransport.bluetooth`
  is now implemented for **Windows** (via libdivecomputer's own
  `dc_bluetooth_open`, on the background isolate like the serial path) and
  **Android** (a Kotlin `BluetoothSocket` RFCOMM channel on the main isolate
  feeding libdivecomputer through the shared-memory isolate bridge and
  `dc_custom_open(DC_TRANSPORT_BLUETOOTH)`). This covers the
  Bluetooth-Classic-only Shearwaters — the original Predator, Petrel,
  Petrel 2, NERD and Perdix. New API: `DiveComputer.bluetoothDevices()`
  (paired/bonded devices) and `DiveComputer.requestBluetoothPermissions()`;
  `download()`'s `serialPort` parameter is generalised to `address` (COM port
  for serial, Bluetooth MAC for Windows bluetooth). Devices must be
  paired/bonded in the OS first — there is no in-app pairing or discovery. On
  Windows, a legacy device whose OS pairing fails mutual authentication will
  still fail to open; that is an OS/hardware matter, not a plugin one. The
  Android side's Kotlin has not yet been built/run on-device in this repo
  (the example app's Android Gradle toolchain predates the local JDK).

## 0.0.1

* Initial release
