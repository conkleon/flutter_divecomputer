# flutter_divecomputer

A Flutter plugin that bridges dive computers to Flutter apps. It talks to the
device over USB/serial (and, longer term, Bluetooth Classic/BLE) using
[libdivecomputer](https://www.libdivecomputer.org/), and hands back typed Dart
dive logs — depth/temperature profiles, gas mixes, tank pressures, samples,
and events.

This plugin was built to help flutter app interface with divewatches: plug in or pair a dive
computer, pull its stored dives, and hand them to the app to store and sync.
It started as a fork of [DiveNote/dive_computer](https://divenote.app) and is
now maintained standalone for that purpose.

## Purpose

Most dive computers store logged dives on-device and only expose them through
a manufacturer-specific USB cable or, on newer models, Bluetooth. This plugin
exists to hide that mess behind one Dart API:

1. Enumerate the dive computers `libdivecomputer` knows how to talk to.
2. Open a connection to one over whichever transport it supports.
3. Download and parse its dive log into plain Dart objects
   (`Computer`, `Dive`, `Sample`, `Gasmix`, `Tank`, ...).

The rest of the app (Nautilus Dive Log or otherwise) never has to know about
vendor protocols, serial ports, or native memory — it just gets a
`Future<List<Dive>>`.

## Platform support

| Platform | Status | Notes |
|---|---|---|
| Windows | ✅ Supported | Native `libdivecomputer` DLL bundled (`native/lib/windows_x64`). Primary desktop target. |
| Android | ✅ Supported | Native `.so` bundled for `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`. USB access requires USB-OTG/host mode; BLE is the practical path for most phones (see [Roadmap](#roadmap)). Primary mobile target. |
| macOS | ⚠️ Builds, untested as a target | Native `.dylib` bundled (universal + per-arch). Not an actively targeted platform for the app, but kept working since libdivecomputer supports it. |
| iOS | ⚠️ Declared, not functional | `pubspec.yaml` registers it as an FFI plugin, but no iOS native binary is built/bundled yet. |
| Web | ❌ Not supported | `libdivecomputer` is a native C library invoked via `dart:ffi` in a background `Isolate`. Browsers can't load native code or spawn OS isolates, so the web build compiles against a stub (`dive_computer_unsupported.dart`) whose methods all throw `UnimplementedError`. Bringing dive-computer sync to the web build would mean a separate implementation on top of the [Web Bluetooth](https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API)/[Web Serial](https://developer.mozilla.org/en-US/docs/Web/API/Web_Serial_API) APIs, not this plugin's FFI path. |

## Roadmap

- **USB/serial transport — done.** `ComputerTransport.serial` is implemented
  end-to-end (`DiveComputerFfi.download` → `_connectSerial`) and can already
  enumerate ports and download/parse dives.
- **Bluetooth (Classic + BLE) transport — not implemented yet.** This is the
  main gap and the main goal: most current-generation dive computers sync
  over BLE rather than a cable. `ComputerTransport.bluetooth` and `.ble`
  already exist in the type model (`lib/types/computer.dart`), and the
  vendored libdivecomputer headers include `bluetooth.h`/`ble.h`
  (`native/include/libdivecomputer/`), but:
  - `ffigen.yaml` doesn't list those headers as entry-points yet, so no
    Bluetooth bindings are generated into
    `dive_computer_ffi_bindings_generated.dart`.
  - `DiveComputerFfi.download`'s transport switch only has a `serial` case;
    `bluetooth`/`ble` fall through to `UnimplementedError`.
  - libdivecomputer expects the *host app* to own the Bluetooth stack and
    feed it bytes through an `dc_custom_iostream` (or platform BLE/RFCOMM
    APIs) — unlike serial, there's no libdivecomputer-provided cross-platform
    transport to bind to. That plumbing (Windows BLE via WinRT, Android BLE
    via `BluetoothGatt`) is what's missing.
- iOS native binaries (build/bundle `libdivecomputer` for iOS) — not started,
  not currently prioritized.
- Web — out of scope for this plugin; would need a Web Bluetooth/Web Serial
  implementation behind the same `DiveComputerInterface`.

## How it works

- `DiveComputerFfi` (`lib/framework/dive_computer_ffi.dart`) wraps the native
  `libdivecomputer` C API via `dart:ffi`. Bindings are generated with
  [`ffigen`](https://pub.dev/packages/ffigen) from the vendored headers in
  `native/include/libdivecomputer/` — regenerate with:
  ```
  flutter pub run ffigen --config ffigen.yaml
  ```
- Because `libdivecomputer` calls are blocking, `DiveComputer`
  (`lib/framework/dive_computer_isolate.dart`) spawns a background `Isolate`
  and proxies `openConnection` / `closeConnection` / `supportedComputers` /
  `download` calls to it, so the UI thread never blocks on device I/O.
- On web, `dive_computer.dart` conditionally exports
  `dive_computer_unsupported.dart` instead (see [Platform
  support](#platform-support)).
- Downloaded dives are parsed field-by-field and sample-by-sample from
  libdivecomputer's callback-based parser API into the plain Dart types in
  `lib/types/dive.dart`.

## Usage

```dart
import 'package:dive_computer/dive_computer.dart';

final dc = DiveComputer.instance;
dc.openConnection();

final computers = await dc.supportedComputers;
final dives = await dc.download(
  computers.first,
  computers.first.transports.first, // currently must be ComputerTransport.serial
  lastKnownFingerprint, // optional: only download dives newer than this
);

dc.closeConnection();
```

See `example/lib/main.dart` for a minimal runnable app that lists supported
computers and downloads dives from one on tap.

## Installation

From the plugin directory:

```
flutter pub get
```

To run the example app:

```
cd example
flutter run -d windows   # or -d android, -d macos
```

---

### Acknowledgements

This project is a fork of the Flutter plugin
[DiveNote/dive_computer](https://divenote.app) by Sebastian Schneider,
repurposed to sync dive logs into the Petousis/Nautilus Dive Log app.

Parts of this project use the library
[libdivecomputer](https://www.libdivecomputer.org/).

> libdivecomputer Copyright (c) 2008 Jef Driesen

<sup>The library is licensed under the GNU Lesser General Public License version 2.1.</sup>
