import 'package:beatpro/src/core/printer.dart';

/// Stands in for the Bluetooth printer: keeps what it was sent.
class FakePrinter implements PrinterService {
  final jobs = <List<int>>[];

  @override
  bool get available => true;

  @override
  Future<List<PrinterDevice>> paired() async => const [PrinterDevice('BT-58 Thermal', '66:02:BD:12:34:56')];

  @override
  Future<void> printBytes(String address, List<int> bytes) async => jobs.add(bytes);
}
