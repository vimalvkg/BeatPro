import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'local_db.dart';
import 'models.dart';

/// A GPS fix, or null when the phone couldn't get one.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

/// A customer on today's plan, with today's visit if there is one.
class StopView {
  StopView(this.stop, this.customer, this.visit);

  final RouteStop stop;
  final Customer customer;
  final LocalRecord? visit;

  bool get visited => visit?.data['state'] == 'done';
  bool get inProgress => visit?.data['state'] == 'in_progress';
}

/// Totals for the day-end close screen, worked out on the phone.
class DaySummary {
  DaySummary({
    required this.planned,
    required this.visitsDone,
    required this.visitsWithOrder,
    required this.orderCount,
    required this.orderValue,
    required this.collected,
  });

  final int planned;
  final int visitsDone;
  final int visitsWithOrder;
  final int orderCount;
  final double orderValue;
  final Map<String, double> collected;

  double get totalCollected => collected.values.fold(0.0, (a, b) => a + b);
}

/// The van screen: what is in the van now, counting what the rep did on the
/// phone since the last sync, and what the main warehouse has.
class VanStockView {
  VanStockView({
    required this.van,
    required this.items,
    required this.mainItems,
    this.todayLoad,
    this.todayUnload,
    this.serverLoad,
    this.serverUnload,
  });

  final VanInfo? van;

  /// Products in the van today (loaded, sold, taken back or left).
  final List<VanItem> items;

  /// Products the main warehouse has.
  final List<VanItem> mainItems;

  /// Today's load or unload made on this phone.
  final LocalRecord? todayLoad;
  final LocalRecord? todayUnload;

  /// Today's open load and unload as Odoo last reported them (`{id, name, state}`).
  final Map<String, dynamic>? serverLoad;
  final Map<String, dynamic>? serverUnload;

  bool get hasVan => van != null;
  double get inVan => items.fold(0.0, (s, i) => s + (i.left > 0 ? i.left : 0));
  double get value => items.fold(0.0, (s, i) => s + (i.left > 0 ? i.left * i.price : 0));
  double get loaded => items.fold(0.0, (s, i) => s + i.loaded);
  double get sold => items.fold(0.0, (s, i) => s + i.sold);
  double get returned => items.fold(0.0, (s, i) => s + i.returned);

  double leftOf(int productId) => items.where((i) => i.productId == productId).firstOrNull?.left ?? 0;
  double mainOf(int productId) => mainItems.where((i) => i.productId == productId).firstOrNull?.mainQty ?? 0;

  /// A load request is waiting for the storekeeper. Odoo's answer wins once synced.
  bool get loadWaiting {
    final local = todayLoad;
    if (local != null && local.state != SyncState.synced) return local.data['selfLoad'] != true;
    return serverLoad?['state'] == 'sent';
  }
}

/// One line of goods a shop gives back.
class ReturnLine {
  ReturnLine({required this.productId, required this.name, required this.priceUnit, this.lastDate, this.qty = 1, required this.reason});

  final int productId;
  final String name;
  final double priceUnit;
  final String? lastDate;
  double qty;
  ReturnReason reason;

  double get subtotal => qty * priceUnit;
}

/// Everything a rep does in the app. Reads and writes only the phone's
/// database; [SyncService] takes care of Odoo.
class Repository {
  Repository(this.db, {DateTime Function()? clock, Uuid? uuid})
      : _clock = clock ?? DateTime.now,
        _uuid = uuid ?? const Uuid();

  final LocalDb db;
  final DateTime Function() _clock;
  final Uuid _uuid;

  DateTime get now => _clock();

  /// Midnight today, in the phone's time zone.
  DateTime get startOfToday {
    final n = now;
    return DateTime(n.year, n.month, n.day);
  }

