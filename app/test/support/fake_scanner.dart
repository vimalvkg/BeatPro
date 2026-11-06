import 'package:beatpro/src/widgets/scanner.dart';
import 'package:flutter/widgets.dart';

/// Stands in for the camera: "scans" the queued codes one after another.
class FakeBarcodeScanner implements BarcodeScanner {
  final queue = <String>[];
  final feedback = <ScanFeedback>[];
  final titles = <String>[];

  @override
  bool get available => true;

  @override
  Future<void> scan(BuildContext context, {required String title, required ScanHandler onCode}) async {
    titles.add(title);
    while (queue.isNotEmpty) {
      feedback.add(onCode(queue.removeAt(0)));
    }
  }
}
