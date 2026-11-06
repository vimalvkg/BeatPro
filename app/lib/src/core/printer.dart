import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

class PrinterDevice {
  const PrinterDevice(this.name, this.address);

  final String name;
  final String address;
}

/// The rep's thermal printer. Tests use a fake that keeps the bytes.
abstract class PrinterService {
  /// False where Bluetooth printing isn't available (the desktop test build).
  bool get available;

  /// Printers paired with the phone in its Bluetooth settings.
  Future<List<PrinterDevice>> paired();

  /// Sends ESC/POS bytes to the printer. Throws [PrinterException] with a message for the rep.
  Future<void> printBytes(String address, List<int> bytes);
}

class PrinterException implements Exception {
  PrinterException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BluetoothPrinterService implements PrinterService {
  const BluetoothPrinterService();

  @override
  bool get available => Platform.isAndroid || Platform.isIOS;

  Future<void> _ensureAllowed() async {
    if (Platform.isAndroid) {
      final statuses = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
      if (statuses.values.any((s) => s.isPermanentlyDenied)) {
        throw PrinterException('Allow BeatPro to use Bluetooth in the phone settings (Nearby devices) to print.');
      }
    }
    if (!await PrintBluetoothThermal.bluetoothEnabled) {
      throw PrinterException('Turn on Bluetooth to print.');
    }
  }

  @override
  Future<List<PrinterDevice>> paired() async {
    await _ensureAllowed();
    final devices = await PrintBluetoothThermal.pairedBluetooths;
    return [for (final d in devices) PrinterDevice(d.name, d.macAdress)];
  }

  @override
  Future<void> printBytes(String address, List<int> bytes) async {
    await _ensureAllowed();
    if (!await PrintBluetoothThermal.connectionStatus) {
      final ok = await PrintBluetoothThermal.connect(macPrinterAddress: address);
      if (!ok) throw PrinterException("Couldn't connect to the printer. Check it's on and near the phone.");
    }
    // Small chunks: some printers drop data sent faster than they print.
    const chunk = 2048;
    for (var i = 0; i < bytes.length; i += chunk) {
      final ok = await PrintBluetoothThermal.writeBytes(bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk));
      if (!ok) throw PrinterException('The printer stopped. Check the paper and try again.');
    }
  }
}
