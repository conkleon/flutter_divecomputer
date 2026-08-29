import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:developer' as developer;

import 'package:dive_computer/framework/ble/ble_bridge_callbacks.dart';
import 'package:dive_computer/framework/ble/ble_bridge_state.dart';
import 'package:dive_computer/framework/utils/serial_ports.dart';
import 'package:dive_computer/framework/utils/transports_bitmask.dart';
import 'package:dive_computer/types/bt_device.dart';
import 'package:dive_computer/types/computer.dart';
import 'package:dive_computer/types/dive.dart';
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart' as logging;

import 'dive_computer_ffi_bindings_generated.dart';

final log = logging.Logger('DiveComputerFfi');

/// Logger used by the BLE bridge callbacks on the background isolate.
final bleBridgeLog = logging.Logger('BleBridge');

/// Logger used by [BleTransport] on the main isolate.
final bleTransportLog = logging.Logger('BleTransport');

final _forwardedLoggers = <String>{};

/// Pipes [logger]'s records to `dart:developer`'s `log()` so they show up in
/// the Flutter/DevTools console. Idempotent per isolate.
void forwardLoggerToDeveloperLog(logging.Logger logger) {
  if (!_forwardedLoggers.add(logger.fullName)) return;
  logger.onRecord.listen((e) {
    developer.log(
      e.message,
      time: e.time,
      sequenceNumber: e.sequenceNumber,
      level: e.level.value,
      name: e.loggerName,
      zone: e.zone,
      error: e.error,
      stackTrace: e.stackTrace,
    );
  });
}

/// Foreign function interface for libdivecomputer.
///
/// Warning: This class performs blocking operations and should only be used in
/// an isolate.
class DiveComputerFfi {
  static void initialize() {
    logging.hierarchicalLoggingEnabled = true;
    forwardLoggerToDeveloperLog(log);
    // BleBridge runs on this (background) isolate; without its own forwarder
    // its records go to a root logger nobody subscribes to.
    forwardLoggerToDeveloperLog(bleBridgeLog);

    String fileName;
    if (Platform.isWindows) {
      fileName = 'libdivecomputer-0.dll';
    } else if (Platform.isAndroid) {
      fileName = 'libdivecomputer.so';
    } else if (Platform.isMacOS) {
      fileName = 'libdivecomputer.0.dylib';
    } else {
      throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
    }

    log.config('Loading native library');
    _library = ffi.DynamicLibrary.open(fileName);
    _bindings = DiveComputerFfiBindings(_library);
    log.fine('Loading complete');
  }

  static final context = calloc<ffi.Pointer<dc_context_t>>();

  static late final ffi.DynamicLibrary _library;
  static late DiveComputerFfiBindings _bindings;

  static final _computerDescriptorCache =
      <Computer, ffi.Pointer<dc_descriptor_t>>{};
  static final _divesCache = <Dive>[];

  static Function(List<Dive>)? divesCallback;

  /// One switch for every logger owned by this isolate — the FFI layer and
  /// the BLE bridge callbacks.
  static void enableDebugLogging([logging.Level level = logging.Level.INFO]) {
    log.level = level;
    bleBridgeLog.level = level;
  }

  static void openConnection() {
    _handleResult(
      _bindings.dc_context_new(context),
      'context creation',
    );

    _handleResult(
      _bindings.dc_context_set_loglevel(
        context.value,
        dc_loglevel_t.DC_LOGLEVEL_WARNING,
      ),
      'log level setting',
    );

    _handleResult(
      _bindings.dc_context_set_logfunc(
        context.value,
        ffi.Pointer.fromFunction(_log),
        ffi.nullptr,
      ),
      'log function setting',
    );
  }

  static void closeConnection() {
    _handleResult(
      _bindings.dc_context_free(context.value),
      'context freeing',
    );
    _computerDescriptorCache.values.forEach(_bindings.dc_descriptor_free);
    _computerDescriptorCache.clear();
  }

