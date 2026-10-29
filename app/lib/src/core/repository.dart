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
  }) async {
    if (lines.isEmpty) throw ArgumentError('Add at least one product.');
    final totals = OrderTotals.of(lines);
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

  // -- Payments -------------------------------------------------------------

  Future<LocalRecord> collectPayment({
    required String customerKey,
    String? visitUuid,
    required double amount,
    required String method,
    List<int> invoiceIds = const [],
    String? chequeNumber,
    String? chequeDate,
    String? upiReference,
  }) async {
    if (amount <= 0) throw ArgumentError('Enter the amount collected.');
    if (!paymentMethods.containsKey(method)) throw ArgumentError('Choose cash, cheque or UPI.');
    if (method == 'cheque' && (chequeNumber == null || chequeNumber.trim().isEmpty)) {
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
        'method': method,
        'invoiceIds': invoiceIds,
        'chequeNumber': chequeNumber,
        'chequeDate': chequeDate,
        'upiReference': upiReference,
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
    final collected = <String, double>{for (final m in paymentMethods.keys) m: 0.0};
    for (final p in payments) {
      collected[p.data['method'] as String] = collected[p.data['method']]! + (p.data['amount'] as num).toDouble();
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
