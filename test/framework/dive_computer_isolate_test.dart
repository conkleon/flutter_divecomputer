import 'dart:io';
import 'package:test/test.dart';

/// `DiveComputer.instance` spawns a background isolate that opens the native
/// library, so exercising the singleton getter directly under `flutter test`
/// is impractical (see the note on the getter). These source-level guards
/// pin the memoization contract from final-review finding C1 instead:
/// concurrent `supportedComputers` callers must share one future / one
/// round-trip, and a close must clear the memo so a reopen re-enumerates.
void main() {
  final source =
      File('lib/framework/dive_computer_isolate.dart').readAsStringSync();

  test('supportedComputers memoizes its request future', () {
    expect(
      source.contains(
          '_supportedComputersRequest ??= _requestSupportedComputers()'),
      isTrue,
      reason: 'The getter must return the same future to concurrent callers '
          'so a second caller cannot clobber the completer.',
    );
  });

  test('closeConnection clears the supportedComputers memo', () {
    final close = RegExp(r'void closeConnection\(\)\s*\{[^}]*\}')
        .firstMatch(source)
        ?.group(0);
    expect(close, isNotNull);
    expect(close, contains('_supportedComputersRequest = null'));
  });

  test('the List<Computer>/List<Dive> replies guard against double-complete',
      () {
    expect(
      RegExp(r'is List<Computer>\)\s*\{.*?isCompleted == false\)\s*\{\s*'
              r'_supportedComputers\?\.complete\(message\)',
              dotAll: true)
          .hasMatch(source),
      isTrue,
      reason: 'A duplicate supportedComputers reply must not complete() an '
          'already-completed completer.',
    );
    expect(
      RegExp(r'is List<Dive>\)\s*\{.*?isCompleted == false\)\s*\{\s*'
              r'_downloadedDives\?\.complete\(message\)',
              dotAll: true)
          .hasMatch(source),
      isTrue,
    );
  });
}