  static List<Computer> get supportedComputers {
    if (_computerDescriptorCache.isNotEmpty) {
      return _computerDescriptorCache.keys.toList();
    }

    final iterator = calloc<ffi.Pointer<dc_iterator_t>>();

    _handleResult(
      _bindings.dc_descriptor_iterator(iterator),
      'iterator creation',
    );

    int result;
    final desc = calloc<ffi.Pointer<dc_descriptor_t>>();
    while ((result = _bindings.dc_iterator_next(iterator.value, desc.cast())) ==
        dc_status_t.DC_STATUS_SUCCESS) {
      final ffi.Pointer<Utf8> vendor =
          _bindings.dc_descriptor_get_vendor(desc.value).cast();
      final ffi.Pointer<Utf8> product =
          _bindings.dc_descriptor_get_product(desc.value).cast();
      final transports = parseTransportsBitmask(
          _bindings.dc_descriptor_get_transports(desc.value));

      final computer = Computer(
        vendor.toDartString(),
        product.toDartString(),
        transports: transports,
      );
      _computerDescriptorCache.addEntries([MapEntry(computer, desc.value)]);
    }
    _handleResult(result, 'iterator next');

    _handleResult(
      _bindings.dc_iterator_free(iterator.value),
      'iterator freeing',
    );

    // Return the deduped cache keys, matching every subsequent call: the
    // iterator can yield duplicate vendor+product descriptors, and duplicate
    // Computers assert in a DropdownButton in debug builds.
    return _computerDescriptorCache.keys.toList();
  }

  /// The serial ports libdivecomputer enumerates for [computer]'s descriptor,
  /// deduplicated. On Windows this includes virtual COM ports for paired
  /// Bluetooth-Classic dive computers (e.g. a Shearwater Petrel). The caller
  /// passes the chosen one back to [download] as `address`.
  static List<String> serialPorts(Computer computer) {
    final descriptor = _computerDescriptorCache[computer];
    if (descriptor == null) {
      throw ArgumentError(
          'Unknown computer $computer — call supportedComputers first');
    }
    return _enumerateSerialPorts(descriptor);
  }

  /// Bluetooth-Classic devices libdivecomputer sees as paired for [computer]'s
  /// descriptor. Windows only — Android goes through the RFCOMM channel.
  static List<BtDevice> bluetoothDevices(Computer computer) {
    final descriptor = _computerDescriptorCache[computer];
    if (descriptor == null) {
      throw ArgumentError(
          'Unknown computer $computer — call supportedComputers first');
    }

    final iterator = calloc<ffi.Pointer<dc_iterator_t>>();
    _handleResult(
      _bindings.dc_bluetooth_iterator_new(iterator, context.value, descriptor),
      'bluetooth iterator creation',
    );

    final devices = <BtDevice>[];
    int result;
    final dev = calloc<ffi.Pointer<dc_bluetooth_device_t>>();
    final strbuf = calloc<ffi.Char>(18); // DC_BLUETOOTH_SIZE
    try {
      while ((result = _bindings.dc_iterator_next(iterator.value, dev.cast())) ==
          dc_status_t.DC_STATUS_SUCCESS) {
        final namePtr = _bindings.dc_bluetooth_device_get_name(dev.value);
        final name = namePtr == ffi.nullptr
            ? ''
            : namePtr.cast<Utf8>().toDartString();
        final addr = _bindings.dc_bluetooth_device_get_address(dev.value);
        final addrStr = _bindings
            .dc_bluetooth_addr2str(addr, strbuf, 18)
            .cast<Utf8>()
            .toDartString();
        devices.add(BtDevice(name, addrStr));
        _bindings.dc_bluetooth_device_free(dev.value);
      }
      _handleResult(result, 'bluetooth iterator next');
    } finally {
      _handleResult(_bindings.dc_iterator_free(iterator.value), 'iterator free');
      calloc.free(strbuf);
      calloc.free(dev);
      calloc.free(iterator);
    }

    log.info('Bluetooth devices: '
        '${devices.map((d) => '${d.name} (${d.address})').join(', ')}');
    return devices;
  }

