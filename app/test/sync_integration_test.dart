// Runs a rep's full day against a real Odoo 19 server with the BeatPro module.
//
//   BEATPRO_ODOO_URL=http://127.0.0.1:8069 BEATPRO_ODOO_DB=beatpro_e2e \
//   BEATPRO_ODOO_KEY=<rep API key> flutter test test/sync_integration_test.dart
//
// Skipped when BEATPRO_ODOO_URL isn't set.
import 'dart:io';

import 'package:beatpro/src/core/local_db.dart';
import 'package:beatpro/src/core/models.dart';
import 'package:beatpro/src/core/odoo_client.dart';
import 'package:beatpro/src/core/repository.dart';
import 'package:beatpro/src/core/sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  final env = Platform.environment;
  final url = env['BEATPRO_ODOO_URL'];

  test('a rep works a full day offline, then syncs to Odoo', () async {
    final client = OdooClient(OdooCredentials(
      url: url!,
      database: env['BEATPRO_ODOO_DB'] ?? '',
      apiKey: env['BEATPRO_ODOO_KEY']!,
    ));
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
        method: 'upi',
        upiReference: 'UPI-TEST-1',
        invoiceIds: invoices.map((i) => i.id).toList(),
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

    // The new shop came back from Odoo as a customer.
    expect((await db.customers(search: 'Test Shop')).any((c) => c.serverId != null), isTrue);
    await db.close();
  }, skip: url == null ? 'Set BEATPRO_ODOO_URL to run against a live Odoo server' : false);
}
