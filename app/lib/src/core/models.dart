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

  /// The Van Sales Dashboard is on this server and this user may open it (supervisors).
  bool get hasSalesDashboard => json['sales_dashboard'] == true;

  /// The van's invoice series, when reps invoice van deliveries at the shop.
  VanInvoiceSeries? get vanInvoice =>
      json['van_invoice'] is Map ? VanInvoiceSeries((json['van_invoice'] as Map).cast<String, dynamic>()) : null;

  /// The rep's van, or null for reps without one.
  VanInfo? get van => json['van'] is Map ? VanInfo((json['van'] as Map).cast<String, dynamic>()) : null;

  List<ReturnReason> get returnReasons {
    final raw = json['return_reasons'];
    if (raw is! List) return ReturnReason.defaults;
    return [
      for (final r in raw.cast<Map<String, dynamic>>())
        ReturnReason(r['value'] as String, r['label'] as String, r['resellable'] == true),
    ];
  }

  /// Payment methods set up in Odoo for reps. Servers from before this existed
  /// get the old fixed list.
  List<PaymentMethod> get paymentMethods {
    final raw = json['payment_methods'];
    if (raw is! List) return PaymentMethod.legacy;
    return raw.cast<Map<String, dynamic>>().map(PaymentMethod.fromJson).toList();
  }

  /// Online payment providers enabled in Odoo (Razorpay, Stripe…). Empty: no online payment.
  List<String> get onlineProviders => (json['online_providers'] as List?)?.cast<String>() ?? const [];
  String get currencySymbol => (json['currency'] as Map)['symbol'] as String? ?? '';
  String get currencyCode => (json['currency'] as Map)['name'] as String? ?? '';
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
    this.vat,
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

  /// The shop's tax number (UAE: TRN). Shops without one get a simplified tax invoice.
  final String? vat;

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
        vat: _str(r['vat']),
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
        'vat': vat,
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
        vat: j['vat'] as String?,
      );
}

class Product {
  Product({
    required this.id,
    required this.name,
    required this.listPrice,
    required this.qtyAvailable,
    this.code,
    this.barcode,
    this.uom,
    this.category,
    this.taxPercent = 0,
  });

  final int id;
  final String name;
  final double listPrice;
  final double qtyAvailable;
  final String? code;

  /// The product's barcode in Odoo, for scanning.
  final String? barcode;
  final String? uom;
  final String? category;
  final double taxPercent;