  static void download(
    Computer computer,
    ComputerTransport transport, [
    String? lastFingerprint,
    int? bleBridgeAddress,
    String? address,
  ]) {
    final computerDescriptor = _computerDescriptorCache[computer]!;

    final ffi.Pointer<dc_iostream_t> iostream;
    switch (transport) {
      case ComputerTransport.serial:
        iostream = _connectSerial(computerDescriptor, address);
        break;
      case ComputerTransport.ble:
        if (bleBridgeAddress == null) {
          throw ArgumentError(
              'ComputerTransport.ble requires a bleBridgeAddress');
        }
        iostream = _connectBle(bleBridgeAddress);
        break;
      default:
        throw UnimplementedError();
    }

    final device = calloc<ffi.Pointer<dc_device_t>>();
    try {
      _handleResult(
        _bindings.dc_device_open(
          device,
          context.value,
          computerDescriptor,
          iostream,
        ),
        'device open',
      );

      final customdata = calloc<_DiveCallbackUserdata>();
      customdata.ref.device = device.value;
      customdata.ref.lastFingerprint =
          lastFingerprint?.toNativeUtf8() ?? ffi.nullptr;

      _divesCache.clear();
      _handleResult(
        _bindings.dc_device_foreach(
          device.value,
          ffi.Pointer.fromFunction(_dive_callback, 0),
          customdata.cast(),
        ),
        'device foreach',
      );

      if (lastFingerprint != null) {
        _divesCache.removeWhere((e) => e.hash == lastFingerprint);
      }
      divesCallback?.call(_divesCache);

      _handleResult(
        _bindings.dc_device_close(device.value),
        'device close',
      );
    } finally {
      _handleResult(
        _bindings.dc_iostream_close(iostream),
        'iostream close',
      );
    }
  }

  static ffi.Pointer<dc_iostream_t> _connectBle(int bleBridgeAddress) {
    final bridge = BleBridge.fromAddress(bleBridgeAddress);
    final callbacks = calloc<dc_custom_cbs_t>();
    callbacks.ref
      ..set_timeout = BleBridgeCallbacks.setTimeoutPtr
      ..set_break = BleBridgeCallbacks.setBreakPtr
      ..set_dtr = BleBridgeCallbacks.setDtrPtr
      ..set_rts = BleBridgeCallbacks.setRtsPtr
      ..get_lines = BleBridgeCallbacks.getLinesPtr
      ..get_available = BleBridgeCallbacks.getAvailablePtr
      ..configure = BleBridgeCallbacks.configurePtr
      ..poll = BleBridgeCallbacks.pollPtr
      ..read = BleBridgeCallbacks.readPtr
      ..write = BleBridgeCallbacks.writePtr
      ..ioctl = BleBridgeCallbacks.ioctlPtr
      ..flush = BleBridgeCallbacks.flushPtr
      ..purge = BleBridgeCallbacks.purgePtr
      ..sleep = BleBridgeCallbacks.sleepPtr
      ..close = BleBridgeCallbacks.closePtr;

    final iostream = calloc<ffi.Pointer<dc_iostream_t>>();
    _handleResult(
      _bindings.dc_custom_open(
        iostream,
        context.value,
        dc_transport_t.DC_TRANSPORT_BLE,
        callbacks,
        bridge.pointer.cast(),
      ),
      'ble custom iostream open',
    );
    calloc.free(callbacks);
    return iostream.value;
  }

  /// Enumerates the serial ports libdivecomputer associates with [descriptor],
  /// deduplicated and in first-seen order. The iterator can yield the same
  /// COM port twice and in a non-deterministic order between calls.
  static List<String> _enumerateSerialPorts(
      ffi.Pointer<dc_descriptor_t> descriptor) {
    final iterator = calloc<ffi.Pointer<dc_iterator_t>>();

    _handleResult(
      _bindings.dc_serial_iterator_new(iterator, context.value, descriptor),
      'serial iterator creation',
    );

    final names = <String>[];

    int result;
    final desc = calloc<ffi.Pointer<dc_serial_device_t>>();
    while ((result = _bindings.dc_iterator_next(iterator.value, desc.cast())) ==
        dc_status_t.DC_STATUS_SUCCESS) {
      final ffi.Pointer<Utf8> name =
          _bindings.dc_serial_device_get_name(desc.value).cast();
      names.add(name.toDartString());

      _bindings.dc_serial_device_free(desc.value);
    }
    _handleResult(result, 'iterator next');

    _handleResult(
      _bindings.dc_iterator_free(iterator.value),
      'iterator freeing',
    );
    calloc.free(desc);
    calloc.free(iterator);

    return dedupeSerialPorts(names);
  }

