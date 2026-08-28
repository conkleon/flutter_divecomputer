import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dive_computer/dive_computer.dart';
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

    dc.enableDebugLogging();
    dc.openConnection();

    supportedComputers = dc.supportedComputers;
  }

  @override
  void dispose() {
    dc.closeConnection();
    super.dispose();
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
                Tab(text: 'Serial computers'),
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
                                return GestureDetector(
                                  onTap: () async {
                                    final dives = await dc.download(
                                      computer,
                                      computer.transports.first,
                                      "exampleFingerprint",
                                    );
                                    // ignore: use_build_context_synchronously
                                    ScaffoldMessenger.of(context)
                                        .showSnackBar(
                                      SnackBar(
                                        content: Text(
                                            'Downloaded ${dives.length} dives'),
                                      ),
                                    );
                                  },
                                  child: Text(computer.toString()),
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

  void _print(String line) {
    if (mounted) setState(() => _log.insert(0, line));
    // ignore: avoid_print
    print('[BleDebug] $line');
  }

  Future<void> _startScan() async {
    try {
      await UniversalBle.requestPermissions();
    } catch (e) {
      _print('Permission request failed: $e');
      return;
    }
    _scanSub?.cancel();
    setState(() => _found.clear());
    _print('Scan started');
    _scanSub = dc.scanForBleDevices().listen(
      (result) {
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
      _print('Connecting to ${device.name}...');
      await dc.connectBle(device);
      if (!mounted) return;
      _print('Connected. Downloading full dive log as $computer ...');
      final dives = await dc.download(computer, ComputerTransport.ble);
      if (!mounted) return;
      setState(() => _dives = dives);
      _print('Downloaded ${dives.length} dives — full dump follows');
      for (final dive in dives) {
        for (final line in describeDiveVerbose(dive)) {
          _print(line);
        }
      }
    } catch (e) {
      _print('ERROR: $e');
    } finally {
      try {
        await dc.disconnectBle();
        _print('Disconnected.');
      } catch (e) {
        _print('Disconnect error (ignored): $e');
      }
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(8),
            children: [
              const Text('Found devices',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (final device in _found.values)
                ListTile(
                  dense: true,
                  selected: identical(device, _selectedDevice),
                  title: Text(device.name.isEmpty ? '(unnamed)' : device.name),
                  subtitle: Text('${device.id}  rssi=${device.rssi}  ·  '
                      '${device.profile?.vendorHint ?? "?"}'),
                  onTap: () => _selectDevice(device),
                ),
              const Divider(),
              Text('Dives (${_dives.length})',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              for (final dive in _dives)
                Card(
                  child: ListTile(
                    dense: true,
                    title: Text(formatDiveSummary(dive)),
                    onTap: () {
                      for (final l in describeDiveVerbose(dive)) {
                        _print(l);
                      }
                    },
                  ),
                ),
              const Divider(),
              const Text('Log',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              for (final line in _log)
                Text(line,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}
