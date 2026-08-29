import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

const int kInboundCapacity = 4096;
const int kOutboundCapacity = 512;

/// If libdivecomputer requests an indefinite block (timeout == -1), we
/// honor "block" but never literally forever — a silent BLE disconnect
/// must not hang the isolate. See the design spec's Defensive measures
/// section.
const int kHardCapTimeoutMs = 30000;

const int kSpinPollIntervalMs = 2;

/// Shared native-memory state for one BLE "connection" — allocated on the
/// main isolate, its `.address` sent to the background isolate so both
/// sides can reconstruct a pointer to the *same* memory (outside the Dart
/// GC heap, so this works across isolates). See design spec, Decision 2.
///
/// Inbound (device -> host) is a lock-free single-producer/single-consumer
/// ring buffer: only the main isolate writes [inboundHead], only the
/// background isolate writes [inboundTail]. Outbound (host -> device) is a
/// single-slot mailbox: the background isolate fills the buffer and bumps
/// [writeSeq]; the main isolate performs the real write and bumps
/// [writeAckSeq] (and sets [writeStatus]) when done. One byte of the ring
/// buffer's capacity is always kept empty to disambiguate "empty" from
/// "full" without a separate counter.
final class BleBridgeState extends ffi.Struct {
  @ffi.Array(kInboundCapacity)
  external ffi.Array<ffi.Uint8> inboundBuffer;

  @ffi.Uint32()
  external int inboundHead;

  @ffi.Uint32()
  external int inboundTail;

  @ffi.Array(kOutboundCapacity)
  external ffi.Array<ffi.Uint8> outboundBuffer;

  @ffi.Uint32()
  external int outboundLen;

  @ffi.Uint32()
  external int writeSeq;

  @ffi.Uint32()
  external int writeAckSeq;

  @ffi.Int32()
  external int writeStatus;

  @ffi.Int32()
  external int closed;

  @ffi.Int32()
  external int timeoutMs;
}

/// Shared native-memory byte pipe between the main isolate and the background
/// isolate. Despite the `Ble` name it is transport-neutral: the BLE transport
/// and the Android RFCOMM transport (`lib/framework/rfcomm/`) both use it.
class BleBridge {
  BleBridge._(this.pointer);

  final ffi.Pointer<BleBridgeState> pointer;

  int get address => pointer.address;

  static BleBridge allocate() {
    final ptr = calloc<BleBridgeState>();
    ptr.ref
      ..inboundHead = 0
      ..inboundTail = 0
      ..outboundLen = 0
      ..writeSeq = 0
      ..writeAckSeq = 0
      ..writeStatus = 0
      ..closed = 0
      ..timeoutMs = -1;
    return BleBridge._(ptr);
  }

  static BleBridge fromAddress(int address) =>
      BleBridge._(ffi.Pointer<BleBridgeState>.fromAddress(address));

  static BleBridge fromRawPointer(ffi.Pointer<ffi.Void> userdata) =>
      BleBridge._(userdata.cast());

  void dispose() => calloc.free(pointer);

  bool get isClosed => pointer.ref.closed != 0;
  void markClosed() => pointer.ref.closed = 1;

  int get timeoutMs => pointer.ref.timeoutMs;
  set timeoutMs(int value) => pointer.ref.timeoutMs = value;

  int get writeStatus => pointer.ref.writeStatus;

  // --- Inbound ring buffer -------------------------------------------

  int get inboundAvailable {
    final head = pointer.ref.inboundHead;
    final tail = pointer.ref.inboundTail;
    return (head - tail) % kInboundCapacity;
  }

  /// Called by the main isolate as BLE notifications arrive. Returns the
  /// number of bytes actually stored; if less than `bytes.length`, the
  /// ring buffer was full (backpressure — see BleTransport, which logs
  /// this as an overflow).
  int pushInbound(Uint8List bytes) {
    final free = kInboundCapacity - inboundAvailable - 1;
    final toWrite = bytes.length < free ? bytes.length : free;
    final head = pointer.ref.inboundHead;
    for (var i = 0; i < toWrite; i++) {
      pointer.ref.inboundBuffer[(head + i) % kInboundCapacity] = bytes[i];
    }
    pointer.ref.inboundHead = (head + toWrite) % kInboundCapacity;
    return toWrite;
  }

