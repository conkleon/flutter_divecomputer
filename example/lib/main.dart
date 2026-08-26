import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dive_computer/dive_computer.dart';
import 'package:universal_ble/universal_ble.dart';

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

/// Tier 0 smoke test for `package:universal_ble` on this platform: raw
/// scan/connect/discoverServices with no bridge code in between. Read-only —
/// this must never write to a characteristic, since the test target is a
/// real device we don't control the firmware of.
///
/// Kept in place beyond its initial manual-gate use: a later task extends
/// this same screen.
class BleDebugScreen extends StatefulWidget {
  const BleDebugScreen({super.key});

  @override
  State<BleDebugScreen> createState() => _BleDebugScreenState();
}

class _BleDebugScreenState extends State<BleDebugScreen> {
  final List<String> _log = [];
  final Map<String, BleDevice> _found = {};

  void _print(String line) {
    setState(() => _log.insert(0, line));
    // ignore: avoid_print
    print('[BleDebug] $line');
  }

  void _startScan() {
    _found.clear();
    UniversalBle.onScanResult = (device) {
      if (_found.containsKey(device.deviceId)) return;
      _found[device.deviceId] = device;
      _print('Found: ${device.name ?? "(unnamed)"} [${device.deviceId}] '
          'rssi=${device.rssi}');
    };
    UniversalBle.startScan();
    _print('Scan started');
  }

  Future<void> _connectAndInspect(BleDevice device) async {
    try {
      _print('Connecting to ${device.name}...');
      await device.connect();
      _print('Connected. Discovering services (read-only)...');
      final services = await device.discoverServices();
      for (final service in services) {
        _print('Service ${service.uuid}');
        for (final characteristic in service.characteristics) {
          _print('  Characteristic ${characteristic.uuid}');
        }
      }
      await device.disconnect();
      _print('Disconnected.');
    } catch (e) {
      _print('ERROR: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ElevatedButton(
                  onPressed: _startScan, child: const Text('Start scan')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => UniversalBle.stopScan(),
                child: const Text('Stop scan'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final device in _found.values)
                ListTile(
                  title: Text(device.name ?? '(unnamed)'),
                  subtitle: Text(device.deviceId),
                  trailing: TextButton(
                    onPressed: () => _connectAndInspect(device),
                    child: const Text('Connect (read-only)'),
                  ),
                ),
              const Divider(),
              for (final line in _log) Text(line),
            ],
          ),
        ),
      ],
    );
  }
}
