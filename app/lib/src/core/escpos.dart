import 'dart:typed_data';

/// Dots across the printable width of common thermal printers (203 dpi).
int dotsForPaper(String paper) => paper == '58' ? 384 : 576;

/// ESC/POS commands that print a picture of the slip, so any language
/// (Arabic included) prints the same on any ESC/POS printer.
///
/// [rgba] is the slip image, [width] × [height] pixels, 4 bytes a pixel; it
/// should already be [dotsForPaper] wide. Prints in bands so printers with small
/// buffers keep up, then feeds the paper and cuts (ignored without a cutter).
List<int> escPosImage(Uint8List rgba, int width, int height, {int copies = 1, int threshold = 160}) {
  final bytesPerRow = (width + 7) ~/ 8;
  final bits = Uint8List(bytesPerRow * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final alpha = rgba[i + 3];
      // Transparent counts as white paper.
      final luminance = alpha < 128 ? 255 : (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
      if (luminance < threshold) bits[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7);
    }
  }
  const band = 128;
  final out = <int>[];
  for (var c = 0; c < copies; c++) {
    out.addAll([0x1B, 0x40]); // ESC @: reset
    for (var top = 0; top < height; top += band) {
      final rows = (height - top) < band ? height - top : band;
      // GS v 0: raster image, normal size.
      out.addAll([0x1D, 0x76, 0x30, 0x00, bytesPerRow & 0xFF, bytesPerRow >> 8, rows & 0xFF, rows >> 8]);
      out.addAll(bits.sublist(top * bytesPerRow, (top + rows) * bytesPerRow));
    }
    out.addAll([0x1B, 0x64, 0x04]); // ESC d 4: feed 4 lines
    out.addAll([0x1D, 0x56, 0x42, 0x00]); // GS V B 0: partial cut
  }
  return out;
}