  /// Called from the background isolate's `read` callback. Returns the
  /// number of bytes actually copied into [dest] (up to [maxLength]).
  int popInbound(ffi.Pointer<ffi.Uint8> dest, int maxLength) {
    final available = inboundAvailable;
    final toRead = maxLength < available ? maxLength : available;
    final tail = pointer.ref.inboundTail;
    for (var i = 0; i < toRead; i++) {
      dest[i] = pointer.ref.inboundBuffer[(tail + i) % kInboundCapacity];
    }
    pointer.ref.inboundTail = (tail + toRead) % kInboundCapacity;
    return toRead;
  }

  /// Busy-waits (real thread sleep, not an awaited Future — this runs
  /// inside a synchronous FFI callback with no event loop available) until
  /// data is available, [closed] is set, or the timeout elapses.
  ///
  /// `timeoutMs == 0` means "check once, don't wait" (matches
  /// libdivecomputer's non-blocking-poll convention). `timeoutMs < 0`
  /// means "block indefinitely", capped at [kHardCapTimeoutMs].
  bool waitForInbound(int timeoutMs) {
    if (timeoutMs == 0) return inboundAvailable > 0 || isClosed;
    final effective = timeoutMs < 0 ? kHardCapTimeoutMs : timeoutMs;
    final deadline = DateTime.now().add(Duration(milliseconds: effective));
    while (inboundAvailable == 0 && !isClosed) {
      if (!DateTime.now().isBefore(deadline)) return false;
      sleep(const Duration(milliseconds: kSpinPollIntervalMs));
    }
    return true;
  }

  // --- Outbound mailbox -------------------------------------------------

  int get pendingWriteSeq => pointer.ref.writeSeq;

  Uint8List get pendingOutbound {
    final len = pointer.ref.outboundLen;
    return Uint8List.fromList(
        [for (var i = 0; i < len; i++) pointer.ref.outboundBuffer[i]]);
  }

  /// Called from the background isolate's `write` callback. Returns the
  /// sequence number to pass to [waitForWriteAck].
  int queueOutbound(ffi.Pointer<ffi.Uint8> data, int length) {
    final clamped = length > kOutboundCapacity ? kOutboundCapacity : length;
    for (var i = 0; i < clamped; i++) {
      pointer.ref.outboundBuffer[i] = data[i];
    }
    pointer.ref.outboundLen = clamped;
    final seq = pointer.ref.writeSeq + 1;
    pointer.ref.writeSeq = seq;
    return seq;
  }

  /// Called by the main isolate once the real GATT write for the mailbox
  /// contents of sequence [seq] has completed (or failed — pass the resulting
  /// dc_status_t either way).
  ///
  /// [seq] MUST be the sequence number that was actually written, captured
  /// before the GATT write started — NOT the current [pendingWriteSeq]. A
  /// retry from libdivecomputer can bump `writeSeq` while a write is still in
  /// flight; acking the current value would tell the background isolate that
  /// a payload it never sent had been delivered.
  void ackOutbound(int seq, int status) {
    pointer.ref.writeStatus = status;
    pointer.ref.writeAckSeq = seq;
  }

  bool waitForWriteAck(int seq, int timeoutMs) {
    if (timeoutMs == 0) return pointer.ref.writeAckSeq == seq || isClosed;
    final effective = timeoutMs < 0 ? kHardCapTimeoutMs : timeoutMs;
    final deadline = DateTime.now().add(Duration(milliseconds: effective));
    while (pointer.ref.writeAckSeq != seq && !isClosed) {
      if (!DateTime.now().isBefore(deadline)) return false;
      sleep(const Duration(milliseconds: kSpinPollIntervalMs));
    }
    return true;
  }
}
