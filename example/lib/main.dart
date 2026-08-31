import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:dive_computer/dive_computer.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:universal_ble/universal_ble.dart';

import 'ble_download_support.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final dc = DiveComputer.instance;

  late final Future<List<Computer>> supportedComputers;

  @override
  void initState() {
    super.initState();

    // dc.enableDebugLogging();  // FINEST logs every sample — kills throughput
    //                              on a big transfer. Uncomment to debug.
    dc.openConnection();

    supportedComputers = dc.supportedComputers;
  }

  @override
  void dispose() {
    dc.closeConnection();
    super.dispose();
  }

  /// Download from a serial/USB dive computer. For a serial transport (which
  /// includes Bluetooth-Classic computers paired as a virtual COM port, e.g. a
  /// Shearwater Petrel on Windows) this first asks libdivecomputer which ports
  /// exist and lets the user pick — the plugin no longer guesses.
  Future<void> _downloadFrom(BuildContext context, Computer computer) async {
    final messenger = ScaffoldMessenger.of(context);
    final hasSerial = computer.transports.contains(ComputerTransport.serial);
    final hasBluetooth =
        computer.transports.contains(ComputerTransport.bluetooth);
    final ComputerTransport transport;
    if (hasSerial && hasBluetooth) {
      final picked = await showDialog<ComputerTransport>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Connect over serial or Bluetooth?'),
          children: [
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, ComputerTransport.serial),
              child: const Text('Serial (cable / COM port)'),
            ),
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, ComputerTransport.bluetooth),
              child: const Text('Bluetooth (paired device)'),
            ),
          ],
        ),
      );
      if (picked == null) return; // dialog dismissed
      transport = picked;
    } else {
      transport = computer.transports.first;
    }
    String? serialPort;
    try {
      if (transport == ComputerTransport.bluetooth) {
        if (!await dc.requestBluetoothPermissions()) {
          messenger.showSnackBar(const SnackBar(
              content: Text('Bluetooth permission denied')));
          return;
        }
        final bonded = await dc.bluetoothDevices(computer);
        if (bonded.isEmpty) {
          messenger.showSnackBar(const SnackBar(
              content: Text('No paired Bluetooth devices — pair the dive '
                  'computer in system Bluetooth settings first')));
          return;
        }
        if (!context.mounted) return;
        final candidates = bluetoothCandidates(
            isShearwater: computer.vendor.toLowerCase() == 'shearwater',
            bonded: bonded);
        final shown = candidates.isEmpty ? bonded : candidates;
        final picked = shown.length == 1
            ? shown.single
            : await showDialog<BtDevice>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Which paired device?'),
                  children: [
                    for (final d in shown)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, d),
                        child: Text('${d.name}  (${d.address})'),
                      ),
                  ],
                ),
              );
        if (picked == null) return;
        if (!context.mounted) return;
        // A persistent status dialog — snackbars auto-dismiss and are easy to
        // miss, and the BT download can take a while / stall.
        final status = ValueNotifier<String>(
            'Connecting to ${picked.name} (${picked.address})…\n'
            'Make sure the Petrel is on its Bluetooth screen.');
        var dialogOpen = true;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AlertDialog(
            title: const Text('Bluetooth download'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<String>(
                  valueListenable: status,
                  builder: (_, s, __) => Text(s),
                ),
                const SizedBox(height: 16),
                StreamBuilder<SyncProgress>(
                  stream: dc.syncProgress,
                  builder: (_, snap) {
                    final f = snap.data?.fraction;
                    return LinearProgressIndicator(value: f);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  dialogOpen = false;
                  Navigator.of(context).pop();
                },
                child: const Text('Close'),
              ),
            ],
          ),
        ).then((_) => dialogOpen = false);
        // Stream each parsed dive straight to a file, one JSON object per line
        // (JSONL). A mid-transfer disconnect then still leaves every dive so
        // far on disk instead of losing the whole run.
        final dir = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
        final outFile = File('${dir.path}/petrel_dives.jsonl');
        // Resume-ish: keep what's already in the file, tell the plugin which
        // dive hashes we have so it skips re-parsing them, and only append
        // the new ones.
        final known = <String>{};
        if (await outFile.exists()) {
          for (final line in await outFile.readAsLines()) {
            if (line.trim().isEmpty) continue;
            try {
              known.add(jsonDecode(line)['hash'] as String);
            } catch (_) {/* partial trailing line */}
          }
        }
        var count = known.length;
        var lastDrained = DateTime.now();
        final pending = StringBuffer();
        status.value = known.isEmpty
            ? 'Opening connection…\nKeep the Petrel on its BT screen, screen on.'
            : 'Resuming — ${known.length} dives already saved.\n'
                'Opening connection…';
        final sub = dc.diveStream.listen((dive) {
          count++;
          pending.writeln(jsonEncode(dive.toJson()));
          // Flush every ~2s or every 20 dives — cheap, and bounds loss.
          final now = DateTime.now();
          if (count % 20 == 0 ||
              now.difference(lastDrained) > const Duration(seconds: 2)) {
            outFile.writeAsStringSync(pending.toString(), mode: FileMode.append);
            pending.clear();
            lastDrained = now;
          }
        });
        final progressSub = dc.syncProgress.listen((p) {
          status.value = switch (p.phase) {
            SyncPhase.connecting =>
              'Connecting…\nKeep the Petrel on its BT screen.',
            SyncPhase.reading => p.fraction != null
                ? 'Downloading… ${(p.fraction! * 100).toStringAsFixed(0)}%  '
                    '(${p.divesParsed} dives)'
                : 'Downloading… ${p.divesParsed} dives',
            SyncPhase.parsing => 'Downloading… ${p.divesParsed} dives saved\n'
                '→ ${outFile.path}',
            SyncPhase.done => 'Finishing…',
          };
        });
        try {
          final result = await dc.sync(SyncRequest(
            computer: computer,
            transport: ComputerTransport.bluetooth,
            endpoint: picked.address,
            knownFingerprints: known,
          ));
          if (pending.isNotEmpty) {
            outFile.writeAsStringSync(pending.toString(), mode: FileMode.append);
          }
          status.value = switch (result.status) {
            SyncStatus.failed => 'Stopped at $count dives: ${result.error}\n'
                'Re-run — it skips what is already saved.',
            _ => 'Done — $count dives '
                '(${result.divesParsed} new, ${result.divesSkipped} skipped).\n'
                'Saved to:\n${outFile.path}',
          };
        } finally {
          await sub.cancel();
          await progressSub.cancel();
        }
        // Offer to share the file regardless of success/failure.
        if (await outFile.exists() && await outFile.length() > 0) {
          try {
            await SharePlus.instance.share(
              ShareParams(files: [XFile(outFile.path)], text: 'Petrel dive log'),
            );
          } catch (_) {/* sharing is best-effort */}
        }
        if (dialogOpen && context.mounted) {
          // leave the result on screen; user taps Close
        }
        return;
      }
      if (transport == ComputerTransport.serial) {
        final ports = await dc.serialPorts(computer);
        if (ports.isEmpty) {
          messenger.showSnackBar(const SnackBar(
              content: Text('No serial ports found — pair the computer and '
                  'put it on its Bluetooth/upload screen, then retry.')));
          return;
        }
        if (!context.mounted) return;
        serialPort = ports.length == 1
            ? ports.single
            : await showDialog<String>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Which serial port is the dive computer?'),
                  children: [
                    for (final p in ports)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(context, p),
                        child: Text(p),
                      ),
                  ],
                ),
              );
        if (serialPort == null) return; // dialog dismissed
      }
      final result = await dc.sync(SyncRequest(
        computer: computer,
        transport: transport,
        endpoint: serialPort,
        lastFingerprint: 'exampleFingerprint',
      ));
      messenger.showSnackBar(SnackBar(
          content: Text('Synced ${result.divesParsed} dives '
              '(${result.status.name})')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('libdivecomputer ffi example'),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Serial / Bluetooth'),
                Tab(text: 'BLE debug'),
              ],
            ),
          ),
          body: TabBarView(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Supported dive computers:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                        )),
                    const SizedBox(height: 10),
                    Expanded(
                      child: FutureBuilder(
                        future: supportedComputers,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Text('Error: ${snapshot.error}');
                          }

                          if (snapshot.hasData) {
                            final computers = snapshot.data as List<Computer>;
                            return ListView.builder(
                              itemCount: computers.length,
                              itemBuilder: (context, index) {
                                final computer = computers[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(computer.toString()),
                                  onTap: () => _downloadFrom(context, computer),
                                );
                              },
                            );
                          }

                          return const Text('Loading...');
                        },
                      ),
                    ),
                  ],
                ),
              ),
              const BleDebugScreen(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tier 2 manual test screen: drives the real `DiveComputer` BLE API end to
/// end — scan (filtered to recognized devices), connect, download, disconnect.
///
/// `openConnection()` is owned by `_MyAppState` for the whole app, so this
/// screen just uses `DiveComputer.instance` directly.
class BleDebugScreen extends StatefulWidget {
  const BleDebugScreen({super.key});

  @override
  State<BleDebugScreen> createState() => _BleDebugScreenState();
}

class _BleDebugScreenState extends State<BleDebugScreen> {
  final dc = DiveComputer.instance;
  final List<String> _log = [];
  final Map<String, BleScanResult> _found = {};
  StreamSubscription<BleScanResult>? _scanSub;

  List<Computer> _supported = const [];
  BleScanResult? _selectedDevice;
  Computer? _selectedComputer;
  List<Dive> _dives = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    DiveComputer.instance.supportedComputers.then((c) {
      if (!mounted) return;
      setState(() {
        _supported = c;
        final device = _selectedDevice;
        if (device != null && _selectedComputer == null) {
          _selectedComputer = defaultComputerFor(device, c);
        }
      });
    });
  }

  /// A realistic dive log is tens of thousands of verbose lines; cap what the
  /// in-memory console keeps so the widget tree and the O(n) inserts stay
  /// bounded.
  static const _maxLogLines = 2000;

  void _print(String line) {
    // ignore: avoid_print
    print('[BleDebug] $line');
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > _maxLogLines) {
        _log.removeRange(_maxLogLines, _log.length);
      }
    });
  }

  /// Batch variant of [_print] for bulk dumps: one `setState` and one cap
  /// trim for the whole batch instead of one per line.
  void _printAll(List<String> lines) {
    for (final l in lines) {
      // ignore: avoid_print
      print('[BleDebug] $l');
    }
    if (!mounted) return;
    setState(() {
      _log.insertAll(0, lines.reversed);
      if (_log.length > _maxLogLines) {
        _log.removeRange(_maxLogLines, _log.length);
      }
    });
  }

  Future<void> _startScan() async {
    try {
      await UniversalBle.requestPermissions();
    } catch (e) {
      _print('Permission request failed: $e');
      return;
    }
    if (!mounted) return;
    await _scanSub?.cancel();
    setState(() => _found.clear());
    _print('Scan started');
    _scanSub = dc.scanForBleDevices().listen(
      (result) {
        if (!mounted) return;
        setState(() => _found[result.id] = result);
        _print('Found: $result');
      },
      onError: (Object e) => _print('SCAN ERROR: $e'),
    );
  }

  void _selectDevice(BleScanResult d) {
    setState(() {
      _selectedDevice = d;
      _selectedComputer = defaultComputerFor(d, _supported);
      _dives = const [];
    });
  }

  Future<void> _connectAndDownload() async {
    final device = _selectedDevice;
    final computer = _selectedComputer;
    if (device == null) return;
    if (computer == null) {
      _print('No libdivecomputer descriptor for '
          '${device.profile?.vendorHint ?? "this device"} — is the plugin '
          'connection open?');
      return;
    }
    setState(() => _busy = true);
    try {
      // An untimed LE scan running alongside a GATT transfer degrades
      // throughput/stability on Android. Stopping it clears universal_ble's
      // seen-device cache, so tell the user the found list is now stale.
      // sync() owns the connection lifecycle now, so stop the scan first.
      await _scanSub?.cancel();
      _scanSub = null;
      _print('Scan stopped for transfer. Re-scan to connect again.');
      _print('Connecting + downloading ${device.name} as $computer ...');
      final dives = <Dive>[];
      final sub = dc.diveStream.listen(dives.add);
      try {
        final result = await dc.sync(SyncRequest(
          computer: computer,
          transport: ComputerTransport.ble,
          endpoint: device.id,
        ));
        _print('Sync ${result.status.name}: ${result.divesParsed} dives');
      } finally {
        await sub.cancel();
      }
      if (!mounted) return;
      setState(() => _dives = dives);
      _printAll([
        for (final dive in dives) ...describeDiveVerbose(dive),
      ]);
    } catch (e) {
      _print('ERROR: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  Widget _selectedDevicePanel(BleScanResult device) {
    final candidates = candidateComputersFor(device, _supported);
    final vendor = device.profile?.vendorHint ?? 'matching';
    final dropdownValue =
        candidates.contains(_selectedComputer) ? _selectedComputer : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Selected: ${device.name.isEmpty ? "(unnamed)" : device.name}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          if (candidates.isEmpty)
            Text('No BLE-capable $vendor descriptor found in libdivecomputer')
          else
            DropdownButton<Computer>(
              isExpanded: true,
              value: dropdownValue,
              hint: const Text('Choose descriptor'),
              items: [
                for (final c in candidates)
                  DropdownMenuItem<Computer>(
                    value: c,
                    child: Text('${c.vendor} ${c.product}'),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _selectedComputer = v),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton(
              onPressed: _busy ? null : _connectAndDownload,
              child: const Text('Connect & download'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedDevice = _selectedDevice;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton(
              onPressed: _busy ? null : _startScan,
              child: const Text('Scan for Mares / Cressi'),
            ),
          ),
        ),
        if (selectedDevice != null) _selectedDevicePanel(selectedDevice),
        // Top region: found devices + downloaded dives, one scroll view.
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              const Text('Found devices',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (final device in _found.values)
                ListTile(
                  dense: true,
                  // The scan replaces the BleScanResult object on every
                  // advertisement, so match on id, not identity.
                  selected: device.id == _selectedDevice?.id,
                  title: Text(device.name.isEmpty ? '(unnamed)' : device.name),
                  subtitle: Text('${device.id}  rssi=${device.rssi}  ·  '
                      '${device.profile?.vendorHint ?? "?"}'),
                  onTap: _busy ? null : () => _selectDevice(device),
                ),
              const Divider(),
              Text('Dives (${_dives.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              for (final dive in _dives)
                Card(
                  child: ListTile(
                    dense: true,
                    title: Text(formatDiveSummary(dive)),
                    onTap: () => _printAll(describeDiveVerbose(dive)),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child:
                Text('Log', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        // Bottom region: the console, lazily built and bounded.
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: _log.length,
            itemBuilder: (context, i) => Text(
              _log[i],
              style: const TextStyle(
                  fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}