  static ffi.Pointer<dc_iostream_t> _connectSerial(
      ffi.Pointer<dc_descriptor_t> computer,
      [String? serialPortName]) {
    final names = _enumerateSerialPorts(computer);
    log.info('Serial devices: ${names.join(', ')}');

    if (names.isEmpty) {
      _handleResult(dc_status_t.DC_STATUS_NODEVICE);
    }

    // Pick the caller's port, or the first enumerated one when unspecified.
    // A non-null serialPortName that isn't in the list throws ArgumentError.
    final chosen = selectSerialPort(names, requested: serialPortName);
    log.info('Opening serial port: $chosen');

    // ### Connecting to the device ### //
    final iostream = calloc<ffi.Pointer<dc_iostream_t>>();
    final chosenNative = chosen.toNativeUtf8();

    try {
      _handleResult(
        _bindings.dc_serial_open(
          iostream,
          context.value,
          chosenNative.cast(),
        ),
        'serial open',
      );
    } finally {
      calloc.free(chosenNative);
    }

    return iostream.value;
  }

  // ignore: unused_element  (wired into download() in the next task)
  static ffi.Pointer<dc_iostream_t> _connectBluetooth(
      ffi.Pointer<dc_descriptor_t> descriptor, String? address) {
    if (address == null || address.isEmpty) {
      throw ArgumentError('Bluetooth download requires a device address');
    }
    final addrNative = address.toNativeUtf8();
    final int64Addr = _bindings.dc_bluetooth_str2addr(addrNative.cast());
    calloc.free(addrNative);
    if (int64Addr == 0) {
      throw ArgumentError('Malformed Bluetooth address: $address');
    }
    log.info('Opening Bluetooth RFCOMM to $address');

    final iostream = calloc<ffi.Pointer<dc_iostream_t>>();
    _handleResult(
      // port 0 -> libdivecomputer resolves the SPP RFCOMM channel via SDP.
      _bindings.dc_bluetooth_open(iostream, context.value, int64Addr, 0),
      'bluetooth open (a DC_STATUS_NOACCESS here usually means the OS '
          'pairing failed mutual authentication — re-pair the device)',
    );
    return iostream.value;
  }

  // ignore: non_constant_identifier_names
  static int _dive_callback(
    ffi.Pointer<ffi.UnsignedChar> data,
    int size,
    ffi.Pointer<ffi.UnsignedChar> fingerprint,
    int fsize,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    final _DiveCallbackUserdata customdata =
        userdata.cast<_DiveCallbackUserdata>().ref;

    _parseDive(data, size, fingerprint, fsize, customdata.device.cast());

    String? lastFingerprint;
    String currentFingerprint = _buildFingerprintHash(fingerprint, fsize);
    if (customdata.lastFingerprint.address != ffi.nullptr.address) {
      lastFingerprint = customdata.lastFingerprint.cast<Utf8>().toDartString();
    }

    // non-zero to continue
    if (currentFingerprint == lastFingerprint) return 0;
    return 1;
  }

