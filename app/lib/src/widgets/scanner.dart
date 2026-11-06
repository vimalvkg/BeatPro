import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme.dart';

/// What one scan did, shown on the scanner screen.
class ScanFeedback {
  const ScanFeedback(this.message, {this.ok = true});

  /// "Added Parle-G Biscuits · 3", or why nothing was added.
  final String message;
  final bool ok;
}

/// Handles one scanned code: adds the product and says what happened.
typedef ScanHandler = ScanFeedback Function(String code);

/// Scans barcodes one after another until the rep taps Done.
abstract class BarcodeScanner {
  /// False where there is no camera scanner (the desktop test build): the
  /// search box still takes typed or handheld-scanned barcodes.
  bool get available => true;

  Future<void> scan(
    BuildContext context, {
    required String title,
    required ScanHandler onCode,
  });
}

/// The phone's camera.
class CameraBarcodeScanner implements BarcodeScanner {
  const CameraBarcodeScanner();

  @override
  bool get available =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  Future<void> scan(
    BuildContext context, {
    required String title,
    required ScanHandler onCode,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _ScanScreen(title: title, onCode: onCode),
    ),
  );
}

final barcodeScannerProvider = Provider<BarcodeScanner>(
  (ref) => const CameraBarcodeScanner(),
);

/// The scan button used on the order, load, take back and unload screens.
class ScanButton extends ConsumerWidget {
  const ScanButton({
    super.key,
    required this.title,
    required this.onCode,
    this.afterScan,
  });

  final String title;
  final ScanHandler onCode;

  /// Runs when the scanner closes, e.g. to refresh totals.
  final VoidCallback? afterScan;

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      !ref.watch(barcodeScannerProvider).available
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: 'Scan barcodes',
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () async {
            await ref
                .read(barcodeScannerProvider)
                .scan(context, title: title, onCode: onCode);
            afterScan?.call();
          },
        );
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen({required this.title, required this.onCode});

  final String title;
  final ScanHandler onCode;

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 400,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.itf14,
      BarcodeFormat.qrCode,
      BarcodeFormat.dataMatrix,
    ],
  );
  ScanFeedback? _last;
  String? _lastCode;
  DateTime _lastAt = DateTime(2000);
  int _count = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final code = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (code == null) return;
    // The camera sees the same box many times a second: count it once,
    // then again only after a short pause (the next box).
    final now = DateTime.now();
    if (code == _lastCode &&
        now.difference(_lastAt) < const Duration(milliseconds: 1500)) {
      _lastAt = now;
      return;
    }
    _lastCode = code;
    _lastAt = now;
    final feedback = widget.onCode(code);
    if (feedback.ok) {
      _count++;
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
    setState(() => _last = feedback);
  }

  @override
  Widget build(BuildContext context) {
    final last = _last;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'Allow BeatPro to use the camera in the phone settings to scan barcodes.'
                      : "The camera couldn't start. Type the barcode in the search box instead.",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          // Aim here.
          Center(
            child: Container(
              width: 260,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: last == null
                            ? Colors.black54
                            : last.ok
                            ? BeatproColors.successSoft
                            : BeatproColors.dangerSoft,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        last?.message ?? 'Point the camera at a product barcode. Keep scanning; tap Done when finished.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: last == null
                              ? Colors.white
                              : (last.ok
                                    ? BeatproColors.success
                                    : BeatproColors.danger),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      _count == 0 ? 'Done' : 'Done · $_count scanned',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
