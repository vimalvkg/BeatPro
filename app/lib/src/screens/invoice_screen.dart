import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../core/escpos.dart';
import '../core/invoice.dart';
import '../core/repository.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/slip.dart';

/// The tax invoice for a van delivery: shown, printed on the thermal printer,
/// or shared as a picture (WhatsApp) or PDF.
class InvoiceScreen extends ConsumerStatefulWidget {
  const InvoiceScreen({super.key, required this.orderUuid, this.justPlaced = false});

  final String orderUuid;

  /// Opened right after placing the order: print automatically if set up so.
  final bool justPlaced;

  @override
  ConsumerState<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends ConsumerState<InvoiceScreen> {
  final _slipKey = GlobalKey();
  ShopInvoice? _invoice;
  PrinterSettings? _printer;
  String? _customerKey;
  String? _visitUuid;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final invoice = await repo.invoiceFor(widget.orderUuid);
    final printer = await repo.printerSettings();
    final order = await repo.db.record(widget.orderUuid);
    if (!mounted) return;
    setState(() {
      _invoice = invoice;
      _printer = printer;
      _customerKey = order?.data['customerKey'] as String?;
      _visitUuid = order?.data['visitUuid'] as String?;
    });
    if (widget.justPlaced && printer.autoPrint && printer.ready && ref.read(printerServiceProvider).available) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _print());
    }
  }

  /// The slip as an image the printer's width in dots.
  Future<ui.Image> _slipImage() async {
    final boundary = _slipKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final dots = dotsForPaper(_printer!.paper);
    return boundary.toImage(pixelRatio: dots / boundary.size.width);
  }

  Future<void> _print() async {
    final printer = _printer!;
    if (!printer.ready) {
      final changed = await context.push<bool>('/printer');
      await _load();
      if (changed != true || !(_printer?.ready ?? false)) return;
    }
    setState(() => _busy = true);
    try {
      final image = await _slipImage();
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final bytes = escPosImage(rgba!.buffer.asUint8List(), image.width, image.height, copies: _printer!.copies);
      await ref.read(printerServiceProvider).printBytes(_printer!.address!, bytes);
      if (mounted) showMessage(context, 'Printed on ${_printer!.name ?? 'the printer'}');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File> _png() async {
    final image = await _slipImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${Directory.systemTemp.path}/${_invoice!.name.replaceAll('/', '-')}.png');
    return file.writeAsBytes(data!.buffer.asUint8List());
  }

  Future<void> _shareImage() async {
    final file = await _png();
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'image/png')],
      text: 'Tax invoice ${_invoice!.name} · ${_invoice!.currency} ${_invoice!.total.toStringAsFixed(2)}',
    ));
  }

  Future<void> _sharePdf() async {
    final image = await _slipImage();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final widthMm = _printer!.paper == '58' ? 58.0 : 80.0;
    final heightMm = widthMm * image.height / image.width;
    final doc = pw.Document(title: _invoice!.name);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(widthMm * PdfPageFormat.mm, heightMm * PdfPageFormat.mm),
      build: (_) => pw.Image(pw.MemoryImage(png)),
    ));
    final file = File('${Directory.systemTemp.path}/${_invoice!.name.replaceAll('/', '-')}.pdf');
    await file.writeAsBytes(await doc.save());
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: 'application/pdf')],
      text: 'Tax invoice ${_invoice!.name}',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _invoice;
    final printer = _printer;
    final money = ref.watch(moneyProvider);
    final canPrint = ref.watch(printerServiceProvider).available;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(invoice?.simplified ?? false ? 'Simplified tax invoice' : 'Tax invoice'),
          Text(invoice?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          if (invoice != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: StatusChip(invoice.json['synced'] == true ? 'In Odoo' : 'Not synced yet',
                  color: invoice.json['synced'] == true ? BeatproColors.success : BeatproColors.warning),
            ),
        ],
      ),
      body: invoice == null || printer == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (invoice.renumberedFrom != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: BeatproColors.amberSoft, borderRadius: BorderRadius.circular(12)),
                    child: Text(
                      'Odoo numbered this invoice ${invoice.name} (the slip printed ${invoice.renumberedFrom}). '
                      'Print it again for the shop.',
                      style: const TextStyle(color: BeatproColors.amberInk, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              // The slip as it will print.
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 12)]),
                  child: RepaintBoundary(key: _slipKey, child: InvoiceSlip(invoice: invoice, paper: printer.paper)),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                if (canPrint) ...[
                  Expanded(
                    child: _Action(
                      icon: Icons.print_outlined,
                      label: _busy ? 'Printing…' : 'Print',
                      onTap: _busy ? null : _print,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(child: _Action(icon: Icons.chat_outlined, label: 'WhatsApp', color: BeatproColors.success, onTap: _shareImage)),
                const SizedBox(width: 8),
                Expanded(child: _Action(icon: Icons.picture_as_pdf_outlined, label: 'PDF', onTap: _sharePdf)),
              ]),
              if (canPrint)
                TextButton(
                  onPressed: () async {
                    await context.push('/printer');
                    await _load();
                  },
                  child: Text(printer.ready ? 'Printer: ${printer.name} · ${printer.paper} mm' : 'Set up the printer'),
                ),
            ]),
      bottomNavigationBar: invoice == null || _customerKey == null
          ? null
          : Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    FilledButton(
                      // The invoice just printed is ticked, so the payment settles it.
                      onPressed: () => context.pushReplacement('/payment/new?customer=${Uri.encodeComponent(_customerKey!)}'
                          '${_visitUuid == null ? '' : '&visit=$_visitUuid'}'
                          '&settle=${Uri.encodeComponent('ord:${widget.orderUuid}')}&invoice=${Uri.encodeComponent(invoice.name)}'),
                      child: Text('Collect payment · ${money(invoice.balance)}'),
                    ),
                    TextButton(onPressed: () => context.pop(), child: const Text('Done')),
                  ]),
                ),
              ),
            ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap, this.color});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(64), foregroundColor: color ?? BeatproColors.brand),
        onPressed: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon), const SizedBox(height: 2), Text(label)]),
      );
}
