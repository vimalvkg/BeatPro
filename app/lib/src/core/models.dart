/// Plain data classes for what the app shows and records.
library;

double _num(dynamic v) => v is num ? v.toDouble() : 0.0;

/// Odoo returns `false` for empty fields.
String? _str(dynamic v) => v is String && v.isNotEmpty ? v : null;

/// A many2one comes back as `[id, name]` or `false`.
int? _m2oId(dynamic v) => v is List && v.isNotEmpty ? v.first as int : (v is int ? v : null);

class AppContext {
  AppContext(this.json);

  final Map<String, dynamic> json;

  int get userId => json['user_id'] as int;
  String get userName => json['name'] as String;
  String get companyName => json['company_name'] as String;
  bool get isSupervisor => json['is_supervisor'] == true;
  double get discountLimit => _num(json['discount_limit']);
  int? get warehouseId => json['warehouse_id'] as int?;
  String get currencySymbol => (json['currency'] as Map)['symbol'] as String? ?? '';
  bool get currencyBefore => (json['currency'] as Map)['position'] != 'after';
  int get currencyDecimals => (json['currency'] as Map)['decimals'] as int? ?? 2;
}

/// A customer. [key] is `srv:<odoo id>` for customers from Odoo and
/// `loc:<uuid>` for customers added on the phone.
class Customer {
  Customer({
    required this.key,
    this.serverId,
    this.uuid,
    required this.name,
    this.phone,
    this.street,
    this.city,
    this.latitude,
    this.longitude,
    this.pricelistId,
  });

  final String key;
  final int? serverId;
  final String? uuid;
  final String name;
  final String? phone;
  final String? street;
  final String? city;
  final double? latitude;
  final double? longitude;
  final int? pricelistId;

  bool get isLocal => key.startsWith('loc:');

  static Customer fromOdoo(Map<String, dynamic> r) => Customer(
        key: 'srv:${r['id']}',
        serverId: r['id'] as int,
        name: (r['name'] as String?) ?? '',
        phone: _str(r['phone']),
        street: _str(r['street']),
        city: _str(r['city']),
        latitude: _num(r['partner_latitude']) == 0 ? null : _num(r['partner_latitude']),
        longitude: _num(r['partner_longitude']) == 0 ? null : _num(r['partner_longitude']),
        pricelistId: _m2oId(r['property_product_pricelist']),
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'serverId': serverId,
        'uuid': uuid,
        'name': name,
        'phone': phone,
        'street': street,
        'city': city,
        'latitude': latitude,
        'longitude': longitude,
        'pricelistId': pricelistId,
      };

  static Customer fromJson(Map<String, dynamic> j) => Customer(
        key: j['key'] as String,
        serverId: j['serverId'] as int?,
        uuid: j['uuid'] as String?,
        name: j['name'] as String,
        phone: j['phone'] as String?,
        street: j['street'] as String?,
        city: j['city'] as String?,
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        pricelistId: j['pricelistId'] as int?,
      );
}

class Product {
  Product({
    required this.id,
    required this.name,
    required this.listPrice,
    required this.qtyAvailable,
    this.code,
    this.uom,
    this.category,
    this.taxPercent = 0,
  });

  final int id;
  final String name;
  final double listPrice;
  final double qtyAvailable;
  final String? code;
  final String? uom;
  final String? category;
  final double taxPercent;

  static Product fromOdoo(Map<String, dynamic> r, double taxPercent) => Product(
        id: r['id'] as int,
        name: (r['display_name'] as String?) ?? '',
        listPrice: _num(r['lst_price']),
        qtyAvailable: _num(r['qty_available']),
        code: _str(r['default_code']),
        uom: r['uom_id'] is List ? (r['uom_id'] as List)[1] as String : null,
        category: r['categ_id'] is List ? (r['categ_id'] as List)[1] as String : null,
        taxPercent: taxPercent,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'listPrice': listPrice,
        'qtyAvailable': qtyAvailable,
        'code': code,
        'uom': uom,
        'category': category,
        'taxPercent': taxPercent,
      };

  static Product fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as int,
        name: j['name'] as String,
        listPrice: _num(j['listPrice']),
        qtyAvailable: _num(j['qtyAvailable']),
        code: j['code'] as String?,
        uom: j['uom'] as String?,
        category: j['category'] as String?,
        taxPercent: _num(j['taxPercent']),
      );
}

