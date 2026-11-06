// Runs a rep's full day against a real Odoo 19 server with the BeatPro module.
//
//   BEATPRO_ODOO_URL=http://127.0.0.1:8069 BEATPRO_ODOO_DB=beatpro_e2e \
//   BEATPRO_ODOO_KEY=<rep API key> flutter test test/sync_integration_test.dart
// or, instead of the key, BEATPRO_ODOO_LOGIN=<login> BEATPRO_ODOO_PASSWORD=<password>.
//
// Skipped when BEATPRO_ODOO_URL isn't set.
import 'dart:io';

import 'package:beatpro/src/core/local_db.dart';
import 'package:beatpro/src/core/invoice.dart';
import 'package:beatpro/src/core/models.dart';
import 'package:beatpro/src/core/odoo_client.dart';
import 'package:beatpro/src/core/repository.dart';
import 'package:beatpro/src/core/schemes.dart';
import 'package:beatpro/src/core/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final env = Platform.environment;
  final url = env['BEATPRO_ODOO_URL'];

  // An API key (BEATPRO_ODOO_KEY), or a login and password (BEATPRO_ODOO_LOGIN,
  // BEATPRO_ODOO_PASSWORD) that Odoo exchanges for a key, as the sign-in screen does.
  Future<OdooCredentials> credentials() async {
    final database = env['BEATPRO_ODOO_DB'] ?? '';
    if (env['BEATPRO_ODOO_LOGIN'] != null) {
      final signedIn = await OdooCredentials.signInWithPassword(
        url: url!,
        database: database,
        login: env['BEATPRO_ODOO_LOGIN']!,
        password: env['BEATPRO_ODOO_PASSWORD'] ?? '',
        device: 'integration test',
      );
      expect(signedIn.apiKey, isNotEmpty);
      return signedIn;
    }
    return OdooCredentials(url: url!, database: database, apiKey: env['BEATPRO_ODOO_KEY']!);
  }

  test('a rep works a full day offline, then syncs to Odoo', () async {
    final client = OdooClient(await credentials());
    sqfliteFfiInit();
    final db = await LocalDb.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = Repository(db);
    final sync = SyncService(db, client);

    // Sign-in download.
    await sync.download();
    final context = (await repo.appContext())!;
    final plan = await repo.todayPlan();
    expect(plan, isNotEmpty, reason: 'the rep needs a route for today');
    final products = await db.products();
    expect(products, isNotEmpty);
    expect(context.paymentMethods, isNotEmpty, reason: 'payment methods come from Odoo');

    // Product barcodes come from Odoo, so scanning finds the product offline.
    final withBarcode = products.where((p) => p.barcode != null).toList();
    if (withBarcode.isNotEmpty) {
      expect(productForCode(products, withBarcode.first.barcode!)?.id, withBarcode.first.id);
    }

    // Visit the first shop: order, collect against its invoices, check out.
    final stop = plan.first;
    final visit = await repo.startVisit(stop.customer.key, routeId: stop.stop.routeId, at: const GeoPoint(19.1136, 72.8697));
    final prices = await db.pricesFor(stop.customer.pricelistId);
    final product = products.first;
    final order = await repo.placeOrder(
      customerKey: stop.customer.key,
      visitUuid: visit.uuid,
      lines: [CartLine(product: product, unitPrice: prices[product.id] ?? product.listPrice, qty: 2)],
    );
    final invoices = await db.invoices(customerKey: stop.customer.key);
    final due = invoices.fold<double>(0, (s, i) => s + i.amountDue);
    LocalRecord? payment;
    if (due > 0) {
      payment = await repo.collectPayment(
        customerKey: stop.customer.key,
        visitUuid: visit.uuid,
        amount: due,
        method: context.paymentMethods.firstWhere((m) => m.kind == 'bank'),
        reference: 'UPI-TEST-1',
        settles: invoices,
      );
      expect(await repo.amountDue(stop.customer.key), 0, reason: 'invoices show as settled on the phone');
    }
    await repo.checkOut(visit.uuid, result: VisitResult.order, at: const GeoPoint(19.1137, 72.8698));

    // A new shop found on the way, visited with no order.
    final newShop = await repo.addCustomer(name: 'Test Shop ${DateTime.now().millisecondsSinceEpoch}', city: 'Powai');
    final visit2 = await repo.startVisit(newShop.key);
    await repo.checkOut(visit2.uuid, result: VisitResult.noOrder, noOrderReason: 'owner_absent');
    await repo.closeDay(distanceKm: 12.5);

    // Back in signal range.
    final report = await sync.sync();
    expect(report.offlineMessage, isNull);
    expect(report.failed, 0, reason: (await db.records(state: SyncState.failed)).map((r) => r.error).join('; '));
    expect(await repo.pendingCount(), 0);

    final syncedOrder = (await db.record(order.uuid))!;
    expect(syncedOrder.serverId, isNotNull);
    expect(syncedOrder.data['odooState'], 'sale');
    expect((syncedOrder.data['name'] as String), startsWith('S'));

    // What Odoo now holds.
    final serverVisit = (await client.searchRead('beatpro.visit', domain: [
      ['id', '=', (await db.record(visit.uuid))!.serverId],
    ], fields: ['state', 'result', 'check_in_latitude', 'sale_order_count', 'amount_collected']))
        .single;
    expect(serverVisit['state'], 'done');
    expect(serverVisit['result'], 'order');
    expect((serverVisit['check_in_latitude'] as num), closeTo(19.1136, 0.0001));
    expect(serverVisit['sale_order_count'], 1);
    if (payment != null) expect((serverVisit['amount_collected'] as num), closeTo(due, 0.01));

    final close = (await client.searchRead('beatpro.day.close', domain: [
      ['id', '=', (await repo.todayClose())!.serverId],
    ], fields: ['state', 'visit_count', 'distance_km', 'user_id'])).single;
    expect(close['state'], 'closed');
    expect(close['visit_count'], greaterThanOrEqualTo(2));
    expect(close['distance_km'], 12.5);
    expect((close['user_id'] as List).first, context.userId);

    // Running sync again changes nothing in Odoo.
    final again = await sync.sync();
    expect(again.uploaded, 0);
    final orderCount = await client.call('sale.order', 'search_count', kwargs: {
      'domain': [
        ['mobile_uuid', '=', order.uuid],
      ],
    });
    expect(orderCount, 1);

    // Paid with the method chosen in the app.
    if (payment != null) {
      final serverPayment = (await client.searchRead('account.payment', domain: [
        ['id', '=', (await db.record(payment.uuid))!.serverId],
      ], fields: ['payment_method_line_id', 'beatpro_reference'])).single;
      expect((serverPayment['payment_method_line_id'] as List).first,
          context.paymentMethods.firstWhere((m) => m.kind == 'bank').id);
      expect(serverPayment['beatpro_reference'], 'UPI-TEST-1');
    }

    // The new shop came back from Odoo as a customer.
    expect((await db.customers(search: 'Test Shop')).any((c) => c.serverId != null), isTrue);
    await db.close();
  }, skip: url == null ? 'Set BEATPRO_ODOO_URL to run against a live Odoo server' : false);

  // Needs a rep with a loaded van and no unload yet today.
  test('a van day: deliver from the van, take goods back, unload', () async {
    final client = OdooClient(await credentials());
    sqfliteFfiInit();
    final db = await LocalDb.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = Repository(db);
    final sync = SyncService(db, client);
    await sync.download();
    final context = (await repo.appContext())!;
    expect(context.van, isNotNull, reason: 'the rep needs a van');
    final before = await repo.vanStock();
    expect(before.inVan, greaterThan(0), reason: 'the van needs stock');

    // One product the van has, and more of another than the van carries.
    final products = {for (final p in await db.products()) p.id: p};
    final inVan = before.items.where((i) => i.left >= 1).toList();
    final fromVan = products[inVan.first.productId]!;
    final tooMuch = products[inVan.last.productId]!;
    final tooMuchQty = inVan.last.left + 5;
    final stop = (await repo.todayPlan()).first;
    final visit = await repo.startVisit(stop.customer.key, routeId: stop.stop.routeId);
    final order = await repo.placeOrder(
      customerKey: stop.customer.key,
      visitUuid: visit.uuid,
      delivery: DeliveryMode.split,
      lines: [
        CartLine(product: fromVan, unitPrice: fromVan.listPrice, qty: 1),
        CartLine(product: tooMuch, unitPrice: tooMuch.listPrice, qty: tooMuchQty),
      ],
    );
    expect((await repo.vanStock()).leftOf(fromVan.id), inVan.first.left - 1);

    final reasons = context.returnReasons;
    final ret = await repo.takeBack(customerKey: stop.customer.key, visitUuid: visit.uuid, lines: [
      ReturnLine(productId: fromVan.id, name: fromVan.name, priceUnit: 10, qty: 2,
          reason: reasons.firstWhere((r) => r.value == 'not_selling')),
      ReturnLine(productId: tooMuch.id, name: tooMuch.name, priceUnit: 20, qty: 1,
          reason: reasons.firstWhere((r) => r.value == 'damaged')),
    ]);
    // The shop pays the invoice printed at the shop, using the credit for the goods taken back.
    final settles = (await repo.openItemsFor(stop.customer.key))
        .where((i) => i.orderUuid == order.uuid || i.returnUuid == ret.uuid)
        .toList();
    final toPay = settles.fold<double>(0, (s, i) => s + i.amountDue);
    if (context.vanInvoice != null) {
      await repo.collectPayment(
        customerKey: stop.customer.key,
        visitUuid: visit.uuid,
        amount: toPay > 0 ? ShopInvoice.round2(toPay) : 0,
        method: context.paymentMethods.firstWhere((m) => m.kind == 'cash'),
        settles: settles,
      );
    }
    await repo.checkOut(visit.uuid, result: VisitResult.order);
    final report = await sync.sync();
    expect(report.failed, 0, reason: (await db.records(state: SyncState.failed)).map((r) => r.error).join('; '));
    expect(report.waiting, 0);

    final serverOrder = (await client.searchRead('sale.order', domain: [
      ['id', '=', (await db.record(order.uuid))!.serverId],
    ], fields: ['beatpro_delivery_mode', 'picking_ids', 'user_id'])).single;
    expect(serverOrder['beatpro_delivery_mode'], 'split');
    expect((serverOrder['picking_ids'] as List).length, 2, reason: 'one delivery from the van, one from the warehouse');
    expect((serverOrder['user_id'] as List).first, context.userId);

    // With invoicing at the shop on, Odoo posted the van part with the number the phone printed.
    final localInvoice = (await repo.invoiceFor(order.uuid));
    if (context.vanInvoice != null) {
      expect(localInvoice, isNotNull, reason: 'the van handed something over');
      final serverInvoice = (await client.searchRead('account.move', domain: [
        ['name', '=', localInvoice!.name],
      ], fields: ['state', 'amount_total', 'beatpro_van_id', 'amount_residual'])).single;
      expect(serverInvoice['state'], 'posted');
      expect(serverInvoice['amount_residual'], 0, reason: 'the payment and the credit note settled this invoice');
      expect((serverInvoice['amount_total'] as num).toDouble(), closeTo(localInvoice.total, 0.05));
    }

    final serverReturn = (await client.searchRead('beatpro.shop.return', domain: [
      ['id', '=', (await db.record(ret.uuid))!.serverId],
    ], fields: ['state', 'amount_total', 'credit_note_id'])).single;
    expect(serverReturn['state'], 'done');
    expect(serverReturn['amount_total'], 40.0);
    expect(serverReturn['credit_note_id'], isNot(false));
    final creditNote = (await client.searchRead('account.move', domain: [
      ['id', '=', (serverReturn['credit_note_id'] as List).first],
    ], fields: ['state', 'amount_total', 'amount_residual'])).single;
    expect(creditNote['state'], 'posted');
    if (context.vanInvoice != null) {
      // Used against the invoice; whatever the invoice didn't need stays for later.
      final unused = toPay < 0 ? -toPay : 0.0;
      expect((creditNote['amount_residual'] as num).toDouble(), closeTo(unused, 0.05));
    }

    // Odoo's van count matches what the phone showed: 1 delivered, 2 back in.
    final after = await repo.vanStock();
    expect(after.leftOf(fromVan.id), inVan.first.left - 1 + 2);

    // Day end: one short, with a note.
    final counted = {for (final i in after.items) i.productId: i.left > 0 ? i.left : 0.0};
    counted[fromVan.id] = counted[fromVan.id]! - 1;
    expect(() => repo.sendUnload(counted), throwsArgumentError);
    final unload = await repo.sendUnload(counted, note: 'One box torn');
    await sync.sync();
    final serverUnload = (await client.searchRead('beatpro.van.transfer', domain: [
      ['id', '=', (await db.record(unload.uuid))!.serverId],
    ], fields: ['state', 'kind', 'total_difference', 'note'])).single;
    expect(serverUnload['kind'], 'unload');
    expect(serverUnload['state'], 'sent');
    expect(serverUnload['total_difference'], -1.0);
    expect(serverUnload['note'], 'One box torn');
    expect((await repo.vanStock()).serverUnload?['state'], 'sent');
    await db.close();
  }, skip: url == null ? 'Set BEATPRO_ODOO_URL to run against a live Odoo server' : false);

  // Needs a van loaded with products sold in cases, running schemes and a quantity price.
  test('cases, schemes and quantity prices on the phone match Odoo', () async {
    final client = OdooClient(await credentials());
    sqfliteFfiInit();
    final db = await LocalDb.open(factory: databaseFactoryFfi, path: inMemoryDatabasePath);
    final repo = Repository(db);
    final sync = SyncService(db, client);
    await sync.download();
    final schemes = await repo.schemes();
    expect(schemes, isNotEmpty, reason: 'set up a scheme in Odoo');
    final products = {for (final p in await db.products()) p.id: p};
    final stock = await repo.vanStock();
    final cased = products.values.where((p) => p.caseUnit != null && stock.leftOf(p.id) >= 11 * p.perUnit(p.caseUnit!)).toList();
    expect(cased, isNotEmpty, reason: 'the van needs products sold in cases');
    final stop = (await repo.todayPlan()).first;
    final pricing = await repo.pricingFor(stop.customer.key);

    // Ten cases of each product sold in cases: enough for "buy 10 cases" schemes and quantity prices.
    final lines = [
      for (final p in cased) CartLine(product: p, unitPrice: 0, unit: p.caseUnit, qty: 10),
    ];
    for (final l in lines) {
      pricing.price(l);
    }
    final free = applySchemes(lines, schemes, products, pricing);
    expect(free, isNotEmpty, reason: 'a free-goods scheme on one of these products');
    final visit = await repo.startVisit(stop.customer.key, routeId: stop.stop.routeId);
    final order = await repo.placeOrder(
      customerKey: stop.customer.key,
      visitUuid: visit.uuid,
      delivery: DeliveryMode.van,
      lines: [...lines, ...free],
    );
    final phone = (await repo.invoiceFor(order.uuid))!;
    expect(phone.saved, greaterThan(0));
    await repo.checkOut(visit.uuid, result: VisitResult.order);
    final report = await sync.sync();
    expect(report.failed, 0, reason: (await db.records(state: SyncState.failed)).map((r) => r.error).join('; '));

    // Odoo added the same free goods and priced the order as the phone did.
    final orderId = (await db.record(order.uuid))!.serverId;
    final freeLines = await client.searchRead('sale.order.line', domain: [
      ['order_id', '=', orderId],
      ['beatpro_free', '=', true],
    ], fields: ['product_id', 'product_uom_qty', 'product_uom_id']);
    expect(freeLines, hasLength(free.length));
    expect((freeLines.first['product_uom_qty'] as num).toDouble(), free.first.qty);
    final invoice = (await client.searchRead('account.move', domain: [
      ['name', '=', phone.name],
    ], fields: ['amount_untaxed', 'amount_total'])).single;
    expect((invoice['amount_untaxed'] as num).toDouble(), closeTo(phone.untaxed, 0.02));
    expect((invoice['amount_total'] as num).toDouble(), closeTo(phone.total, 0.02));
    // The free goods left the van too.
    final after = await repo.vanStock();
    final first = cased.first;
    final need = Repository.piecesNeeded([...lines, ...free])[first.id]!;
    expect(after.leftOf(first.id), closeTo(stock.leftOf(first.id) - need, 0.001));
    await db.close();
  }, skip: url == null ? 'Set BEATPRO_ODOO_URL to run against a live Odoo server' : false);
}