  static Product fromOdoo(Map<String, dynamic> r, double taxPercent) => Product(
        id: r['id'] as int,
        name: (r['display_name'] as String?) ?? '',
        listPrice: _num(r['lst_price']),
        qtyAvailable: _num(r['qty_available']),
        code: _str(r['default_code']),
        barcode: _str(r['barcode']),
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
        'barcode': barcode,
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
        barcode: j['barcode'] as String?,
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
enum RecordKind { customer, visit, order, payment, dayClose, shopReturn, vanTransfer }

/// The order in which records go to Odoo: a morning load before the day's
/// orders, goods taken back before the day-end unload, and the day close last.
int uploadRank(LocalRecord r) => switch (r.kind) {
      RecordKind.customer => 0,
      RecordKind.visit => 1,
      RecordKind.vanTransfer => r.data['kind'] == 'load' ? 2 : 7,
      RecordKind.order => 3,
      RecordKind.payment => 4,
      RecordKind.shopReturn => 5,
      RecordKind.dayClose => 8,
    };

/// How an order reaches the shop when the rep has a van.
enum DeliveryMode {
  van('van', 'Deliver now from the van'),
  split('split', 'Van now, the rest from the warehouse'),
  warehouse('warehouse', 'Main warehouse delivers everything');

  const DeliveryMode(this.code, this.label);

  final String code;
  final String label;
}

/// The van's own invoice series in Odoo (for example VAN1/2026/00001), so the
/// phone can number invoices without signal.
class VanInvoiceSeries {
  VanInvoiceSeries(this.json);

  final Map<String, dynamic> json;

  String get journal => json['journal'] as String;
  int get year => json['year'] as int;
  int get next => json['next'] as int;
  int get padding => json['padding'] as int? ?? 5;

  /// '80' or '58': the thermal paper width set in Odoo.
  String get paper => json['paper'] as String? ?? '80';
  Map<String, dynamic> get company => (json['company'] as Map?)?.cast<String, dynamic>() ?? const {};

  String nameFor(int year, int number) => '$journal/$year/${number.toString().padLeft(padding, '0')}';
}

/// The rep's van, from Odoo.
class VanInfo {
  VanInfo(this.json);

  final Map<String, dynamic> json;

  int get id => json['id'] as int;
  String get name => json['name'] as String? ?? '';
  String? get vehicle => json['vehicle'] is String ? json['vehicle'] as String : null;
  String get mainWarehouse => json['main_warehouse'] as String? ?? 'Main warehouse';
  bool get selfLoad => json['self_load'] == true;
}

/// Why a shop gives goods back, and whether they can be sold again.
class ReturnReason {
  const ReturnReason(this.value, this.label, this.resellable);

  final String value;
  final String label;
  final bool resellable;

  static const defaults = [
    ReturnReason('damaged', 'Damaged', false),
    ReturnReason('expired', 'Expired', false),
    ReturnReason('not_selling', 'Not selling', true),
    ReturnReason('wrong_item', 'Wrong item', true),
    ReturnReason('other', 'Other', true),
  ];
}

/// One product's stock for the van screen.
class VanItem {
  VanItem({
    required this.productId,
    required this.name,
    this.loaded = 0,
    this.sold = 0,
    this.returned = 0,
    this.left = 0,
    this.mainQty = 0,
    this.price = 0,
  });

  final int productId;
  final String name;
  double loaded;
  double sold;
  double returned;
  double left;
  double mainQty;
  double price;

  /// 'ok', 'low' or 'out', for the label next to the quantity.
  String get status => left <= 0 ? 'out' : (loaded > 0 && left <= 0.25 * loaded ? 'low' : 'ok');

  static VanItem fromOdoo(Map<String, dynamic> r) => VanItem(
        productId: r['product_id'] as int,
        name: r['name'] as String? ?? '',
        loaded: _num(r['loaded']),
        sold: _num(r['sold']),
        returned: _num(r['returned']),
        left: _num(r['left']),
        mainQty: _num(r['main_qty']),
        price: _num(r['price']),
      );
}

/// Finds the product a scanned code belongs to: its barcode first, then its
/// internal reference. Scanners and people add spaces, so they are ignored.
Product? productForCode(Iterable<Product> products, String code) {
  final c = code.trim();
  if (c.isEmpty) return null;
  return products.where((p) => p.barcode != null && p.barcode!.trim() == c).firstOrNull ??
      products.where((p) => p.code != null && p.code!.trim().toLowerCase() == c.toLowerCase()).firstOrNull;
}

/// What a shop bought lately, to take back.
class ReturnCandidate {
  ReturnCandidate({required this.productId, required this.name, required this.lastDate, required this.priceUnit});

  final int productId;
  final String name;
  final String? lastDate;
  final double priceUnit;

  static ReturnCandidate fromOdoo(Map<String, dynamic> r) => ReturnCandidate(
        productId: r['product_id'] as int,
        name: r['name'] as String? ?? '',
        lastDate: r['last_date'] is String ? r['last_date'] as String : null,
        priceUnit: _num(r['price_unit']),
      );
}

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

/// A way a rep can receive money, as set up in Odoo: a payment method of a cash
/// or bank journal.
class PaymentMethod {
  const PaymentMethod({
    this.id,
    required this.name,
    required this.kind,
    this.reference = 'none',
    this.handIn = false,
    this.legacyCode,
  });

  /// The Odoo payment method line; null for the old fixed list.
  final int? id;
  final String name;

  /// `cash`, `cheque` or `bank`: how the day-end close counts it.
  final String kind;

  /// What the rep enters: `none`, `reference` (optional transaction ID) or `cheque`.
  final String reference;

  /// Cash and cheques are handed in at the office; bank payments are already banked.
  final bool handIn;

  /// `cash`, `cheque` or `upi`, for servers from before payment methods came from Odoo.
  final String? legacyCode;

  static PaymentMethod fromJson(Map<String, dynamic> j) => PaymentMethod(
        id: j['id'] as int,
        name: j['name'] as String,
        kind: j['kind'] as String,
        reference: (j['reference'] as String?) ?? 'none',
        handIn: j['hand_in'] == true,
      );

  static const legacy = [
    PaymentMethod(name: 'Cash', kind: 'cash', handIn: true, legacyCode: 'cash'),
    PaymentMethod(name: 'Bank transfer', kind: 'bank', reference: 'reference', legacyCode: 'upi'),
    PaymentMethod(name: 'Cheque', kind: 'cheque', reference: 'cheque', handIn: true, legacyCode: 'cheque'),
  ];
}

/// How the day-end close groups collections.
const collectionKinds = <String, String>{'cash': 'Cash', 'cheque': 'Cheque', 'bank': 'Bank and card'};

/// The name of the method a payment record was taken with.
String paymentMethodName(Map<String, dynamic> data) =>
    (data['methodName'] as String?) ??
    const {'cash': 'Cash', 'cheque': 'Cheque', 'upi': 'Bank transfer'}[data['method']] ??
    'Payment';

/// `cash`, `cheque` or `bank` for a payment record, including ones made before
/// payment methods came from Odoo.
String paymentKind(Map<String, dynamic> data) =>
    (data['kind'] as String?) ?? (data['method'] == 'upi' ? 'bank' : (data['method'] as String? ?? 'bank'));

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
