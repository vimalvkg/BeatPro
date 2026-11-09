import 'package:flutter/material.dart';

/// A customer statement on thermal paper, black on white like the invoice slip.
class StatementSlip extends StatelessWidget {
  const StatementSlip({super.key, required this.statement, required this.company, this.paper = '80'});

  final Map<String, dynamic> statement;
  final Map<String, dynamic> company;
  final String paper;

  @override
  Widget build(BuildContext context) {
    final small = paper == '58';
    final base = TextStyle(fontFamily: 'Manrope', fontSize: small ? 9.5 : 11, height: 1.35, color: Colors.black);
    final bold = base.copyWith(fontWeight: FontWeight.w800);
    final ar = base.copyWith(fontFamily: 'NotoNaskhArabic', fontSize: (base.fontSize ?? 11) + 1, fontWeight: FontWeight.w700);
    String n(num v) => v.toStringAsFixed(2).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    String d(String iso) {
      final p = iso.split('-');
      return p.length == 3 ? '${p[2]}/${p[1]}' : iso;
    }

    Widget row(String a, String b, {TextStyle? style}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(a, style: style ?? base)),
          const SizedBox(width: 6),
          Text(b, style: style ?? base, textAlign: TextAlign.right),
        ]);
    Widget rule() => Container(margin: const EdgeInsets.symmetric(vertical: 4), height: 1, color: Colors.black54);
    final partner = (statement['partner'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ageing = (statement['ageing'] as Map?)?.cast<String, dynamic>() ?? const {};
    final currency = statement['currency'] as String? ?? 'AED';
    return Container(
      width: paper == '58' ? 192 : 288,
      color: Colors.white,
      padding: EdgeInsets.all(small ? 4 : 8),
      child: DefaultTextStyle(
        style: base,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text((company['name'] as String? ?? '').toUpperCase(), textAlign: TextAlign.center, style: bold),
          if ((company['trn'] as String? ?? '').isNotEmpty) Text('TRN ${company['trn']}', textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text('STATEMENT OF ACCOUNT', textAlign: TextAlign.center, style: bold),
          Text('كشف حساب', textAlign: TextAlign.center, textDirection: TextDirection.rtl, style: ar),
          Text('${d(statement['date_from'] as String)} – ${d(statement['date_to'] as String)}', textAlign: TextAlign.center),
          rule(),
          Text((partner['name'] as String? ?? '').toUpperCase(), style: bold),
          if ((partner['trn'] as String? ?? '').isNotEmpty) Text('TRN ${partner['trn']}'),
          rule(),
          row('Opening balance', n(statement['opening'] as num)),
          for (final l in ((statement['lines'] as List?) ?? const []).cast<Map<String, dynamic>>()) ...[
            Text('${d(l['date'] as String)} ${l['label']}'),
            row(
              (l['debit'] as num) > 0 ? '+ ${n(l['debit'] as num)}' : '- ${n(l['credit'] as num)}',
              n(l['balance'] as num),
            ),
          ],
          rule(),
          row('Balance due $currency', n(statement['closing'] as num), style: bold.copyWith(fontSize: (base.fontSize ?? 11) + 2)),
          row('Overdue', n(statement['overdue'] as num)),
          rule(),
          row('Not due', n(ageing['not_due'] as num? ?? 0)),
          row('1–30 days', n(ageing['d30'] as num? ?? 0)),
          row('31–60 days', n(ageing['d60'] as num? ?? 0)),
          row('Over 60 days', n(ageing['older'] as num? ?? 0)),
          if ((statement['note'] as String? ?? '').isNotEmpty) ...[
            rule(),
            Text(statement['note'] as String, style: base.copyWith(fontSize: (base.fontSize ?? 11) - 1.5)),
          ],
        ]),
      ),
    );
  }
}
