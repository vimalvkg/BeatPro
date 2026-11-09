import 'dart:typed_data';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/escpos.dart';
import '../core/printer.dart';
import '../core/repository.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Choose the Bluetooth thermal printer, paper width, automatic printing and copies.
class PrinterScreen extends ConsumerStatefulWidget {
  const PrinterScreen({super.key});

  @override
  ConsumerState<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends ConsumerState<PrinterScreen> {
  PrinterSettings? _settings;
  List<PrinterDevice>? _devices;
  String? _error;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await ref.read(repositoryProvider).printerSettings();
    if (mounted) setState(() => _settings = settings);
    await _findPrinters();
  }

  Future<void> _findPrinters() async {
    setState(() => _error = null);
    try {
      final devices = await ref.read(printerServiceProvider).paired();
      if (mounted) setState(() => _devices = devices);
    } catch (e) {
      if (mounted) {
        setState(() {
          _devices = [];
          _error = describeError(e);
        });
      }
    }
  }

  Future<void> _save(PrinterSettings s) async {
    await ref.read(repositoryProvider).savePrinterSettings(s);
    setState(() => _settings = s);
  }

  /// A short slip to check the printer and paper width.
  Future<void> _testPrint() async {
    final s = _settings!;
    setState(() => _testing = true);
    try {
      final dots = dotsForPaper(s.paper);
      // A black frame with a bar the full printable width: shows if the paper width is right.
      const height = 96;
      final rgba = Uint8List(dots * height * 4)..fillRange(0, dots * height * 4, 255);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < dots; x++) {
          final edge = x < 4 || x >= dots - 4 || y < 4 || y >= height - 4 || (y > 40 && y < 56);
          if (edge) {
            final i = (y * dots + x) * 4;
            rgba[i] = rgba[i + 1] = rgba[i + 2] = 0;
          }
        }
      }
      final bytes = escPosImage(rgba, dots, height);
      await ref.read(printerServiceProvider).printBytes(s.address!, bytes);
      if (mounted) showMessage(context, 'Test slip sent. The frame should reach both edges of the paper.');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _settings;
    final devices = _devices;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Printer'),
          Text('For invoices at the shop', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Eyebrow('Bluetooth printers', padding: EdgeInsets.fromLTRB(0, 0, 0, 8)),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  if (devices == null)
                    const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator())
                  else if (devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error ?? 'No paired printers. Turn the printer on and pair it in the phone\'s Bluetooth settings first.',
                          style: TextStyle(color: _error == null ? BeatproColors.muted : BeatproColors.danger)),
                    )
                  else
                    RadioGroup<String>(
                      groupValue: s.address,
                      onChanged: (address) {
                        final d = devices.firstWhere((d) => d.address == address);
                        _save(s.copyWith(address: d.address, name: d.name));
                      },
                      child: Column(children: [
                        for (final d in devices)
                          RadioListTile<String>(
                            value: d.address,
                            title: Text(d.name.isEmpty ? d.address : d.name),
                            subtitle: Text(d.address),
                          ),
                      ]),
                    ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('Look for printers again'),
                    onTap: _findPrinters,
                  ),
                ]),
              ),
              const Eyebrow('Paper width', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: '58', label: Text('58 mm (2 inch)')),
                  ButtonSegment(value: '80', label: Text('80 mm (3 inch)')),
                ],
                selected: {s.paper},
                onSelectionChanged: (v) => _save(s.copyWith(paper: v.first)),
              ),
              const SizedBox(height: 16),
              Card(
                child: Column(children: [
                  SwitchListTile(
                    title: const Text('Print automatically'),
                    subtitle: const Text('After every van delivery'),
                    value: s.autoPrint,
                    onChanged: (v) => _save(s.copyWith(autoPrint: v)),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: const Text('Copies'),
                    subtitle: const Text('For example the shop copy and the van copy'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          tooltip: tr('Fewer'),
                          onPressed: s.copies > 1 ? () => _save(s.copyWith(copies: s.copies - 1)) : null,
                          icon: const Icon(Icons.remove)),
                      Text('${s.copies}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      IconButton(
                          tooltip: tr('More'),
                          onPressed: s.copies < 3 ? () => _save(s.copyWith(copies: s.copies + 1)) : null,
                          icon: const Icon(Icons.add)),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: BeatproColors.successSoft, borderRadius: BorderRadius.circular(14)),
                child: const Text(
                  'Works with ESC/POS Bluetooth printers (most 58 and 80 mm thermal printers). '
                  'No printer? Share the invoice on WhatsApp instead.',
                  style: TextStyle(color: BeatproColors.success, fontWeight: FontWeight.w600),
                ),
              ),
            ]),
      bottomNavigationBar: s == null || !s.ready
          ? null
          : Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                          onPressed: _testing ? null : _testPrint, child: Text(_testing ? 'Printing…' : 'Print a test slip')),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: FilledButton(onPressed: () => context.pop(true), child: const Text('Done'))),
                  ]),
                ),
              ),
            ),
    );
  }
}
