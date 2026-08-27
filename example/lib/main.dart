import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dive_computer/dive_computer.dart';

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

  void _print(String line) {
    setState(() => _log.insert(0, line));
    // ignore: avoid_print
    print('[BleDebug] $line');
  }

  void _startScan() {
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

  Future<void> _connectAndDownload(BleScanResult device) async {
    try {
      _print('Connecting to ${device.name}...');
      await dc.connectBle(device);
      _print('Connected. Downloading...');
      final dives = await dc.download(
        Computer(device.profile?.vendorHint ?? 'Unknown',
            device.profile?.productHint ?? device.name),
        ComputerTransport.ble,
      );
      _print('Downloaded ${dives.length} dives');
    } catch (e) {
      _print('ERROR: $e');
    } finally {
      await dc.disconnectBle();
      _print('Disconnected.');
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton(
            onPressed: _startScan,
            child: const Text('Scan for known BLE devices'),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final device in _found.values)
                ListTile(
                  title: Text(device.name.isEmpty ? '(unnamed)' : device.name),
                  subtitle: Text('${device.id}  rssi=${device.rssi}'),
                  trailing: TextButton(
                    onPressed: () => _connectAndDownload(device),
                    child: const Text('Connect + download'),
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
