import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'growth.dart';
import 'invoice.dart';
import 'local_db.dart';
import 'models.dart';
import 'schemes.dart';

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

/// The rep's thermal printer, kept on the phone.
class PrinterSettings {
  PrinterSettings({this.address, this.name, this.paper = '80', this.autoPrint = false, this.copies = 1});

  final String? address;
  final String? name;

  /// '80' or '58' mm.
  final String paper;
  final bool autoPrint;
  final int copies;

  bool get ready => address != null;

  PrinterSettings copyWith({String? address, String? name, String? paper, bool? autoPrint, int? copies}) => PrinterSettings(
        address: address ?? this.address,
        name: name ?? this.name,
        paper: paper ?? this.paper,
        autoPrint: autoPrint ?? this.autoPrint,
        copies: copies ?? this.copies,
      );

  Map<String, dynamic> toJson() =>
      {'address': address, 'name': name, 'paper': paper, 'autoPrint': autoPrint, 'copies': copies};

  static PrinterSettings fromJson(Map<String, dynamic> j) => PrinterSettings(
        address: j['address'] as String?,
        name: j['name'] as String?,
        paper: j['paper'] as String? ?? '80',
        autoPrint: j['autoPrint'] == true,
        copies: j['copies'] as int? ?? 1,
      );
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
    if (at != null) await queueLocation(at);
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

  // -- Targets, shelf photos and surveys, location ---------------------------------

  /// The rep's target this month, or null for reps on monthly salary only.
  Future<MyTarget?> myTarget() async {
    final raw = await db.getValue('my_target');
    final json = raw == null ? null : jsonDecode(raw);
    return json is Map ? MyTarget(json.cast<String, dynamic>()) : null;
  }

  Future<Map<String, dynamic>> _surveyData() async {
    final raw = await db.getValue('surveys');
    final json = raw == null ? null : jsonDecode(raw);
    return json is Map ? json.cast<String, dynamic>() : const {};
  }

  /// Surveys due at a shop on today's plan.
  Future<List<Survey>> surveysFor(String customerKey) async {
    final data = await _surveyData();
    final ids = ((data['due'] as Map?)?[customerKey.replaceFirst('srv:', '')] as List?)?.cast<int>() ?? const [];
    return [
      for (final s in ((data['surveys'] as List?) ?? const []).cast<Map<String, dynamic>>())
        if (ids.contains(s['id'])) Survey(s),
    ];
  }

  /// What a shelf photo can be of.
  Future<List<String>> photoTags() async =>
      ((await _surveyData())['photo_tags'] as List?)?.cast<String>() ??
      const ['Main shelf', 'Display stand', 'Competitor', 'Out of stock', 'Price label'];

  /// Keeps a shelf photo on the phone until it syncs with its visit.
  Future<LocalRecord> addPhoto({
    required String visitUuid,
    required Uint8List bytes,
    required String tag,
    required Directory dir,
    GeoPoint? at,
  }) async {
    final uuid = _uuid.v4();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$uuid.jpg');
    await file.writeAsBytes(bytes, flush: true);
    final record = LocalRecord(
      uuid: uuid,
      kind: RecordKind.photo,
      createdAt: now,
      data: {
        'visitUuid': visitUuid,
        'path': file.path,
        'tag': tag,
        'takenAt': now.toUtc().toIso8601String(),
        'lat': at?.latitude,
        'lng': at?.longitude,
      },
    );
    await db.saveRecord(record);
    return record;
  }

  Future<List<LocalRecord>> photosFor(String visitUuid) async =>
      (await db.records(kind: RecordKind.photo)).where((r) => r.data['visitUuid'] == visitUuid).toList();

  Future<void> deletePhoto(String uuid) async {
    final record = await db.record(uuid);
    if (record == null || record.state == SyncState.synced) return;
    final file = File(record.data['path'] as String);
    if (await file.exists()) await file.delete();
    await db.deleteRecord(uuid);
  }

