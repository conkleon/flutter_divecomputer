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
      src.contains('dc_descriptor_iterator('),
      isFalse,
      reason: 'the old symbol is now a C macro and is not in the bindings',
    );
  });

  test('generated bindings expose dc_descriptor_iterator_new', () {
    final gen = File('lib/framework/dive_computer_ffi_bindings_generated.dart')
        .readAsStringSync();
    expect(gen.contains('dc_descriptor_iterator_new'), isTrue);
  });
}
