import 'dart:typed_data';

import 'package:beatpro/src/core/growth.dart';

/// Stands in for the camera: each photo is a few bytes.
class FakePhotoService implements PhotoService {
  int taken = 0;

  @override
  Future<Uint8List?> take() async => Uint8List.fromList([0xFF, 0xD8, 0xFF, ++taken]);
}