  static final _samplesCache = <int, Sample>{};
  static void _parseDive(
    ffi.Pointer<ffi.UnsignedChar> data,
    int size,
    ffi.Pointer<ffi.UnsignedChar> fingerprint,
    int fsize,
    ffi.Pointer<dc_device_t> device,
  ) {
    final fingerprintHash =
        _buildFingerprintHash(fingerprint, fsize).toNativeUtf8();
    log.fine('Parsing Dive #${fingerprintHash.toDartString()}');

    final parser = malloc<ffi.Pointer<dc_parser_t>>();

    _handleResult(_bindings.dc_parser_new(
      parser,
      device,
      data,
      size,
    ));

    final diveTime =
        _parseField<int>(dc_field_type_t.DC_FIELD_DIVETIME, parser.value);
    final maxDepth =
        _parseField<double>(dc_field_type_t.DC_FIELD_MAXDEPTH, parser.value);
    final avgDepth =
        _parseField<double>(dc_field_type_t.DC_FIELD_AVGDEPTH, parser.value);
    final atmospheric =
        _parseField<double>(dc_field_type_t.DC_FIELD_ATMOSPHERIC, parser.value);
    final temperatureSurface = _parseField<double>(
        dc_field_type_t.DC_FIELD_TEMPERATURE_SURFACE, parser.value);
    final temperatureMinumum = _parseField<double>(
        dc_field_type_t.DC_FIELD_TEMPERATURE_MINIMUM, parser.value);
    final temperatureMaximum = _parseField<double>(
        dc_field_type_t.DC_FIELD_TEMPERATURE_MAXIMUM, parser.value);
    final diveMode =
        _parseField<int>(dc_field_type_t.DC_FIELD_DIVEMODE, parser.value);

    final salinity =
        _parseField<Salinity>(dc_field_type_t.DC_FIELD_SALINITY, parser.value);

    final gasmixCount =
        _parseField<int>(dc_field_type_t.DC_FIELD_GASMIX_COUNT, parser.value);
    List<Gasmix>? gasmixes;
    if (gasmixCount != null) {
      gasmixes = [];
      for (var i = 0; i < gasmixCount; i++) {
        final gasmix = _parseField<Gasmix>(
            dc_field_type_t.DC_FIELD_GASMIX, parser.value, i);
        if (gasmix == null) continue;
        gasmixes.add(gasmix);
      }
    }

    final tankCount =
        _parseField<int>(dc_field_type_t.DC_FIELD_TANK_COUNT, parser.value);
    List<Tank>? tanks;
    if (tankCount != null) {
      tanks = [];
      for (var i = 0; i < tankCount; i++) {
        final tank =
            _parseField<Tank>(dc_field_type_t.DC_FIELD_TANK, parser.value, i);
        if (tank == null) continue;
        tanks.add(tank);
      }
    }

    final dateTimePointer = malloc<dc_datetime_t>();
    _handleResult(
      _bindings.dc_parser_get_datetime(parser.value, dateTimePointer),
    );
    final dateTime = DateTime(
      dateTimePointer.ref.year,
      dateTimePointer.ref.month,
      dateTimePointer.ref.day,
      dateTimePointer.ref.hour,
      dateTimePointer.ref.minute,
      dateTimePointer.ref.second,
    );

    try {
      _samplesCache.clear();
      _handleResult(
        _bindings.dc_parser_samples_foreach(
          parser.value,
          ffi.Pointer.fromFunction(_sample_callback),
          fingerprintHash.cast(),
        ),
      );
    } catch (e) {
      log.warning(e);
    }

    final dive = Dive(
      fingerprintHash.toDartString(),
      samples: _samplesCache.values.toList(),
      diveTime: diveTime,
      maxDepth: maxDepth,
      avgDepth: avgDepth,
      atmospheric: atmospheric,
      temperatureSurface: temperatureSurface,
      temperatureMinimum: temperatureMinumum,
      temperatureMaximum: temperatureMaximum,
      diveMode: diveMode,
      salinity: salinity,
      dateTime: dateTime,
      gasmixes: gasmixes,
      tanks: tanks,
    );
    log.info(dive);
    _divesCache.add(dive);

    _handleResult(_bindings.dc_parser_destroy(parser.value));
  }

