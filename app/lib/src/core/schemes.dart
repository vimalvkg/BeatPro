import 'models.dart';

/// A scheme running in Odoo: free goods (buy 10 cases, get 1 free) or a discount
/// from a quantity. The phone applies it offline; Odoo applies it again when the
/// order arrives, with the same rules.
class Scheme {
  Scheme({
    required this.id,
    required this.name,
    required this.kind,
    required this.productIds,
    required this.minQty,
    this.minLabel = '',
    this.discount = 0,
    this.freeProductId,
    this.freeQty = 0,
    this.freeUomId,
    this.rule = '',
  });

  final int id;
  final String name;

  /// `free_goods` or `discount`.
  final String kind;
  final List<int> productIds;

  /// The quantity to buy, in absolute unit size (pieces): 10 cases of 24 is 240.
  final double minQty;

  /// `10 Case of 24`, as set up in Odoo.
  final String minLabel;
  final double discount;
  final int? freeProductId;
  final double freeQty;
  final int? freeUomId;

  /// One line for the rep: `Buy 10 Case of 24, get 1 Case of 24 Oreo free`.
  final String rule;

  bool get isFreeGoods => kind == 'free_goods';

  static Scheme fromOdoo(Map<String, dynamic> r) => Scheme(
        id: r['id'] as int,
        name: (r['name'] as String?) ?? '',
        kind: (r['kind'] as String?) ?? 'free_goods',
        productIds: ((r['product_ids'] as List?) ?? const []).cast<int>(),
        minQty: (r['min_qty'] as num?)?.toDouble() ?? 1,
        minLabel: (r['min_label'] as String?) ?? '',
        discount: (r['discount'] as num?)?.toDouble() ?? 0,
        freeProductId: r['free_product_id'] is int ? r['free_product_id'] as int : null,
        freeQty: (r['free_qty'] as num?)?.toDouble() ?? 0,
        freeUomId: r['free_uom_id'] is int ? r['free_uom_id'] as int : null,
        rule: r['rule'] is String ? r['rule'] as String : '',
      );

  /// A short badge for the catalogue.
  String get badge {
    String q(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    if (!isFreeGoods) return '${q(discount)}% off from ${minLabel.isEmpty ? q(minQty) : minLabel}';
    return 'Buy ${minLabel.isEmpty ? q(minQty) : minLabel}, get ${q(freeQty)} free';
  }
}

/// A customer's prices: their price list's price for one, and the quantity prices
/// (slabs) that apply from a quantity in pieces.
class Pricing {
  Pricing({required this.prices, this.breaks = const {}});

  /// Price for one piece, per product, from the customer's price list.
  final Map<int, double> prices;

  /// `{product id: [(min pieces, price per piece), ...]}`, lowest quantity first.
  final Map<int, List<(double, double)>> breaks;

  double piecePrice(Product p, double pieces) {
    var price = prices[p.id] ?? p.listPrice;
    for (final (min, at) in breaks[p.id] ?? const <(double, double)>[]) {
      if (pieces + 1e-9 >= min) price = at;
    }
    return price;
  }

  /// Price for one [unit] at [pieces] bought, as Odoo works it out (rounded to fils).
  double unitPrice(Product p, ProductUnit unit, double pieces) => _round2(piecePrice(p, pieces) * p.perUnit(unit));

  /// The first quantity price above what is bought, to nudge the rep: `(pieces, price per piece)`.
  (double, double)? nextBreak(Product p, double pieces) {
    for (final b in breaks[p.id] ?? const <(double, double)>[]) {
      if (b.$1 > pieces + 1e-9) return b;
    }
    return null;
  }

  /// Re-prices a line for its unit and quantity.
  void price(CartLine l) {
    l.unitPrice = unitPrice(l.product, l.unit, l.baseQty);
    l.listPrice = unitPrice(l.product, l.unit, 1);
  }

  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}

/// Applies running schemes to the lines the shop buys, as Odoo does: scheme
/// discounts go on the lines bought, and free goods come back as new lines.
///
/// Quantities of all a scheme's products count together, in pieces. Each full
/// quantity bought earns the free goods again (20 cases: 2 free).
List<CartLine> applySchemes(List<CartLine> lines, List<Scheme> schemes, Map<int, Product> products, Pricing pricing) {
  final paid = lines.where((l) => !l.free).toList();
  for (final l in paid) {
    l.schemeDiscount = 0;
    l.schemeId = null;
    l.schemeName = null;
  }
  final free = <CartLine>[];
  for (final s in schemes) {
    final matching = paid.where((l) => s.productIds.contains(l.product.id)).toList();
    final bought = matching.fold<double>(0, (sum, l) => sum + l.qty * l.unit.factor);
    final times = s.minQty > 0 ? (bought / s.minQty + 1e-9).floor() : 0;
    if (times == 0) continue;
    if (!s.isFreeGoods) {
      for (final l in matching.where((l) => l.discount < s.discount)) {
        l.schemeDiscount = s.discount;
        l.schemeId = s.id;
        l.schemeName = s.name;
      }
      continue;
    }
    final product = products[s.freeProductId];
    if (product == null) continue;
    final unit = product.unitById(s.freeUomId);
    final line = CartLine(
      product: product,
      unitPrice: pricing.unitPrice(product, unit, 1),
      qty: s.freeQty * times,
      unit: unit,
      free: true,
      schemeId: s.id,
      schemeName: s.name,
    );
    free.add(line);
  }
  return free;
}
