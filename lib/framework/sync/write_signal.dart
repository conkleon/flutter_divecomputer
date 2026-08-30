import 'dart:isolate';

/// Posted by the bridge `write` callback (background isolate) to tell the
/// main isolate a payload is waiting in the outbound mailbox — replacing
/// the old `Timer.periodic(4ms)` poll. [seq] is the mailbox sequence the
/// callback is now blocked waiting an ack for.
class WriteReady {
  const WriteReady(this.seq);
  final int seq;
}

/// The main isolate's `SendPort`, stashed here by `_spawnIsolate` for the
/// duration of one transfer (see `dive_computer_ffi.dart`). Null outside a
/// transfer. Lives on the background isolate only — isolates don't share
/// globals, so this is not cross-isolate state.
SendPort? syncHostPort;