  static T? _parseField<T>(
    int fieldType,
    ffi.Pointer<dc_parser_t> parser, [
    int flags = 0,
  ]) {
    // ignore: prefer_typing_uninitialized_variables
    final ffi.Pointer field;
    switch (T) {
      case const (int):
        field = malloc<ffi.UnsignedInt>();
        break;
      case const (double):
        field = malloc<ffi.Double>();
        break;
      case const (Salinity):
        field = malloc<dc_salinity_t>();
        break;
      case const (Gasmix):
        field = malloc<dc_gasmix_t>();
        break;
      case const (Tank):
        field = malloc<dc_tank_t>();
        break;
      default:
        throw UnsupportedError('Unsupported type: ${T.runtimeType}');
    }

    try {
      _handleResult(_bindings.dc_parser_get_field(
        parser,
        fieldType,
        flags,
        field.cast(),
      ));
    } on UnsupportedError catch (_) {
      return null;
    }

    switch (T) {
      case const (int):
        return field.cast<ffi.UnsignedInt>().value as T;
      case const (double):
        return field.cast<ffi.Double>().value as T;
      case const (Salinity):
        final salinity = field.cast<dc_salinity_t>().ref;
        return Salinity(salinity.type, salinity.density) as T;
      case const (Gasmix):
        final gasmix = field.cast<dc_gasmix_t>().ref;
        return Gasmix(
          flags,
          gasmix.usage,
          helium: gasmix.helium,
          oxygen: gasmix.oxygen,
          nitrogen: gasmix.nitrogen,
        ) as T;
      case const (Tank):
        final tank = field.cast<dc_tank_t>().ref;
        return Tank(
          tank.gasmix,
          tank.usage,
          workpressure: tank.workpressure,
          beginpressure: tank.beginpressure,
          endpressure: tank.endpressure,
        ) as T;
      default:
        throw UnsupportedError('Unsupported type: ${T.runtimeType}');
    }
  }

