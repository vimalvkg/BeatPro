import 'package:beatpro/src/core/models.dart';
import 'package:beatpro/src/core/schemes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const piece = ProductUnit(id: 1, name: 'Units', short: 'pc', factor: 1);
  const case24 = ProductUnit(id: 7, name: 'Case of 24', short: 'cs', factor: 24);
  final oreo = Product(id: 1, name: 'Oreo 36 g', listPrice: 2, qtyAvailable: 0, taxPercent: 5, units: const [piece, case24]);
  final water = Product(id: 2, name: 'Al Ain Water 500 ml', listPrice: 1, qtyAvailable: 0, taxPercent: 5, units: const [piece, case24]);
  final products = {oreo.id: oreo, water.id: water};
  final pricing = Pricing(prices: {1: 2.0, 2: 1.0}, breaks: {
    2: [(480.0, 0.8)],
  });

  CartLine line(Product p, double qty, ProductUnit unit) {
    final l = CartLine(product: p, unitPrice: 0, qty: qty, unit: unit);
    pricing.price(l);
    return l;
  }

  test('cases and pieces', () {
    expect(oreo.defaultUnit.short, 'cs');
    expect(oreo.packText(29), '1 cs + 5 pc');
    expect(oreo.packText(48), '2 cs');
    expect(oreo.packText(0), '0 pc');
    final l = line(oreo, 3, case24);
    expect(l.baseQty, 72);
    expect(l.unitPrice, 48, reason: 'a case of 24 at AED 2');
  });

  test('quantity prices (slabs) from the pieces bought', () {
    final small = line(water, 19, case24);
    expect(small.unitPrice, 24);
    final big = line(water, 20, case24);
    expect(big.unitPrice, 19.2, reason: '480 pieces at the slab price');
    expect(big.listPrice, 24);
    expect(big.saved, closeTo(96, 0.001));
    expect(pricing.nextBreak(water, 100), (480.0, 0.8));
  });

  test('free goods: each full quantity earns them again', () {
    final scheme = Scheme(
      id: 3,
      name: 'Oreo: buy 10 cases, get 1 free',
      kind: 'free_goods',
      productIds: const [1],
      minQty: 240,
      freeProductId: 1,
      freeQty: 1,
      freeUomId: 7,
    );
    expect(applySchemes([line(oreo, 9, case24), line(oreo, 23, piece)], [scheme], products, pricing), isEmpty,
        reason: '9 cases + 23 pieces is one piece short');
    final free = applySchemes([line(oreo, 20, case24)], [scheme], products, pricing);
    expect(free.single.qty, 2);
    expect(free.single.unit.short, 'cs');
    expect(free.single.subtotal, 0);
    expect(free.single.saved, 96);
    expect(free.single.schemeName, 'Oreo: buy 10 cases, get 1 free');
  });

  test('a scheme discount only where it beats the rep\'s', () {
    final scheme = Scheme(id: 4, name: 'Water 5%', kind: 'discount', productIds: const [2], minQty: 120, discount: 5);
    final a = line(water, 6, case24);
    applySchemes([a], [scheme], products, pricing);
    expect(a.effectiveDiscount, 5);
    expect(a.schemeId, 4);
    final b = line(water, 6, case24)..discount = 8;
    applySchemes([b], [scheme], products, pricing);
    expect(b.effectiveDiscount, 8);
    expect(b.schemeId, isNull);
    final c = line(water, 4, case24);
    applySchemes([c], [scheme], products, pricing);
    expect(c.effectiveDiscount, 0, reason: 'too few cases');
  });
}
