import 'package:flutter/material.dart';

import '../core/invoice.dart';

/// The printed slip, black on white, the same layout as Odoo's thermal slip.
/// Its width in logical pixels is half the printer's dots, so it prints at 2×.
class InvoiceSlip extends StatelessWidget {
  const InvoiceSlip({super.key, required this.invoice, this.paper = '80'});

  final ShopInvoice invoice;
  final String paper;

  static double widthFor(String paper) => paper == '58' ? 192 : 288;

  @override
  Widget build(BuildContext context) {
    final small = paper == '58';
    final base = TextStyle(fontFamily: 'Manrope', fontSize: small ? 9.5 : 11, height: 1.35, color: Colors.black);
    final bold = base.copyWith(fontWeight: FontWeight.w800);
    final i = invoice;
    final c = i.company;
    final cust = i.customer;
    String n(num v) => v.toStringAsFixed(2);
    Widget row(String a, String b, {TextStyle? style}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(a, style: style ?? base)),
          const SizedBox(width: 6),
          Text(b, style: style ?? base, textAlign: TextAlign.right),
        ]);
    Widget rule() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: LayoutBuilder(
            builder: (context, box) => Text('-' * (box.maxWidth / (small ? 4.6 : 5.3)).floor(),
                maxLines: 1, overflow: TextOverflow.clip, style: base.copyWith(letterSpacing: 0.5)),
          ),
        );
    Widget center(String text, {TextStyle? style}) => Text(text, textAlign: TextAlign.center, style: style ?? base);
    // Bundled, so Arabic shows and prints the same on every phone.
    final ar = base.copyWith(fontFamily: 'NotoNaskhArabic', fontSize: (base.fontSize ?? 11) + 1, height: 1.2);
    return Container(
      width: widthFor(paper),
      color: Colors.white,
      padding: EdgeInsets.all(small ? 4 : 8),
      child: DefaultTextStyle(
        style: base,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          center((c['name'] as String? ?? '').toUpperCase(), style: bold.copyWith(fontSize: (base.fontSize ?? 11) + 2)),
          if ((c['address'] as String? ?? '').isNotEmpty) center(c['address'] as String),
          if ((c['trn'] as String? ?? '').isNotEmpty) center('TRN ${c['trn']}'),
          if ((c['phone'] as String? ?? '').isNotEmpty) center('Tel ${c['phone']}'),
          const SizedBox(height: 6),
          center(i.title, style: bold),
          Text(i.titleAr, textAlign: TextAlign.center, textDirection: TextDirection.rtl, style: ar.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          row('Inv', i.name),
          row('Date', '${_ddmmyyyy(i.date)} ${i.json['time'] ?? ''}'.trim()),
          if ((i.van ?? '').isNotEmpty) row('Van', i.van!),
          rule(),
          Text((cust['name'] as String? ?? '').toUpperCase(), style: bold),
          if ((cust['city'] as String? ?? '').isNotEmpty) Text(cust['city'] as String),
          if ((cust['trn'] as String? ?? '').isNotEmpty) Text('TRN ${cust['trn']}'),
          rule(),
          row('Item', 'Qty x Price · Amount', style: bold),
          rule(),
          for (final l in i.lines) ...[
            Text(l['name'] as String),
            row((l['note'] as String?) ?? 'VAT ${_pct(l['vat'] as num)}',
                '${_qty(l['qty'] as num)}${l['unit'] == null ? '' : ' ${l['unit']}'} x ${n(l['price'] as num)} · ${n(l['amount'] as num)}'),
            const SizedBox(height: 3),
          ],
          rule(),
          row('Total excl. VAT', n(i.untaxed)),
          row('VAT', n(i.tax)),
          const SizedBox(height: 4),
          row('TOTAL ${i.currency}', n(i.total), style: bold.copyWith(fontSize: (base.fontSize ?? 11) + 2)),
          Row(children: [
            Text(n(i.total)),
            const Spacer(),
            Text('الإجمالي شامل الضريبة', textDirection: TextDirection.rtl, style: ar),
          ]),
          Text(i.words, style: base.copyWith(fontSize: (base.fontSize ?? 11) - 1.5)),
          if (i.saved >= 0.01) ...[
            rule(),
            row('You saved ${i.currency}', n(i.saved), style: bold),
          ],
          rule(),
          row('Previous balance', n(i.previous)),
          row('Balance due ${i.currency}', n(i.balance), style: bold),
          rule(),
          const SizedBox(height: 2),
          const Text('Received by: ______________'),
          const Text('Signature & stamp'),
          const SizedBox(height: 8),
          center('Thank you for your business'),
          Text('شكراً لتعاملكم معنا', textAlign: TextAlign.center, textDirection: TextDirection.rtl, style: ar),
          const SizedBox(height: 4),
        ]),
      ),
    );
  }

  static String _ddmmyyyy(String iso) {
    final p = iso.split('-');
    return p.length == 3 ? '${p[2]}/${p[1]}/${p[0]}' : iso;
  }

  static String _qty(num q) => q == q.roundToDouble() ? q.toInt().toString() : q.toStringAsFixed(2);
  static String _pct(num p) => '${p == p.roundToDouble() ? p.toInt() : p}%';
}