  String get todayIso {
    final d = startOfToday;
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<AppContext?> appContext() async {
    final raw = await db.getValue('context');
    return raw == null ? null : AppContext(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<DateTime?> lastSync() async {
    final raw = await db.getValue('last_sync');
    return raw == null ? null : DateTime.parse(raw).toLocal();
  }

  // -- Today's plan and visits ------------------------------------------

  Future<List<LocalRecord>> visitsToday() =>
      db.records(kind: RecordKind.visit, since: startOfToday.toUtc());

  Future<List<StopView>> todayPlan() async {
    final stops = await db.stops();
    final visits = await visitsToday();
    final result = <StopView>[];
    for (final stop in stops) {
      final customer = await db.customer(stop.customerKey);
      if (customer == null) continue;
      final visit = visits.lastWhereOrNull((v) => v.data['customerKey'] == stop.customerKey);
      result.add(StopView(stop, customer, visit));
    }
    return result;
  }

  Future<LocalRecord?> activeVisit() async {
    final visits = await visitsToday();
    return visits.lastWhereOrNull((v) => v.data['state'] == 'in_progress');
  }

  Future<LocalRecord> startVisit(String customerKey, {int? routeId, GeoPoint? at}) async {
    final active = await activeVisit();
    if (active != null) {
      if (active.data['customerKey'] == customerKey) return active;
      throw StateError('Check out of your current visit before starting another.');
    }
    final visit = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.visit,
      createdAt: now,
      data: {
        'customerKey': customerKey,
        'routeId': routeId,
        'state': 'in_progress',
        'checkIn': now.toUtc().toIso8601String(),
        'checkInLat': at?.latitude,
        'checkInLng': at?.longitude,
      },
    );
    await db.saveRecord(visit);
    return visit;
  }

  Future<LocalRecord> checkOut(
    String visitUuid, {
    required VisitResult result,
    String? noOrderReason,
    String? note,
    GeoPoint? at,
  }) async {
    final visit = await db.record(visitUuid);
    if (visit == null || visit.data['state'] != 'in_progress') {
      throw StateError('This visit has already ended.');
    }
    if (result == VisitResult.noOrder && noOrderReason == null) {
      throw ArgumentError('Choose why there was no order.');
    }
    final updated = visit.copyWith(data: {
      ...visit.data,
      'state': 'done',
      'checkOut': now.toUtc().toIso8601String(),
      'checkOutLat': at?.latitude,
      'checkOutLng': at?.longitude,
      'result': result.code,
      'noOrderReason': result == VisitResult.noOrder ? noOrderReason : null,
      'note': note,
    });
    await db.saveRecord(updated);
    return updated;
  }

  // -- Orders ---------------------------------------------------------------

  Future<LocalRecord> placeOrder({
    required String customerKey,
    String? visitUuid,
    required List<CartLine> lines,
    String? note,
    DeliveryMode? delivery,
  }) async {
    if (lines.isEmpty) throw ArgumentError('Add at least one product.');
    final totals = OrderTotals.of(lines);
    Map<int, double> vanLines = {};
    if (delivery != null) {
      final stock = await vanStock();
      if (stock.hasVan) {
        vanLines = vanLinesFor(delivery, lines, stock);
        if (delivery == DeliveryMode.van && lines.any((l) => stock.leftOf(l.product.id) < l.qty)) {
          throw StateError('The van does not have enough of every product. Choose another way to deliver.');
        }
      } else {
        delivery = null;
      }
    }
    final order = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.order,
      createdAt: now,
      data: {
        'customerKey': customerKey,
        'visitUuid': visitUuid,
        'note': note,
        'lines': [
          for (final l in lines)
            {
              'productId': l.product.id,
              'name': l.product.name,
              'qty': l.qty,
              'unitPrice': l.unitPrice,
              'discount': l.discount,
              'taxPercent': l.product.taxPercent,
            },
        ],
        'deliveryMode': delivery?.code,
        'vanLines': {for (final e in vanLines.entries) '${e.key}': e.value},
        'untaxed': totals.untaxed,
        'tax': totals.tax,
        'total': totals.total,
      },
    );
    await db.saveRecord(order);
    return order;
  }

  Future<List<LocalRecord>> orders({DateTime? since}) async =>
      (await db.records(kind: RecordKind.order, since: since)).reversed.toList();

  Future<LocalRecord?> lastOrderFor(String customerKey) async {
    final all = await db.records(kind: RecordKind.order);
    return all.lastWhereOrNull((o) => o.data['customerKey'] == customerKey);
  }

  /// A not-yet-synced order can still be cancelled on the phone.
  Future<void> cancelOrder(String uuid) async {
    final order = await db.record(uuid);
    if (order == null || order.state == SyncState.synced) {
      throw StateError('This order is already in Odoo. Ask your supervisor to cancel it.');
    }
    await db.deleteRecord(uuid);
  }

  // -- Van sales -------------------------------------------------------------

  Future<VanStockView> vanStock() async {
    final context = await appContext();
    final van = context?.van;
    final raw = await db.getValue('van_stock');
    final snapshot = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    final items = <int, VanItem>{
      for (final r in ((snapshot['van_items'] as List?) ?? const []).cast<Map<String, dynamic>>())
        r['product_id'] as int: VanItem.fromOdoo(r),
    };
    final main = <int, VanItem>{
      for (final r in ((snapshot['main_items'] as List?) ?? const []).cast<Map<String, dynamic>>())
        r['product_id'] as int: VanItem.fromOdoo(r),
    };
    final products = {for (final p in await db.products()) p.id: p};
    VanItem item(int productId) => items[productId] ??= VanItem(
          productId: productId,
          name: products[productId]?.name ?? main[productId]?.name ?? '',
          price: products[productId]?.listPrice ?? main[productId]?.price ?? 0,
        );

    // What the rep did on the phone since Odoo last counted the van.
    final unsynced = [...await db.records(state: SyncState.pending), ...await db.records(state: SyncState.failed)];
    for (final r in unsynced) {
      switch (r.kind) {
        case RecordKind.order:
          final vanLines = (r.data['vanLines'] as Map?)?.cast<String, dynamic>() ?? const {};
          vanLines.forEach((id, qty) {
            final i = item(int.parse(id));
            i.left -= (qty as num).toDouble();
            i.sold += qty.toDouble();
          });
        case RecordKind.shopReturn:
          for (final l in (r.data['lines'] as List).cast<Map<String, dynamic>>()) {
            if (l['resellable'] != true) continue;
            final i = item(l['productId'] as int);
            i.left += (l['qty'] as num).toDouble();
            i.returned += (l['qty'] as num).toDouble();
          }
        case RecordKind.vanTransfer when r.data['kind'] == 'load' && r.data['selfLoad'] == true:
          for (final l in (r.data['lines'] as List).cast<Map<String, dynamic>>()) {
            final i = item(l['productId'] as int);
            i.left += (l['qty'] as num).toDouble();
            i.loaded += (l['qty'] as num).toDouble();
            main[l['productId'] as int]?.mainQty -= (l['qty'] as num).toDouble();
          }
        default:
          break;
      }
    }
    final transfers = await db.records(kind: RecordKind.vanTransfer, since: startOfToday.toUtc());
    final sorted = items.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return VanStockView(
      van: van,
      items: van == null ? [] : sorted.where((i) => i.loaded != 0 || i.sold != 0 || i.returned != 0 || i.left != 0).toList(),
      mainItems: (main.values.where((i) => i.mainQty > 0).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()))),
      todayLoad: transfers.lastWhereOrNull((t) => t.data['kind'] == 'load'),
      todayUnload: transfers.lastWhereOrNull((t) => t.data['kind'] == 'unload'),
      serverLoad: snapshot['open_load'] is Map ? (snapshot['open_load'] as Map).cast<String, dynamic>() : null,
      serverUnload: snapshot['unload'] is Map ? (snapshot['unload'] as Map).cast<String, dynamic>() : null,
    );
  }

  /// Today's suggested load, from Odoo: `[{product_id, name, qty, main_qty}]`.
  Future<List<Map<String, dynamic>>> loadSuggestion() async {
    final raw = await db.getValue('load_suggestion');
    return raw == null ? [] : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  /// Asks the storekeeper for stock for the van (or loads it, for reps who load their own van).
  Future<LocalRecord> requestLoad(Map<Product, double> quantities) async {
    final van = (await appContext())?.van;
    if (van == null) throw StateError('You have no van. Ask your supervisor to set one up.');
    final lines = [
      for (final e in quantities.entries)
        if (e.value > 0) {'productId': e.key.id, 'name': e.key.name, 'qty': e.value},
    ];
    if (lines.isEmpty) throw ArgumentError('Enter the quantities to load.');
    final record = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.vanTransfer,
      createdAt: now,
      data: {'kind': 'load', 'date': todayIso, 'selfLoad': van.selfLoad, 'lines': lines},
    );
    await db.saveRecord(record);
    return record;
  }

  /// Sends the day-end count. A difference from what should be in the van needs a note.
  Future<LocalRecord> sendUnload(Map<int, double> counted, {String? note}) async {
    final stock = await vanStock();
    if (!stock.hasVan) throw StateError('You have no van.');
    final existing = stock.todayUnload;
    if (existing != null) return existing;
    final lines = <Map<String, dynamic>>[];
    var differs = false;
    for (final i in stock.items) {
      final expected = i.left > 0 ? i.left : 0.0;
      final qty = counted[i.productId] ?? expected;
      if (expected == 0 && qty == 0) continue;
      if ((qty - expected).abs() > 0.0001) differs = true;
      lines.add({'productId': i.productId, 'name': i.name, 'expected': expected, 'qty': qty});
    }
    if (differs && (note == null || note.trim().isEmpty)) {
      throw ArgumentError('Your count differs from what should be in the van. Add a note saying why.');
    }
    final record = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.vanTransfer,
      createdAt: now,
      data: {'kind': 'unload', 'date': todayIso, 'note': note?.trim(), 'lines': lines},
    );
    await db.saveRecord(record);
    return record;
  }

  /// What the shop bought lately, with the price it paid; other products at their sales price.
  Future<List<ReturnCandidate>> returnCandidates(String customerKey) async {
    final raw = await db.getValue('return_candidates');
    final all = raw == null ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    final serverId = customerKey.startsWith('srv:') ? customerKey.substring(4) : null;
    final bought = ((all[serverId] as List?) ?? const []).cast<Map<String, dynamic>>().map(ReturnCandidate.fromOdoo).toList();
    final seen = {for (final c in bought) c.productId};
    return [
      ...bought,
      for (final p in await db.products())
        if (!seen.contains(p.id)) ReturnCandidate(productId: p.id, name: p.name, lastDate: null, priceUnit: p.listPrice),
    ];
  }

  /// Takes goods back from a shop. Goods that can be sold again go back into the van.
  Future<LocalRecord> takeBack({required String customerKey, String? visitUuid, required List<ReturnLine> lines}) async {
    final kept = lines.where((l) => l.qty > 0).toList();
    if (kept.isEmpty) throw ArgumentError('Add the products the shop is giving back.');
    final record = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.shopReturn,
      createdAt: now,
      data: {
        'customerKey': customerKey,
        'visitUuid': visitUuid,
        'date': todayIso,
        'lines': [
          for (final l in kept)
            {
              'productId': l.productId,
              'name': l.name,
              'qty': l.qty,
              'reason': l.reason.value,
              'reasonLabel': l.reason.label,
              'resellable': l.reason.resellable,
              'priceUnit': l.priceUnit,
            },
        ],
        'total': kept.fold(0.0, (s, l) => s + l.subtotal),
      },
    );
    await db.saveRecord(record);
    return record;
  }

  Future<List<LocalRecord>> returnsFor(String visitUuid) async =>
      (await db.records(kind: RecordKind.shopReturn)).where((r) => r.data['visitUuid'] == visitUuid).toList();

  /// Which lines the van hands over now, for each delivery choice.
  static Map<int, double> vanLinesFor(DeliveryMode mode, List<CartLine> lines, VanStockView stock) {
    if (mode == DeliveryMode.warehouse) return {};
    final left = {for (final i in stock.items) i.productId: i.left};
    final result = <int, double>{};
    for (final l in lines) {
      final have = left[l.product.id] ?? 0;
      if (mode == DeliveryMode.van || have >= l.qty) {
        result[l.product.id] = (result[l.product.id] ?? 0) + l.qty;
        left[l.product.id] = have - l.qty;
      }
    }
    return result;
  }

  // -- Payments -------------------------------------------------------------

  Future<LocalRecord> collectPayment({
    required String customerKey,
    String? visitUuid,
    required double amount,
    required PaymentMethod method,
    List<int> invoiceIds = const [],
    String? chequeNumber,
    String? chequeDate,
    String? reference,
  }) async {
    if (amount <= 0) throw ArgumentError('Enter the amount collected.');
    if (method.reference == 'cheque' && (chequeNumber == null || chequeNumber.trim().isEmpty)) {
      throw ArgumentError('Enter the cheque number.');
    }
    final payment = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.payment,
      createdAt: now,
      data: {
        'customerKey': customerKey,
        'visitUuid': visitUuid,
        'amount': amount,
        'methodId': method.id,
        'method': method.legacyCode,
        'methodName': method.name,
        'kind': method.kind,
        'invoiceIds': invoiceIds,
        'chequeNumber': chequeNumber,
        'chequeDate': chequeDate,
        'reference': reference,
        'date': todayIso,
      },
    );
    await db.saveRecord(payment);
    // Show the invoices as settled straight away, oldest first.
    var left = amount;
    final open = await db.invoices(customerKey: customerKey);
    for (final invoice in open.where((i) => invoiceIds.contains(i.id))) {
      if (left <= 0) break;
      final applied = left < invoice.amountDue ? left : invoice.amountDue;
      await db.reduceInvoiceDue(invoice.id, applied);
      left -= applied;
    }
    return payment;
  }

  // -- Customers -------------------------------------------------------------

  Future<Customer> addCustomer({
    required String name,
    String? phone,
    String? street,
    String? city,
    GeoPoint? at,
  }) async {
    if (name.trim().isEmpty) throw ArgumentError('Enter the shop name.');
    final uuid = _uuid.v4();
    final customer = Customer(
      key: 'loc:$uuid',
      uuid: uuid,
      name: name.trim(),
      phone: phone,
      street: street,
      city: city,
      latitude: at?.latitude,
      longitude: at?.longitude,
    );
    await db.saveCustomer(customer);
    await db.saveRecord(LocalRecord(
      uuid: uuid,
      kind: RecordKind.customer,
      createdAt: now,
      data: customer.toJson(),
    ));
    return customer;
  }

  Future<double> amountDue(String customerKey) async =>
      (await db.invoices(customerKey: customerKey)).fold<double>(0.0, (sum, i) => sum + i.amountDue);

  // -- Day-end close -----------------------------------------------------------

  Future<DaySummary> todaySummary() async {
    final since = startOfToday.toUtc();
    final visits = (await db.records(kind: RecordKind.visit, since: since))
        .where((v) => v.data['state'] == 'done')
        .toList();
    final orders = await db.records(kind: RecordKind.order, since: since);
    final payments = await db.records(kind: RecordKind.payment, since: since);
    final collected = <String, double>{for (final k in collectionKinds.keys) k: 0.0};
    for (final p in payments) {
      final kind = paymentKind(p.data);
      collected[kind] = (collected[kind] ?? 0) + (p.data['amount'] as num).toDouble();
    }
    return DaySummary(
      planned: (await db.stops()).length,
      visitsDone: visits.length,
      visitsWithOrder: visits.where((v) => v.data['result'] == 'order').length,
      orderCount: orders.length,
      orderValue: orders.fold(0.0, (sum, o) => sum + ((o.data['amountTotal'] ?? o.data['total']) as num).toDouble()),
      collected: collected,
    );
  }

  Future<LocalRecord?> todayClose() async {
    final closes = await db.records(kind: RecordKind.dayClose);
    return closes.lastWhereOrNull((c) => c.data['date'] == todayIso);
  }

  Future<LocalRecord> closeDay({double distanceKm = 0, String? note}) async {
    if (await activeVisit() != null) {
      throw StateError('Check out of your current visit before closing the day.');
    }
    final existing = await todayClose();
    if (existing != null) return existing;
    final close = LocalRecord(
      uuid: _uuid.v4(),
      kind: RecordKind.dayClose,
      createdAt: now,
      data: {'date': todayIso, 'distanceKm': distanceKm, 'note': note},
    );
    await db.saveRecord(close);
    return close;
  }

  Future<int> pendingCount() async =>
      (await db.records(state: SyncState.pending)).length + (await db.records(state: SyncState.failed)).length;
}

extension _LastWhere<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}