/// One customer on today's plan.
class RouteStop {
  RouteStop({required this.routeName, required this.sequence, required this.customerKey, required this.routeId});

  final int routeId;
  final String routeName;
  final int sequence;
  final String customerKey;
}

class OpenInvoice {
  OpenInvoice({
    required this.id,
    required this.customerKey,
    required this.name,
    required this.amountDue,
    this.dueDate,
    this.overdue = false,
  });

  final int id;
  final String customerKey;
  final String name;
  final double amountDue;
  final String? dueDate;
  final bool overdue;

  static OpenInvoice fromOdoo(Map<String, dynamic> r) => OpenInvoice(
        id: r['id'] as int,
        customerKey: 'srv:${r['partner_id']}',
        name: r['name'] as String,
        amountDue: _num(r['amount_due']),
        dueDate: _str(r['due_date']),
        overdue: r['overdue'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'customerKey': customerKey,
        'name': name,
        'amountDue': amountDue,
        'dueDate': dueDate,
        'overdue': overdue,
      };

  static OpenInvoice fromJson(Map<String, dynamic> j) => OpenInvoice(
        id: j['id'] as int,
        customerKey: j['customerKey'] as String,
        name: j['name'] as String,
        amountDue: _num(j['amountDue']),
        dueDate: j['dueDate'] as String?,
        overdue: j['overdue'] == true,
      );
}

/// What kind of thing a [LocalRecord] is. Uploaded in this order, so that
/// orders can point to visits and customers already in Odoo.
enum RecordKind { customer, visit, order, payment, dayClose }

enum SyncState { pending, synced, failed }

/// Something made on the phone that must reach Odoo: a new customer, a visit,
/// an order, a payment or a day-end close.
class LocalRecord {
  LocalRecord({
    required this.uuid,
    required this.kind,
    required this.data,
    this.state = SyncState.pending,
    this.serverId,
    this.error,
    required this.createdAt,
  });

  final String uuid;
  final RecordKind kind;
  final Map<String, dynamic> data;
  final SyncState state;
  final int? serverId;
  final String? error;
  final DateTime createdAt;

  LocalRecord copyWith({Map<String, dynamic>? data, SyncState? state, int? serverId, String? error}) => LocalRecord(
        uuid: uuid,
        kind: kind,
        data: data ?? this.data,
        state: state ?? this.state,
        serverId: serverId ?? this.serverId,
        error: error,
        createdAt: createdAt,
      );
}

enum VisitResult { order, noOrder, closed }

extension VisitResultCodes on VisitResult {
  String get code => switch (this) {
        VisitResult.order => 'order',
        VisitResult.noOrder => 'no_order',
        VisitResult.closed => 'closed',
      };

  String get label => switch (this) {
        VisitResult.order => 'Order taken',
        VisitResult.noOrder => 'No order',
        VisitResult.closed => 'Shop closed',
      };
}

/// Reasons the module accepts for a visit without an order.
const noOrderReasons = <String, String>{
  'enough_stock': 'Has enough stock',
  'credit': 'Payment or credit problem',
  'owner_absent': 'Owner not available',
  'competitor': 'Bought from a competitor',
  'other': 'Other',
};

const paymentMethods = <String, String>{'cash': 'Cash', 'cheque': 'Cheque', 'upi': 'UPI'};

/// One line in the cart.
class CartLine {
  CartLine({required this.product, required this.unitPrice, this.qty = 1, this.discount = 0});

  final Product product;
  final double unitPrice;
  double qty;
  double discount;

  double get subtotal => qty * unitPrice * (1 - discount / 100);
  double get tax => subtotal * product.taxPercent / 100;
}

/// Totals for a list of order lines, as a preview: Odoo recalculates them.
class OrderTotals {
  OrderTotals(this.untaxed, this.tax);

  final double untaxed;
  final double tax;
  double get total => untaxed + tax;

  static OrderTotals of(Iterable<CartLine> lines) => OrderTotals(
        lines.fold(0.0, (sum, l) => sum + l.subtotal),
        lines.fold(0.0, (sum, l) => sum + l.tax),
      );
}
