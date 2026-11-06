import 'dart:typed_data';

import 'package:beatpro/src/core/escpos.dart';
import 'package:beatpro/src/core/invoice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('amounts in words for UAE invoices', () {
    expect(amountInWords(504, 'AED'), 'Five Hundred Four Dirhams only');
    expect(amountInWords(869.40, 'AED'), 'Eight Hundred Sixty-Nine Dirhams and Forty Fils');
    expect(amountInWords(1, 'AED'), 'One Dirham only');
    expect(amountInWords(12345.05, 'AED'), 'Twelve Thousand Three Hundred Forty-Five Dirhams and Five Fils');
  });

  test('ESC/POS raster: black pixels become dots, in bands, then feed and cut', () {
    // 16 × 3 image: the first row black, the rest white.
    const width = 16, height = 3;
    final rgba = Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
    for (var x = 0; x < width; x++) {
      rgba[x * 4] = rgba[x * 4 + 1] = rgba[x * 4 + 2] = 0;
    }
    final bytes = escPosImage(rgba, width, height, copies: 2);
    expect(bytes.sublist(0, 2), [0x1B, 0x40], reason: 'reset first');
    // GS v 0, 2 bytes a row, 3 rows, then the bits: one black row, two white.
    expect(bytes.sublist(2, 10), [0x1D, 0x76, 0x30, 0x00, 2, 0, 3, 0]);
    expect(bytes.sublist(10, 16), [0xFF, 0xFF, 0, 0, 0, 0]);
    expect(bytes.sublist(16, 23), [0x1B, 0x64, 0x04, 0x1D, 0x56, 0x42, 0x00], reason: 'feed, then cut');
    expect(bytes.length, 2 * 23, reason: 'two copies');
    expect(dotsForPaper('58'), 384);
    expect(dotsForPaper('80'), 576);
  });
}
