import 'dart:convert';
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
import '../core/repository.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/statement_slip.dart';

const _periods = [('this_month', 'This month'), ('last_month', 'Last month'), ('3_months', '3 months')];

/// A shop's account: invoices, credit notes and payments with the running
/// balance, to print, share by WhatsApp or as a PDF. Needs signal the first
/// time; the last statement fetched is kept for offline.
class StatementScreen extends ConsumerStatefulWidget {
  const StatementScreen({super.key, required this.customerKey});

  final String customerKey;

  @override
  ConsumerState<StatementScreen> createState() => _StatementScreenState();
}

class _StatementScreenState extends ConsumerState<StatementScreen> {
  final _slipKey = GlobalKey();
  String _period = 'this_month';
  Map<String, dynamic>? _statement;
  bool _cached = false;
  bool _loading = true;
  bool _busy = false;
  PrinterSettings? _printer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _cacheKey => 'statement:${widget.customerKey}:$_period';

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = ref.read(repositoryProvider);
    _printer = await repo.printerSettings();
    final customer = await repo.db.customer(widget.customerKey);
    Map<String, dynamic>? statement;
    var cached = false;
    final sync = ref.read(syncServiceProvider);
    if (sync != null && customer?.serverId != null) {
      try {
        statement = await sync.statement(customer!.serverId!, _period);
        await repo.db.setValue(_cacheKey, jsonEncode(statement));
      } catch (_) {
        statement = null;
      }
    }
    if (statement == null) {
      final raw = await repo.db.getValue(_cacheKey);
      if (raw != null) {
        statement = (jsonDecode(raw) as Map).cast<String, dynamic>();
        cached = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _statement = statement;
      _cached = cached;
      _loading = false;
    });
  }

  Future<ui.Image> _image() async {
    final boundary = _slipKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return boundary.toImage(pixelRatio: dotsForPaper(_printer?.paper ?? '80') / boundary.size.width);
  }

  String get _name => 'Statement ${(_statement?['partner'] as Map?)?['name'] ?? ''} ${_statement?['date_to'] ?? ''}'.trim();

  Future<void> _print() async {
    final printer = _printer;
    if (printer == null || !printer.ready) {
      await context.push<bool>('/printer');
      _printer = await ref.read(repositoryProvider).printerSettings();
      if (!(_printer?.ready ?? false)) return;
    }
    setState(() => _busy = true);
    try {
      final image = await _image();
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      await ref.read(printerServiceProvider).printBytes(
          _printer!.address!, escPosImage(rgba!.buffer.asUint8List(), image.width, image.height, copies: 1));
      if (mounted) showMessage(context, 'Printed on ${_printer!.name ?? 'the printer'}');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareImage() async {
    final image = await _image();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = await File('${Directory.systemTemp.path}/${_name.replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '-')}.png')
        .writeAsBytes(data!.buffer.asUint8List());
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'image/png')], text: _name));
  }

  Future<void> _sharePdf() async {
    final image = await _image();
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final widthMm = (_printer?.paper ?? '80') == '58' ? 58.0 : 80.0;
    final doc = pw.Document(title: _name);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(widthMm * PdfPageFormat.mm, widthMm * image.height / image.width * PdfPageFormat.mm),
      build: (_) => pw.Image(pw.MemoryImage(png)),
    ));
    final file = await File('${Directory.systemTemp.path}/${_name.replaceAll(RegExp(r'[^A-Za-z0-9-]+'), '-')}.pdf')
        .writeAsBytes(await doc.save());
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'application/pdf')], text: _name));
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final customer = ref.watch(customerProvider(widget.customerKey)).value;
    final company = ref.watch(appContextProvider).value?.vanInvoice?.company ??
        {'name': ref.watch(appContextProvider).value?.companyName ?? ''};
    final s = _statement;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Statement'),
          Text(customer?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<String>(
          segments: [for (final (code, label) in _periods) ButtonSegment(value: code, label: Text(label))],
          selected: {_period},
          showSelectedIcon: false,
          onSelectionChanged: (v) {
            _period = v.first;
            _load();
          },
        ),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (s == null)
          const EmptyState(
              icon: Icons.cloud_off, title: 'Needs signal', message: 'The statement comes from Odoo. Try again when you have signal.')
        else ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(gradient: BeatproColors.bandGradient, borderRadius: BorderRadius.circular(16)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Balance due', style: TextStyle(color: BeatproColors.onBrand, fontWeight: FontWeight.w700, fontSize: 12)),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(money((s['closing'] as num).toDouble()),
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
                  ),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Text('Overdue', style: TextStyle(color: BeatproColors.onBrand, fontWeight: FontWeight.w700, fontSize: 12)),
                Text(money((s['overdue'] as num).toDouble()),
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
              ]),
            ]),
          ),
          if (_cached)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No signal: this is the statement fetched last time.', style: TextStyle(color: BeatproColors.warning)),
            ),
          const SizedBox(height: 12),
          Center(
            child: DecoratedBox(
              decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 4))]),
              child: RepaintBoundary(
                key: _slipKey,
                child: StatementSlip(statement: s, company: company, paper: _printer?.paper ?? '80'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _ShareButton(icon: Icons.print_outlined, label: 'Print', onTap: _busy ? null : _print)),
            const SizedBox(width: 8),
            Expanded(child: _ShareButton(icon: Icons.chat_outlined, label: 'WhatsApp', onTap: _shareImage)),
            const SizedBox(width: 8),
            Expanded(child: _ShareButton(icon: Icons.picture_as_pdf_outlined, label: 'PDF', onTap: _sharePdf)),
          ]),
        ],
      ]),
      bottomNavigationBar: s == null || (s['closing'] as num) <= 0
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: () => context.push('/payment/new?customer=${Uri.encodeComponent(widget.customerKey)}'),
                  child: Text('Collect payment · ${money((s['closing'] as num).toDouble())}'),
                ),
              ),
            ),
    );
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10), backgroundColor: Colors.white),
        onPressed: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
        ]),
      );
}
