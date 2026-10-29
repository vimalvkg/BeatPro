import 'dart:convert';

import 'local_db.dart';
import 'models.dart';
import 'odoo_client.dart';

/// What a sync did, for the Sync screen.
class SyncReport {
  int uploaded = 0;
  int failed = 0;
  int waiting = 0;
  bool downloaded = false;
  String? offlineMessage;

  bool get ok => offlineMessage == null && failed == 0;
}

/// Moves data between the phone and Odoo: uploads what the rep did, then
/// downloads a fresh copy of customers, products, prices, plan and invoices.
///
/// Every record carries a mobile UUID, so a sync that is cut off half way can
/// simply run again: Odoo returns the records it already has.
class SyncService {
  SyncService(this.db, this.client);

  final LocalDb db;
  final OdooClient client;

  bool _running = false;

  Future<SyncReport> sync() async {
    final report = SyncReport();
    if (_running) return report;
    _running = true;
    try {
      await upload(report);
      await download();
      report.downloaded = true;
      await db.setValue('last_sync', DateTime.now().toUtc().toIso8601String());
    } on OfflineException catch (e) {
      report.offlineMessage = e.toString();
    } finally {
      _running = false;
    }
    return report;
  }

  // -- Download ------------------------------------------------------------

  Future<void> download() async {
    final context = await client.call('res.users', 'beatpro_app_context') as Map<String, dynamic>;
    final app = AppContext(context);

    final plan = (await client.call('beatpro.route', 'beatpro_today_plan') as List).cast<Map<String, dynamic>>();

    final customerRows = await client.searchRead(
      'res.partner',
      domain: [
        '|',
        ['beatpro_route_line_ids.route_id.user_id', '=', app.userId],
        ['create_uid', '=', app.userId],
      ],
      fields: ['name', 'phone', 'street', 'city', 'partner_latitude', 'partner_longitude', 'property_product_pricelist'],
      order: 'name',
    );
    final customers = customerRows.map(Customer.fromOdoo).toList();

    final productRows = await client.searchRead(
      'product.product',
      domain: [
        ['sale_ok', '=', true],
      ],
      fields: ['display_name', 'lst_price', 'qty_available', 'default_code', 'uom_id', 'categ_id', 'taxes_id'],
      order: 'name',
      context: {if (app.warehouseId != null) 'warehouse_id': app.warehouseId},
    );
    final taxIds = {for (final r in productRows) ...(r['taxes_id'] as List).cast<int>()};
    final taxPercent = <int, double>{};
    if (taxIds.isNotEmpty) {
      final taxes = await client.searchRead('account.tax', domain: [
        ['id', 'in', taxIds.toList()],
      ], fields: ['amount', 'amount_type']);
      for (final t in taxes) {
        taxPercent[t['id'] as int] = t['amount_type'] == 'percent' ? (t['amount'] as num).toDouble() : 0.0;
      }
    }
    final products = [
      for (final r in productRows)
        Product.fromOdoo(r, (r['taxes_id'] as List).cast<int>().fold(0.0, (sum, id) => sum + (taxPercent[id] ?? 0))),
    ];

    final pricelistIds = {for (final c in customers) if (c.pricelistId != null) c.pricelistId!};
    final prices = <int, Map<int, double>>{};
    if (pricelistIds.isNotEmpty && products.isNotEmpty) {
      final raw = await client.call('product.pricelist', 'beatpro_prices', kwargs: {
        'pricelist_ids': pricelistIds.toList(),
        'product_ids': products.map((p) => p.id).toList(),
      }) as Map<String, dynamic>;
      raw.forEach((pricelist, byProduct) {
        prices[int.parse(pricelist)] = {
          for (final e in (byProduct as Map<String, dynamic>).entries) int.parse(e.key): (e.value as num).toDouble(),
        };
      });
    }

    final invoices = customers.isEmpty
        ? <OpenInvoice>[]
        : ((await client.call('res.partner', 'beatpro_open_invoices', kwargs: {
            'partner_ids': customers.map((c) => c.serverId).toList(),
          })) as List)
            .cast<Map<String, dynamic>>()
            .map(OpenInvoice.fromOdoo)
            .toList();

    final stops = [
      for (final s in plan)
        RouteStop(
          routeId: s['route_id'] as int,
          routeName: s['route_name'] as String,
          sequence: s['sequence'] as int,
          customerKey: 'srv:${s['partner_id']}',
        ),
    ];

    await db.setValue('context', jsonEncode(context));
    await db.replaceDownloaded(
      customers: customers,
      products: products,
      prices: prices,
      stops: stops,
      invoices: invoices,
    );
  }

  // -- Upload ----------------------------------------------------------------

  Future<void> upload(SyncReport report) async {
    final pending = [
      ...await db.records(state: SyncState.pending),
      ...await db.records(state: SyncState.failed),
    ]..sort((a, b) {
        final byKind = a.kind.index.compareTo(b.kind.index);
        return byKind != 0 ? byKind : a.createdAt.compareTo(b.createdAt);
      });

    for (final record in pending) {
      // Re-read: an earlier upload in this run may have changed it.
      final current = await db.record(record.uuid);
      if (current == null || current.state == SyncState.synced) continue;
      try {
        final done = await _upload(current);
        if (done) {
          report.uploaded++;
        } else {
          report.waiting++;
        }
      } on OdooException catch (e) {
        report.failed++;
        await db.saveRecord(current.copyWith(state: SyncState.failed, error: e.message));
      }
    }
  }

