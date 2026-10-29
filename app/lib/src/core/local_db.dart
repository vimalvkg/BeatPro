import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// The phone's copy of the rep's data. Everything the screens show is read
/// from here, so the app works without a connection.
class LocalDb {
  LocalDb._(this._db);

  final Database _db;

  static const _version = 1;

  static Future<LocalDb> open({required DatabaseFactory factory, required String path}) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: _version, onCreate: (db, _) => _create(db)),
    );
    return LocalDb._(db);
  }

  static Future<void> _create(Database db) async {
    final batch = db.batch();
    batch.execute('CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT)');
    batch.execute('CREATE TABLE customers (key TEXT PRIMARY KEY, server_id INTEGER, name TEXT, data TEXT)');
    batch.execute('CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, data TEXT)');
    batch.execute('CREATE TABLE prices (pricelist_id INTEGER, product_id INTEGER, price REAL, '
        'PRIMARY KEY (pricelist_id, product_id))');
    batch.execute('CREATE TABLE stops (route_id INTEGER, route_name TEXT, sequence INTEGER, customer_key TEXT)');
    batch.execute('CREATE TABLE invoices (id INTEGER PRIMARY KEY, customer_key TEXT, data TEXT)');
    batch.execute('CREATE TABLE records (uuid TEXT PRIMARY KEY, kind TEXT, data TEXT, state TEXT, '
        'server_id INTEGER, error TEXT, created_at TEXT)');
    await batch.commit(noResult: true);
  }

  Future<void> close() => _db.close();

  // -- Settings -----------------------------------------------------------

  Future<String?> getValue(String key) async {
    final rows = await _db.query('kv', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setValue(String key, String? value) =>
      _db.insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);

  // -- Data downloaded from Odoo -------------------------------------------

  /// Replaces everything downloaded from Odoo in one transaction, so the
  /// screens never see a half-finished download. Customers added on the
  /// phone are kept.
  Future<void> replaceDownloaded({
    required List<Customer> customers,
    required List<Product> products,
    required Map<int, Map<int, double>> prices,
    required List<RouteStop> stops,
    required List<OpenInvoice> invoices,
  }) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      batch.delete('customers', where: "key LIKE 'srv:%'");
      batch.delete('products');
      batch.delete('prices');
      batch.delete('stops');
      batch.delete('invoices');
      for (final c in customers) {
        batch.insert('customers', {'key': c.key, 'server_id': c.serverId, 'name': c.name, 'data': jsonEncode(c.toJson())},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final p in products) {
        batch.insert('products', {'id': p.id, 'name': p.name, 'data': jsonEncode(p.toJson())});
      }
      prices.forEach((pricelistId, byProduct) {
        byProduct.forEach((productId, price) {
          batch.insert('prices', {'pricelist_id': pricelistId, 'product_id': productId, 'price': price});
        });
      });
      for (final s in stops) {
        batch.insert('stops', {
          'route_id': s.routeId,
          'route_name': s.routeName,
          'sequence': s.sequence,
          'customer_key': s.customerKey,
        });
      }
      for (final i in invoices) {
        batch.insert('invoices', {'id': i.id, 'customer_key': i.customerKey, 'data': jsonEncode(i.toJson())});
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Customer>> customers({String? search}) async {
    final rows = await _db.query(
      'customers',
      where: search == null || search.isEmpty ? null : 'name LIKE ?',
      whereArgs: search == null || search.isEmpty ? null : ['%$search%'],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map((r) => Customer.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>)).toList();
  }

  Future<Customer?> customer(String key) async {
    final rows = await _db.query('customers', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : Customer.fromJson(jsonDecode(rows.first['data'] as String) as Map<String, dynamic>);
  }

  Future<void> saveCustomer(Customer c) => _db.insert(
        'customers',
        {'key': c.key, 'server_id': c.serverId, 'name': c.name, 'data': jsonEncode(c.toJson())},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<Product>> products({String? search}) async {
    final rows = await _db.query(
      'products',
      where: search == null || search.isEmpty ? null : 'name LIKE ?',
      whereArgs: search == null || search.isEmpty ? null : ['%$search%'],
      orderBy: 'name COLLATE NOCASE',
    );
    return rows.map((r) => Product.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>)).toList();
  }

  /// The customer's price for each product: their price list's price where
  /// Odoo sent one, otherwise the product's sales price.
  Future<Map<int, double>> pricesFor(int? pricelistId) async {
    if (pricelistId == null) return {};
    final rows = await _db.query('prices', where: 'pricelist_id = ?', whereArgs: [pricelistId]);
    return {for (final r in rows) r['product_id'] as int: (r['price'] as num).toDouble()};
  }

  Future<List<RouteStop>> stops() async {
    final rows = await _db.query('stops', orderBy: 'route_name, sequence');
    return rows
        .map((r) => RouteStop(
              routeId: r['route_id'] as int,
              routeName: r['route_name'] as String,
              sequence: r['sequence'] as int,
              customerKey: r['customer_key'] as String,
            ))
        .toList();
  }

  Future<List<OpenInvoice>> invoices({String? customerKey}) async {
    final rows = await _db.query(
      'invoices',
      where: customerKey == null ? null : 'customer_key = ?',
      whereArgs: customerKey == null ? null : [customerKey],
      orderBy: 'id',
    );
    return rows.map((r) => OpenInvoice.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>)).toList();
  }

  /// Lowers what the phone shows as due on an invoice after a collection,
  /// until the next download brings Odoo's figure.
  Future<void> reduceInvoiceDue(int invoiceId, double amount) async {
    final rows = await _db.query('invoices', where: 'id = ?', whereArgs: [invoiceId]);
    if (rows.isEmpty) return;
    final invoice = OpenInvoice.fromJson(jsonDecode(rows.first['data'] as String) as Map<String, dynamic>);
    final left = invoice.amountDue - amount;
    if (left <= 0.005) {
      await _db.delete('invoices', where: 'id = ?', whereArgs: [invoiceId]);
    } else {
      final updated = OpenInvoice(
        id: invoice.id,
        customerKey: invoice.customerKey,
        name: invoice.name,
        amountDue: left,
        dueDate: invoice.dueDate,
        overdue: invoice.overdue,
      );
      await _db.update('invoices', {'data': jsonEncode(updated.toJson())}, where: 'id = ?', whereArgs: [invoiceId]);
    }
  }

  // -- Records made on the phone -----------------------------------------

  Future<void> saveRecord(LocalRecord r) => _db.insert(
        'records',
        {
          'uuid': r.uuid,
          'kind': r.kind.name,
          'data': jsonEncode(r.data),
          'state': r.state.name,
          'server_id': r.serverId,
          'error': r.error,
          'created_at': r.createdAt.toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<LocalRecord?> record(String uuid) async {
    final rows = await _db.query('records', where: 'uuid = ?', whereArgs: [uuid]);
    return rows.isEmpty ? null : _record(rows.first);
  }

  Future<List<LocalRecord>> records({RecordKind? kind, SyncState? state, DateTime? since}) async {
    final where = <String>[];
    final args = <Object>[];
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind.name);
    }
    if (state != null) {
      where.add('state = ?');
      args.add(state.name);
    }
    if (since != null) {
      where.add('created_at >= ?');
      args.add(since.toUtc().toIso8601String());
    }
    final rows = await _db.query(
      'records',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at',
    );
    return rows.map(_record).toList();
  }

  LocalRecord _record(Map<String, Object?> r) => LocalRecord(
        uuid: r['uuid'] as String,
        kind: RecordKind.values.byName(r['kind'] as String),
        data: jsonDecode(r['data'] as String) as Map<String, dynamic>,
        state: SyncState.values.byName(r['state'] as String),
        serverId: r['server_id'] as int?,
        error: r['error'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
      );

  Future<void> deleteRecord(String uuid) => _db.delete('records', where: 'uuid = ?', whereArgs: [uuid]);

  /// Removes everything, for signing out.
  Future<void> clear() async {
    for (final table in ['kv', 'customers', 'products', 'prices', 'stops', 'invoices', 'records']) {
      await _db.delete(table);
    }
  }
}