  /// Saves a visit's answers to a survey, replacing earlier answers not yet sent.
  Future<LocalRecord> saveSurveyAnswers({
    required String visitUuid,
    required Survey survey,
    required Map<int, Object?> answers,
  }) async {
    final missing = [for (final q in survey.questions) if (q.required && (answers[q.id] == null || answers[q.id] == '')) q.name];
    if (missing.isNotEmpty) throw ArgumentError('Answer: ${missing.join(', ')}');
    final existing = (await db.records(kind: RecordKind.surveyAnswer))
        .where((r) => r.data['visitUuid'] == visitUuid && r.data['surveyId'] == survey.id && r.state != SyncState.synced)
        .firstOrNull;
    final record = LocalRecord(
      uuid: existing?.uuid ?? _uuid.v4(),
      kind: RecordKind.surveyAnswer,
      createdAt: existing?.createdAt ?? now,
      data: {
        'visitUuid': visitUuid,
        'surveyId': survey.id,
        'surveyName': survey.name,
        'answers': {for (final e in answers.entries) '${e.key}': e.value},
      },
    );
    await db.saveRecord(record);
    return record;
  }

  Future<Map<int, Object?>> answersFor(String visitUuid, int surveyId) async {
    final record = (await db.records(kind: RecordKind.surveyAnswer))
        .where((r) => r.data['visitUuid'] == visitUuid && r.data['surveyId'] == surveyId)
        .lastOrNull;
    final raw = (record?.data['answers'] as Map?) ?? const {};
    return {for (final e in raw.entries) int.parse(e.key as String): e.value};
  }

  /// The rep is working: they checked in somewhere today and haven't closed the day.
  Future<bool> workingNow() async {
    if (await todayClose() != null) return false;
    final visits = await db.records(kind: RecordKind.visit, since: startOfToday.toUtc());
    return visits.isNotEmpty;
  }

  /// Keeps a position for the supervisor's Live Map until the next sync.
  Future<void> queueLocation(GeoPoint at, {double? accuracy}) async {
    if ((await appContext())?.trackLocation != true) return;
    final queue = await locationQueue();
    queue.add({
      'mobile_uuid': _uuid.v4(),
      'at': now.toUtc().toIso8601String().replaceFirst('T', ' ').split('.').first,
      'latitude': at.latitude,
      'longitude': at.longitude,
      'accuracy': accuracy ?? 0,
    });
    // A day without signal is about 150 points; keep at most two days.
    await db.setValue('location_queue', jsonEncode(queue.length > 300 ? queue.sublist(queue.length - 300) : queue));
  }

  Future<List<Map<String, dynamic>>> locationQueue() async {
    final raw = await db.getValue('location_queue');
    return raw == null ? [] : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  }

  Future<void> dropSentLocations(Set<String> uuids) async {
    final left = (await locationQueue()).where((p) => !uuids.contains(p['mobile_uuid'])).toList();
    await db.setValue('location_queue', jsonEncode(left));
  }

  // -- Expenses ------------------------------------------------------------------

  /// Records an expense the rep paid: from the cash collected today, their own
  /// money, or the company card. The receipt photo is optional.
  Future<LocalRecord> addExpense({
    required int categoryId,
    required String categoryName,
    required double amount,
    required String paidFrom,
    String? note,
    Uint8List? receipt,
    Directory? dir,
  }) async {
    if (amount <= 0) throw ArgumentError('Enter the amount.');
    final uuid = _uuid.v4();
    String? path;
    if (receipt != null && dir != null) {
      await dir.create(recursive: true);
      path = '${dir.path}/$uuid.jpg';
      await File(path).writeAsBytes(receipt, flush: true);
    }
    final record = LocalRecord(
      uuid: uuid,
      kind: RecordKind.expense,
      createdAt: now,
      data: {
        'categoryId': categoryId,
        'category': categoryName,
        'amount': amount,
        'paidFrom': paidFrom,
        'note': note,
        'receiptPath': path,
        'date': todayIso,
        'state': 'waiting',
      },
    );
    await db.saveRecord(record);
    return record;
  }

