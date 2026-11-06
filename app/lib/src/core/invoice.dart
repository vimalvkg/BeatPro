/// A tax invoice made at the shop for a van delivery, kept with the order on
/// the phone so it can be shown and printed without signal.
class ShopInvoice {
  ShopInvoice(this.json);

  final Map<String, dynamic> json;

  String get name => json['name'] as String;
  String get date => json['date'] as String;
  bool get simplified => json['simplified'] == true;
  String get title => simplified ? 'SIMPLIFIED TAX INVOICE' : 'TAX INVOICE';
  String get titleAr => simplified ? 'فاتورة ضريبية مبسطة' : 'فاتورة ضريبية';
  String get currency => json['currency'] as String? ?? 'AED';
  double get untaxed => (json['untaxed'] as num).toDouble();
  double get tax => (json['tax'] as num).toDouble();
  double get total => (json['total'] as num).toDouble();
  double get previous => (json['previous'] as num?)?.toDouble() ?? 0;
  double get balance => previous + total;
  String get words => amountInWords(total, currency);
  Map<String, dynamic> get company => (json['company'] as Map).cast<String, dynamic>();
  Map<String, dynamic> get customer => (json['customer'] as Map).cast<String, dynamic>();
  String? get van => json['van'] as String?;
  List<Map<String, dynamic>> get lines => (json['lines'] as List).cast<Map<String, dynamic>>();

  /// Odoo gave a different number (the phone's was used meanwhile).
  String? get renumberedFrom => json['renumberedFrom'] as String?;

  static double round2(double v) => (v * 100).roundToDouble() / 100;
}

const _ones = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve',
  'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen',
];
const _tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

String _below1000(int n) {
  final parts = <String>[];
  if (n >= 100) {
    parts.add('${_ones[n ~/ 100]} Hundred');
    n %= 100;
  }
  if (n >= 20) {
    parts.add(n % 10 == 0 ? _tens[n ~/ 10] : '${_tens[n ~/ 10]}-${_ones[n % 10]}');
  } else if (n > 0) {
    parts.add(_ones[n]);
  }
  return parts.join(' ');
}

String _integerWords(int n) {
  if (n == 0) return 'Zero';
  final parts = <String>[];
  for (final (size, name) in [(1000000000, 'Billion'), (1000000, 'Million'), (1000, 'Thousand')]) {
    if (n >= size) {
      parts.add('${_below1000(n ~/ size)} $name');
      n %= size;
    }
  }
  if (n > 0) parts.add(_below1000(n));
  return parts.join(' ');
}

/// "Eight Hundred Sixty-Nine Dirhams and Forty Fils".
String amountInWords(double amount, String currency) {
  final cents = (amount * 100).round();
  final whole = cents ~/ 100;
  final fraction = cents % 100;
  final (unit, units, sub) = currency == 'AED' ? ('Dirham', 'Dirhams', 'Fils') : (currency, currency, 'Cents');
  final main = '${_integerWords(whole)} ${whole == 1 ? unit : units}';
  return fraction == 0 ? '$main only' : '$main and ${_integerWords(fraction)} $sub';
}