  /// Uploads one record. Returns false when it has to wait for another one
  /// (a visit still in progress, or a customer not yet in Odoo).
  Future<bool> _upload(LocalRecord r) async {
    switch (r.kind) {
      case RecordKind.customer:
        final id = await _upsert('res.partner', r.uuid, {
          'name': r.data['name'],
          'phone': r.data['phone'],
          'street': r.data['street'],
          'city': r.data['city'],
          'partner_latitude': r.data['latitude'] ?? 0,
          'partner_longitude': r.data['longitude'] ?? 0,
          'customer_rank': 1,
        });
        final customer = Customer.fromJson(r.data);
        await db.saveCustomer(Customer(
          key: customer.key,
          serverId: id,
          uuid: customer.uuid,
          name: customer.name,
          phone: customer.phone,
          street: customer.street,
          city: customer.city,
          latitude: customer.latitude,
          longitude: customer.longitude,
        ));
        await _markSynced(r, id);
        return true;

      case RecordKind.visit:
        if (r.data['state'] != 'done') return false;
        final partnerId = await _customerId(r.data['customerKey'] as String);
        if (partnerId == null) return false;
        final id = await _upsert('beatpro.visit', r.uuid, {
          'partner_id': partnerId,
          'route_id': r.data['routeId'],
          'state': 'done',
          'check_in': _odooDatetime(r.data['checkIn']),
          'check_out': _odooDatetime(r.data['checkOut']),
          'check_in_latitude': r.data['checkInLat'] ?? 0,
          'check_in_longitude': r.data['checkInLng'] ?? 0,
          'check_out_latitude': r.data['checkOutLat'] ?? 0,
          'check_out_longitude': r.data['checkOutLng'] ?? 0,
          'result': r.data['result'],
          'no_order_reason': r.data['noOrderReason'] ?? false,
          'note': r.data['note'] ?? false,
        });
        await _markSynced(r, id);
        return true;

      case RecordKind.order:
        final partnerId = await _customerId(r.data['customerKey'] as String);
        if (partnerId == null) return false;
        final visitUuid = r.data['visitUuid'] as String?;
        int? visitId;
        if (visitUuid != null) {
          visitId = await _serverIdOf(visitUuid);
          if (visitId == null) return false;
        }
        final result = await client.call('sale.order', 'beatpro_submit_orders', kwargs: {
          'vals_list': [
            {
              'mobile_uuid': r.uuid,
              'partner_id': partnerId,
              'beatpro_visit_id': visitId ?? false,
              'note': r.data['note'] ?? false,
              'order_line': [
                for (final l in (r.data['lines'] as List).cast<Map<String, dynamic>>())
                  [
                    0,
                    0,
                    {'product_id': l['productId'], 'product_uom_qty': l['qty'], 'discount': l['discount']},
                  ],
              ],
            },
          ],
        }) as Map<String, dynamic>;
        final info = result[r.uuid] as Map<String, dynamic>;
        await db.saveRecord(r.copyWith(
          state: SyncState.synced,
          serverId: info['id'] as int,
          data: {
            ...r.data,
            'name': info['name'],
            'odooState': info['state'],
            'approval': info['approval'] == false ? null : info['approval'],
            'amountTotal': info['amount_total'],
          },
        ));
        return true;

      case RecordKind.payment:
        final partnerId = await _customerId(r.data['customerKey'] as String);
        if (partnerId == null) return false;
        final visitUuid = r.data['visitUuid'] as String?;
        int? visitId;
        if (visitUuid != null) {
          visitId = await _serverIdOf(visitUuid);
          if (visitId == null) return false;
        }
        final result = await client.call('account.payment', 'beatpro_register_payment', kwargs: {
          'vals_list': [
            {
              'mobile_uuid': r.uuid,
              'partner_id': partnerId,
              'amount': r.data['amount'],
              'date': r.data['date'],
              'beatpro_method': r.data['method'],
              'beatpro_visit_id': visitId ?? false,
              'invoice_ids': r.data['invoiceIds'] ?? [],
              'beatpro_cheque_number': r.data['chequeNumber'] ?? false,
              'beatpro_cheque_date': r.data['chequeDate'] ?? false,
              'beatpro_upi_reference': r.data['upiReference'] ?? false,
            },
          ],
        }) as Map<String, dynamic>;
        await _markSynced(r, result[r.uuid] as int);
        return true;

      case RecordKind.dayClose:
        // Wait until the day's visits, orders and payments are all in Odoo.
        final others = await db.records(state: SyncState.pending);
        if (others.any((o) => o.kind != RecordKind.dayClose)) return false;
        final id = await _upsert('beatpro.day.close', r.uuid, {
          'date': r.data['date'],
          'distance_km': r.data['distanceKm'] ?? 0,
          'note': r.data['note'] ?? false,
        });
        await client.call('beatpro.day.close', 'action_close', ids: [id]);
        await _markSynced(r, id);
        return true;
    }
  }

  Future<int> _upsert(String model, String uuid, Map<String, dynamic> vals) async {
    final result = await client.call(model, 'beatpro_upsert', kwargs: {
      'vals_list': [
        {'mobile_uuid': uuid, ...vals},
      ],
    }) as Map<String, dynamic>;
    return result[uuid] as int;
  }

  Future<void> _markSynced(LocalRecord r, int serverId) =>
      db.saveRecord(r.copyWith(state: SyncState.synced, serverId: serverId));

  Future<int?> _customerId(String key) async {
    if (key.startsWith('srv:')) return int.parse(key.substring(4));
    return (await db.customer(key))?.serverId;
  }

  Future<int?> _serverIdOf(String uuid) async => (await db.record(uuid))?.serverId;

  /// Odoo stores datetimes as `YYYY-MM-DD HH:MM:SS` in UTC.
  static String? _odooDatetime(dynamic iso) {
    if (iso == null) return null;
    final d = DateTime.parse(iso as String).toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