  static int _currentSampleTime = 0;
  // ignore: non_constant_identifier_names
  static void _sample_callback(
    int type /* dc_sample_type_t */,
    ffi.Pointer<dc_sample_value_t> value,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    final fingerprintHash = userdata.cast<Utf8>().toDartString();

    // https://github.com/libdivecomputer/libdivecomputer/blob/08d8c3e13272bc4c33f62cfdc57a34702cff7191/include/libdivecomputer/parser.h#L237-L272
    switch (type) {
      case dc_sample_type_t.DC_SAMPLE_TIME:
        final time = value.cast<ffi.UnsignedInt>().value;
        log.finest('Time: $time @ $fingerprintHash');
        _samplesCache.putIfAbsent(time, () => Sample(time));
        _currentSampleTime = time;
        break;
      case dc_sample_type_t.DC_SAMPLE_DEPTH:
        final depth = value.cast<ffi.Double>().value;
        log.finest('Depth: $depth @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.depth = depth;
        break;
      case dc_sample_type_t.DC_SAMPLE_TEMPERATURE:
        final temperature = value.cast<ffi.Double>().value;
        log.finest('Temperature: $temperature @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.temperature = temperature;
        break;
      case dc_sample_type_t.DC_SAMPLE_RBT:
        final rbt = value.cast<ffi.UnsignedInt>().value;
        log.finest('RBT: $rbt @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.rbt = rbt;
      case dc_sample_type_t.DC_SAMPLE_HEARTBEAT:
        final heartbeat = value.cast<ffi.UnsignedInt>().value;
        log.finest('Heartbeat: $heartbeat @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.heartbeat = heartbeat;
        break;
      case dc_sample_type_t.DC_SAMPLE_BEARING:
        final bearing = value.cast<ffi.UnsignedInt>().value;
        log.finest('Bearing: $bearing @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.bearing = bearing;
        break;
      case dc_sample_type_t.DC_SAMPLE_SETPOINT:
        final setpoint = value.cast<ffi.Double>().value;
        log.finest('Setpoint: $setpoint @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.setpoint = setpoint;
        break;
      case dc_sample_type_t.DC_SAMPLE_CNS:
        final cns = value.cast<ffi.Double>().value;
        log.finest('CNS: $cns @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.cns = cns;
        break;
      case dc_sample_type_t.DC_SAMPLE_GASMIX:
        final gasmix = value.cast<ffi.UnsignedInt>().value;
        log.finest('Gasmix: $gasmix @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.gasmix = gasmix;
        break;
      case dc_sample_type_t.DC_SAMPLE_PRESSURE:
        final pressureCallback = value.cast<_SampleCallbackPressure>();
        final pressure = pressureCallback.ref.value;
        log.finest('Pressure: $pressure @ $fingerprintHash');
        _samplesCache[_currentSampleTime]!.pressure ??= [];
        _samplesCache[_currentSampleTime]!
            .pressure!
            .add(Pressure(pressureCallback.ref.tank, pressure));
        break;
      case dc_sample_type_t.DC_SAMPLE_EVENT:
        final eventCallback = value.cast<_SampleCallbackEvent>();
        _samplesCache[_currentSampleTime]!.events ??= [];
        _samplesCache[_currentSampleTime]!.events!.add(Event(
              eventCallback.ref.type,
              eventCallback.ref.time,
              eventCallback.ref.flags,
              eventCallback.ref.value,
            ));
        break;
      case dc_sample_type_t.DC_SAMPLE_VENDOR:
        final vendorCallback = value.cast<_SampleCallbackVendor>();
        _samplesCache[_currentSampleTime]!.vendor ??= Vendor(
          vendorCallback.ref.type,
          vendorCallback.ref.size,
        );
        break;
      case dc_sample_type_t.DC_SAMPLE_PPO2:
        final ppo2Callback = value.cast<_SampleCallbackPPO2>();
        _samplesCache[_currentSampleTime]!.ppo2 ??= PPO2(
          ppo2Callback.ref.sensor,
          ppo2Callback.ref.value,
        );
        break;
      case dc_sample_type_t.DC_SAMPLE_DECO:
        final decoCallback = value.cast<_SampleCallbackDeco>();
        _samplesCache[_currentSampleTime]!.deco ??= Deco(
          decoCallback.ref.type,
          decoCallback.ref.time,
          decoCallback.ref.depth,
          decoCallback.ref.tts,
        );
        break;
      default:
        log.warning('Unknown sample type: $type');
    }
  }

  static void _log(
    ffi.Pointer<dc_context_t> context,
    int loglevel,
    ffi.Pointer<ffi.Char> file,
    int line,
    ffi.Pointer<ffi.Char> function,
    ffi.Pointer<ffi.Char> message,
    ffi.Pointer<ffi.Void> userdata,
  ) {
    log.fine('[native] ${message.cast<Utf8>().toDartString()}');
  }

  static void _handleResult(int result, [String operation = '']) {
    switch (result) {
      case dc_status_t.DC_STATUS_SUCCESS:
        if (operation.isNotEmpty) {
          log.finer('$operation successful');
        }
      case dc_status_t.DC_STATUS_DONE:
        if (operation.isNotEmpty) {
          log.finer('$operation done');
        }
        break;
      case dc_status_t.DC_STATUS_UNSUPPORTED:
        throw UnsupportedError('Unsupported');
      case dc_status_t.DC_STATUS_INVALIDARGS:
        throw ArgumentError('Invalid arguments');
      case dc_status_t.DC_STATUS_TIMEOUT:
        throw TimeoutException("Timeout");
      case dc_status_t.DC_STATUS_NOMEMORY:
        throw const OutOfMemoryError();
      case dc_status_t.DC_STATUS_NODEVICE:
        throw Exception("No device");
      case dc_status_t.DC_STATUS_NOACCESS:
        throw Exception("No access");
      case dc_status_t.DC_STATUS_IO:
        throw Exception("IO");
      case dc_status_t.DC_STATUS_PROTOCOL:
        throw Exception("Protocol");
      case dc_status_t.DC_STATUS_DATAFORMAT:
        throw Exception("Data format");
      case dc_status_t.DC_STATUS_CANCELLED:
        throw Exception("Cancelled");
    }
  }

  static String _buildFingerprintHash(
      ffi.Pointer<ffi.UnsignedChar> fingerprint, int fsize) {
    final ascii = '0123456789ABCDEF'.codeUnits;

    var result = StringBuffer();

    for (var i = 0; i < fsize; ++i) {
      var msn = (fingerprint.elementAt(i).value >> 4) & 0x0F;
      var lsn = fingerprint.elementAt(i).value & 0x0F;

      result.writeCharCode(ascii[msn]);
      result.writeCharCode(ascii[lsn]);
    }

    return result.toString();
  }
}

final class _DiveCallbackUserdata extends ffi.Struct {
  external ffi.Pointer<dc_device_t> device;
  external ffi.Pointer<Utf8> lastFingerprint;
}

typedef _SampleCallbackPressure = UnnamedStruct2;
typedef _SampleCallbackEvent = UnnamedStruct3;
typedef _SampleCallbackVendor = UnnamedStruct4;
typedef _SampleCallbackPPO2 = UnnamedStruct5;
typedef _SampleCallbackDeco = UnnamedStruct6;
