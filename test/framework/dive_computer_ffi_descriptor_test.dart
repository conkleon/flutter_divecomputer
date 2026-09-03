import 'dart:io';
import 'package:test/test.dart';

void main() {
  final src = File('lib/framework/dive_computer_ffi.dart').readAsStringSync();

  test('supportedComputers uses dc_descriptor_iterator_new (0.9.0 API)', () {
    expect(
      RegExp(r'dc_descriptor_iterator_new\(\s*iterator,\s*ffi\.nullptr\s*\)')
          .hasMatch(src),
      isTrue,
      reason: '0.9.0 replaced dc_descriptor_iterator with '
          'dc_descriptor_iterator_new(iterator, context); pass ffi.nullptr '
          'to keep the pre-openConnection() call working.',
    );
    expect(
      src.contains('_bindings.dc_descriptor_iterator('),
      isFalse,
      reason: 'the bindings must never be called with the pre-0.9.0 one-arg '
          'name — that symbol is now a C macro and is not in the generated '
          'bindings; the only legacy reference allowed is the raw '
          'lookupFunction fallback below',
    );
    expect(
      src.contains('lookupFunction'),
      isTrue,
      reason: 'the macOS compat path raw-looks-up the legacy symbol when the '
          'bundled .dylib predates 0.9.0 and lacks dc_descriptor_iterator_new',
    );
    expect(
      src.contains("'dc_descriptor_iterator'"),
      isTrue,
      reason: 'the macOS compat path falls back to the pre-0.9.0 one-arg '
          'dc_descriptor_iterator so the rest of macOS keeps working',
    );
  });

  test('generated bindings expose dc_descriptor_iterator_new', () {
    final gen = File('lib/framework/dive_computer_ffi_bindings_generated.dart')
        .readAsStringSync();
    expect(gen.contains('dc_descriptor_iterator_new'), isTrue);
  });
}