  /// The rep's expenses: from Odoo with their approval, and the ones on the phone.
  Future<List<Map<String, dynamic>>> myExpenses() async {
    final raw = await db.getValue('my_expenses');
    final server = raw == null ? <Map<String, dynamic>>[] : (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    final known = {for (final e in server) e['mobile_uuid']};
    final local = [
      for (final r in (await db.records(kind: RecordKind.expense)).reversed)
        if (!known.contains(r.uuid))
          {
            'mobile_uuid': r.uuid,
            'date': r.data['date'],
            'category': r.data['category'],
            'amount': r.data['amount'],
            'paid_from': r.data['paidFrom'],
            'note': r.data['note'],
            'state': 'waiting',
            'on_phone': r.state != SyncState.synced,
          },
    ];
    return [...local, ...server];
  }

  /// Today's expenses, from Odoo or the phone, not rejected.
  Future<List<Map<String, dynamic>>> todayExpenses() async =>
      (await myExpenses()).where((e) => e['date'] == todayIso && e['state'] != 'rejected').toList();

  /// Cash collected today the rep spent on expenses: taken off what they hand in.
  Future<double> cashSpentToday() async => (await todayExpenses())
      .where((e) => e['paid_from'] == 'cash')
      .fold<double>(0, (s, e) => s + (e['amount'] as num).toDouble());

  // -- Orders ---------------------------------------------------------------

  /// The customer's prices, with quantity prices (slabs) from their price list.
  Future<Pricing> pricingFor(String customerKey) async {
    final customer = await db.customer(customerKey);
    final prices = await db.pricesFor(customer?.pricelistId);
    final raw = await db.getValue('price_breaks');
    final all = raw == null ? const <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    final mine = (all['${customer?.pricelistId}'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Pricing(prices: prices, breaks: {
      for (final e in mine.entries)
        int.parse(e.key): [
          for (final b in (e.value as List).cast<List>()) ((b[0] as num).toDouble(), (b[1] as num).toDouble()),
        ],
    });
  }

  /// Schemes running today, from the last sync.
  Future<List<Scheme>> schemes() async {
    final raw = await db.getValue('schemes');
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).cast<Map<String, dynamic>>().map(Scheme.fromOdoo).toList();
  }

  /// What the shop owes now, with orders and payments not yet in Odoo, against
  /// its credit limit; null when there is nothing to warn about.
  Future<CreditWarning?> creditFor(String customerKey, {double adding = 0}) async {
    final customer = await db.customer(customerKey);
    final info = customer?.credit;
    if (info == null) return null;
    var owed = info.owed + adding;
    for (final r in [...await db.records(state: SyncState.pending), ...await db.records(state: SyncState.failed)]) {
      if (r.data['customerKey'] != customerKey) continue;
      if (r.kind == RecordKind.order) owed += (r.data['total'] as num?)?.toDouble() ?? 0;
      if (r.kind == RecordKind.payment) owed -= (r.data['amount'] as num?)?.toDouble() ?? 0;
    }
    final over = info.limit > 0 && owed > info.limit + 0.005;
    if (!over && info.overdueDays <= 0) return null;
    return CreditWarning(info: info, owed: owed, overLimit: over);
  }

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
        if (delivery == DeliveryMode.van && !vanHasAll(lines, stock)) {
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
              'uomId': l.unit.id,
              'unit': l.unit.short,
              'pieces': l.baseQty,
              'unitPrice': l.unitPrice,
              'listPrice': l.listPrice,
              'discount': l.discount,
              'schemeDiscount': l.schemeDiscount,
              'free': l.free,
              'schemeId': l.schemeId,
              'schemeName': l.schemeName,
              'taxPercent': l.product.taxPercent,
            },
        ],
        'deliveryMode': delivery?.code,
        'vanLines': {for (final e in vanLines.entries) '${e.key}': e.value},
        'invoice': await _invoiceFor(customerKey, lines, vanLines),
        'untaxed': totals.untaxed,
        'tax': totals.tax,
        'total': totals.total,
        'saved': lines.fold<double>(0, (s, l) => s + l.saved),
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

  /// Pieces of each product the order needs, free goods included.
  static Map<int, double> piecesNeeded(Iterable<CartLine> lines) {
    final need = <int, double>{};
    for (final l in lines) {
      need[l.product.id] = (need[l.product.id] ?? 0) + l.baseQty;
    }
    return need;
  }

  /// The van has every product of the order, free goods included.
  static bool vanHasAll(Iterable<CartLine> lines, VanStockView stock) =>
      piecesNeeded(lines).entries.every((e) => stock.leftOf(e.key) + 1e-9 >= e.value);

  /// Which lines the van hands over now, for each delivery choice, in pieces.
  static Map<int, double> vanLinesFor(DeliveryMode mode, List<CartLine> lines, VanStockView stock) {
    if (mode == DeliveryMode.warehouse) return {};
    final left = {for (final i in stock.items) i.productId: i.left};
    final result = <int, double>{};
    for (final l in lines) {
      final have = left[l.product.id] ?? 0;
      if (mode == DeliveryMode.van || have + 1e-9 >= l.baseQty) {
        result[l.product.id] = (result[l.product.id] ?? 0) + l.baseQty;
        left[l.product.id] = have - l.baseQty;
      }
    }
    return result;
  }

  // -- Invoices made at the shop ------------------------------------------------

  /// The tax invoice for what the van hands over, numbered in the van's own
  /// series so it can be printed without signal. Null when the van hands over
  /// nothing or invoicing at the shop is off.
  Future<Map<String, dynamic>?> _invoiceFor(String customerKey, List<CartLine> lines, Map<int, double> vanLines) async {
    final context = await appContext();
    final series = context?.vanInvoice;
    if (series == null || vanLines.isEmpty) return null;
    final customer = await db.customer(customerKey);
    final left = Map.of(vanLines);
    final items = <Map<String, dynamic>>[];
    var untaxed = 0.0;
    var tax = 0.0;
    var saved = 0.0;
    for (final l in lines) {
      final pieces = (left[l.product.id] ?? 0) < l.baseQty ? (left[l.product.id] ?? 0) : l.baseQty;
      if (pieces <= 1e-9) continue;
      left[l.product.id] = (left[l.product.id] ?? 0) - pieces;
      final qty = pieces / l.product.perUnit(l.unit);
      final amount = ShopInvoice.round2(qty * l.unitPrice * (1 - l.effectiveDiscount / 100));
      final vat = ShopInvoice.round2(amount * l.product.taxPercent / 100);
      untaxed += amount;
      tax += vat;
      final lineSaved = qty * l.listPrice - amount;
      if (lineSaved > 0.005) saved += lineSaved;
      final vatText = 'VAT ${formatPercent(l.product.taxPercent)}';
      items.add({
        'name': l.free ? '${l.product.name} · FREE' : l.product.name,
        'qty': qty,
        'unit': l.unit.short,
        'price': l.free ? 0.0 : l.unitPrice,
        'discount': l.effectiveDiscount,
        'vat': l.product.taxPercent,
        'amount': amount,
        'free': l.free,
        'note': l.free
            ? 'FREE · ${l.schemeName ?? ''}'
            : l.schemeDiscount > l.discount
                ? '${formatPercent(l.schemeDiscount)} off · $vatText'
                : l.unitPrice + 0.005 < l.listPrice
                    ? 'Qty price · $vatText'
                    : vatText,
      });
    }
    if (items.isEmpty) return null;
    final previous = (await db.invoices(customerKey: customerKey)).fold<double>(0, (s, i) => s + i.amountDue);
    final name = await _nextInvoiceName(series);
    final van = context?.van;
    return {
      'name': name,
      'date': todayIso,
      'time': '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      'simplified': (customer?.vat ?? '').isEmpty,
      'currency': context?.currencyCode ?? 'AED',
      'company': series.company,
      'customer': {'name': customer?.name ?? '', 'city': customer?.city, 'trn': customer?.vat},
      'van': [van?.vehicle, context?.userName].whereType<String>().join(' / '),
      'lines': items,
      'untaxed': ShopInvoice.round2(untaxed),
      'tax': ShopInvoice.round2(tax),
      'total': ShopInvoice.round2(untaxed + tax),
      'saved': ShopInvoice.round2(saved),
      'previous': ShopInvoice.round2(previous),
    };
  }

  /// The van series' next number: Odoo's next number, or further on if this
  /// phone has already used numbers Odoo hasn't seen yet.
  Future<String> _nextInvoiceName(VanInvoiceSeries series) async {
    final year = startOfToday.year;
    final key = 'inv_next:${series.journal}/$year';
    final stored = int.tryParse(await db.getValue(key) ?? '') ?? 1;
    final serverNext = series.year == year ? series.next : 1;
    final number = stored > serverNext ? stored : serverNext;
    await db.setValue(key, '${number + 1}');
    return series.nameFor(year, number);
  }

  /// Odoo's next number after a sync: never go back to a number already used here.
  Future<void> rememberInvoiceSeries(VanInvoiceSeries series) async {
    final key = 'inv_next:${series.journal}/${series.year}';
    final stored = int.tryParse(await db.getValue(key) ?? '') ?? 1;
    if (series.next > stored) await db.setValue(key, '${series.next}');
  }

  Future<ShopInvoice?> invoiceFor(String orderUuid) async {
    final order = await db.record(orderUuid);
    final raw = order?.data['invoice'];
    return raw is Map ? ShopInvoice(raw.cast<String, dynamic>()) : null;
  }

  // -- Printer settings ------------------------------------------------------------

  Future<PrinterSettings> printerSettings() async {
    final raw = await db.getValue('printer');
    final paper = (await appContext())?.vanInvoice?.paper ?? '80';
    return raw == null ? PrinterSettings(paper: paper) : PrinterSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> savePrinterSettings(PrinterSettings settings) => db.setValue('printer', jsonEncode(settings.toJson()));

  // -- Payments -------------------------------------------------------------

  /// What the shop can settle now: Odoo's unpaid invoices and credit notes, plus
  /// invoices printed and goods taken back on this phone that Odoo hasn't got yet.
  /// Phone items show what is left after payments already recorded here.
  Future<List<OpenInvoice>> openItemsFor(String customerKey) async {
    final items = [...await db.invoices(customerKey: customerKey)];
    final unsynced = [...await db.records(state: SyncState.pending), ...await db.records(state: SyncState.failed)]
        .where((r) => r.data['customerKey'] == customerKey)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final used = <String, double>{};
    for (final p in unsynced.where((r) => r.kind == RecordKind.payment)) {
      ((p.data['applied'] as Map?) ?? const {}).forEach((k, v) => used[k as String] = (used[k] ?? 0) + (v as num).toDouble());
    }
    final taxes = {for (final p in await db.products()) p.id: p.taxPercent};
    for (final r in unsynced) {
      if (r.kind == RecordKind.order && r.data['invoice'] is Map) {
        final invoice = ShopInvoice((r.data['invoice'] as Map).cast<String, dynamic>());
        final due = ShopInvoice.round2(invoice.total - (used['ord:${r.uuid}'] ?? 0));
        if (due > 0.005) {
          items.add(OpenInvoice(
              id: 0, customerKey: customerKey, name: invoice.name, amountDue: due, dueDate: invoice.date, orderUuid: r.uuid));
        }
      } else if (r.kind == RecordKind.shopReturn) {
        // Odoo's credit note adds the products' VAT to what the shop is given back.
        final total = ShopInvoice.round2((r.data['lines'] as List).cast<Map<String, dynamic>>().fold<double>(0, (s, l) {
          final amount = ShopInvoice.round2((l['qty'] as num).toDouble() * (l['priceUnit'] as num).toDouble());
          return s + amount + ShopInvoice.round2(amount * (taxes[l['productId']] ?? 0) / 100);
        }));
        final left = ShopInvoice.round2(total - (used['ret:${r.uuid}'] ?? 0));
        if (left > 0.005) {
          items.add(OpenInvoice(
            id: 0,
            customerKey: customerKey,
            name: 'Goods taken back ${r.data['date'] ?? ''}'.trim(),
            amountDue: -left,
            dueDate: r.data['date'] as String?,
            creditNote: true,
            returnUuid: r.uuid,
          ));
        }
      }
    }
    return items;
  }

  /// Records money collected from a shop.
  ///
  /// [settles] are the invoices it pays and the credit notes the shop uses against
  /// them. Credit notes are used first, then [amount]; with credit notes that cover
  /// the invoices, [amount] can be 0.
  Future<LocalRecord> collectPayment({
    required String customerKey,
    String? visitUuid,
    required double amount,
    required PaymentMethod method,
    List<OpenInvoice> settles = const [],
    String? chequeNumber,
    String? chequeDate,
    String? reference,
  }) async {
    final invoices = settles.where((i) => !i.creditNote).toList();
    final credits = settles.where((i) => i.creditNote).toList();
    if (amount < 0 || amount == 0 && (invoices.isEmpty || credits.isEmpty)) {
      throw ArgumentError('Enter the amount collected.');
    }
    if (amount > 0 && method.reference == 'cheque' && (chequeNumber == null || chequeNumber.trim().isEmpty)) {
      throw ArgumentError('Enter the cheque number.');
    }
    // How much of each invoice and credit note this settles: credit notes first, then the money.
    final applied = <String, double>{};
    var invoiceLeft = invoices.fold<double>(0, (s, i) => s + i.amountDue);
    for (final c in credits) {
      final use = ShopInvoice.round2((-c.amountDue) < invoiceLeft ? -c.amountDue : invoiceLeft);
      if (use <= 0) continue;
      applied[c.key] = use;
      invoiceLeft -= use;
    }
    var pay = credits.fold<double>(0, (s, c) => s + (applied[c.key] ?? 0)) + amount;
    for (final i in invoices) {
      final use = ShopInvoice.round2(pay < i.amountDue ? pay : i.amountDue);
      if (use <= 0) break;
      applied[i.key] = use;
      pay -= use;
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
        'methodName': amount > 0 ? method.name : 'Credit note',
        'kind': amount > 0 ? method.kind : 'credit',
        'invoiceIds': [for (final i in settles) if (!i.onPhone) i.id],
        'orderUuids': [for (final i in settles) if (i.orderUuid != null) i.orderUuid],
        'returnUuids': [for (final i in settles) if (i.returnUuid != null) i.returnUuid],
        'applied': applied,
        'chequeNumber': amount > 0 ? chequeNumber : null,
        'chequeDate': amount > 0 ? chequeDate : null,
        'reference': reference,
        'date': todayIso,
      },
    );
    await db.saveRecord(payment);
    // Show Odoo's invoices and credit notes as settled straight away.
    for (final i in settles.where((i) => !i.onPhone)) {
      if ((applied[i.key] ?? 0) > 0) await db.reduceInvoiceDue(i.id, applied[i.key]!);
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

/// Why the rep is warned before taking an order. Orders are never blocked.
class CreditWarning {
  CreditWarning({required this.info, required this.owed, required this.overLimit});

  final CreditInfo info;

  /// What the shop owes now, including work on the phone not yet in Odoo.
  final double owed;
  final bool overLimit;
}

String formatPercent(num p) => '${p == p.roundToDouble() ? p.toInt() : p}%';
