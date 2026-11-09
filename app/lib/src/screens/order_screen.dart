import 'dart:async';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/repository.dart';
import '../core/schemes.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/scanner.dart';

/// Product catalogue with the customer's prices, and the cart.
///
/// Lines sell in cases or pieces. Quantity prices (slabs) and running schemes
/// apply as the rep adds products, offline; Odoo applies the same schemes when
/// the order arrives.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.customerKey, this.visitUuid});

  final String customerKey;
  final String? visitUuid;

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  List<Product> _products = [];
  Map<int, Product> _byId = {};
  Pricing _pricing = Pricing(prices: const {});
  List<Scheme> _schemes = const [];
  CreditWarning? _credit;
  final Map<int, CartLine> _cart = {};

  /// Free goods the cart earns, worked out again after every change.
  List<CartLine> _free = [];

  /// The unit chosen for each product, also before it is in the cart.
  final Map<int, ProductUnit> _units = {};
  String _search = '';
  VanStockView? _stock;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final products = await repo.db.products();
    final pricing = await repo.pricingFor(widget.customerKey);
    final schemes = await repo.schemes();
    final stock = await repo.vanStock();
    final credit = await repo.creditFor(widget.customerKey);
    if (mounted) {
      setState(() {
        _products = products;
        _byId = {for (final p in products) p.id: p};
        _pricing = pricing;
        _schemes = schemes;
        _stock = stock;
        _credit = credit;
        _loading = false;
      });
    }
  }

  List<CartLine> get _lines => [..._cart.values, ..._free];

  ProductUnit _unitOf(Product p) => _cart[p.id]?.unit ?? _units[p.id] ?? p.defaultUnit;

  /// Prices and schemes follow the quantities.
  void _recalculate() {
    for (final l in _cart.values) {
      _pricing.price(l);
    }
    _free = applySchemes(_cart.values.toList(), _schemes, _byId, _pricing);
  }

  final _searchField = TextEditingController();

  @override
  void dispose() {
    _searchField.dispose();
    super.dispose();
  }

  /// A scanned barcode (camera or handheld scanner): one more of that product.
  ScanFeedback _scanned(String code) {
    final p = productForCode(_products, code);
    if (p == null) return ScanFeedback('No product with barcode $code. Sync to update the products.', ok: false);
    final qty = (_cart[p.id]?.qty ?? 0) + 1;
    _setQty(p, qty);
    return ScanFeedback('Added ${p.name} · ${formatQty(qty)} ${_unitOf(p).short} in the order');
  }

  /// Handheld scanners type the barcode into the search box and press Enter.
  void _searchSubmitted(String value) {
    if (productForCode(_products, value) == null) return;
    final feedback = _scanned(value);
    _searchField.clear();
    setState(() => _search = '');
    showMessage(context, feedback.message);
  }

  void _setQty(Product p, double qty) => setState(() {
        if (qty <= 0) {
          _cart.remove(p.id);
        } else {
          (_cart[p.id] ??= CartLine(product: p, unitPrice: 0, unit: _unitOf(p))).qty = qty;
        }
        _recalculate();
      });

  void _setUnit(Product p, ProductUnit unit) => setState(() {
        _units[p.id] = unit;
        _cart[p.id]?.unit = unit;
        _recalculate();
      });

  Future<void> _repeatLastOrder() async {
    final last = await ref.read(repositoryProvider).lastOrderFor(widget.customerKey);
    if (last == null) {
      if (mounted) showMessage(context, 'No earlier order for this customer on this phone.');
      return;
    }
    setState(() {
      for (final l in (last.data['lines'] as List).cast<Map<String, dynamic>>().where((l) => l['free'] != true)) {
        final product = _byId[l['productId']];
        if (product != null) {
          _cart[product.id] = CartLine(
            product: product,
            unitPrice: 0,
            unit: l['uomId'] == null ? product.baseUnit : product.unitById(l['uomId'] as int),
            qty: (l['qty'] as num).toDouble(),
          );
        }
      }
      _recalculate();
    });
  }

  Future<void> _openCart() async {
    final confirmed = await showModalBottomSheet<_CartResult?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CartSheet(
        lines: () => _lines,
        stock: _stock?.hasVan == true ? _stock : null,
        credit: () async => ref.read(repositoryProvider).creditFor(widget.customerKey, adding: OrderTotals.of(_lines).total),
        onChanged: () => setState(_recalculate),
      ),
    );
    if (confirmed == null) return;
    setState(() => _saving = true);
    try {
      final order = await ref.read(repositoryProvider).placeOrder(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            lines: _lines,
            note: confirmed.note.isEmpty ? null : confirmed.note,
            delivery: confirmed.delivery,
          );
      ref.read(dataVersionProvider.notifier).bump();
      if (widget.visitUuid == null) unawaited(ref.read(syncControllerProvider.notifier).run());
      if (!mounted) return;
      // A van delivery comes with its tax invoice: show it, to print or share.
      context.pushReplacement(order.data['invoice'] is Map ? '/invoice/${order.uuid}?placed=1' : '/orders/${order.uuid}');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Where the cart stands on a scheme: `3 cs more: 1 free`, or `1 cs free earned`.
  String? _nudge(Product p, Scheme s) {
    final bought = _cart.values
        .where((l) => s.productIds.contains(l.product.id))
        .fold<double>(0, (sum, l) => sum + l.qty * l.unit.factor);
    if (bought <= 0 || s.minQty <= 0) return null;
    final times = (bought / s.minQty + 1e-9).floor();
    if (times > 0) {
      final free = _free.where((l) => l.schemeId == s.id).firstOrNull;
      return s.isFreeGoods
          ? '${formatQty(s.freeQty * times)} ${free?.unit.short ?? ''} free earned'.replaceAll('  ', ' ')
          : '${formatQty(s.discount)}% off earned';
    }
    final unit = _unitOf(p);
    final more = ((s.minQty - bought) / unit.factor - 1e-9).ceil();
    return s.isFreeGoods
        ? '$more ${unit.short} more: ${formatQty(s.freeQty)} free'
        : '$more ${unit.short} more: ${formatQty(s.discount)}% off';
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final customer = ref.watch(customerProvider(widget.customerKey)).value;
    final visible = _search.isEmpty
        ? _products
        : _products.where((p) => p.name.toLowerCase().contains(_search) || (p.code ?? '').toLowerCase().contains(_search) || (p.barcode ?? '').contains(_search)).toList();
    final totals = OrderTotals.of(_lines);
    final cases = _cart.values.where((l) => l.unit.short == 'cs').fold<double>(0, (s, l) => s + l.qty);
    final pieces = _cart.values.where((l) => l.unit.short != 'cs').fold<double>(0, (s, l) => s + l.qty);
    final count = [if (cases > 0) '${formatQty(cases)} cs', if (pieces > 0 || cases == 0) '${formatQty(pieces)} ${pieces == 1 ? 'item' : 'items'}'].join(' + ');
    final running = _schemes.where((s) => s.productIds.any(_byId.containsKey)).length;

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('New order'),
          Text(customer?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          ScanButton(title: 'Scan products', onCode: _scanned),
          IconButton(tooltip: tr('Repeat last order'), onPressed: _repeatLastOrder, icon: const Icon(Icons.replay)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchField,
              decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search), hintText: tr('Search or scan products'), isDense: true),
              onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
              onSubmitted: _searchSubmitted,
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : visible.isEmpty
              ? const EmptyState(icon: Icons.inventory_2_outlined, title: 'No products', message: 'Sync to download the product list.')
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: visible.length + 1,
                  separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Column(children: [
                        if (_credit != null) CreditWarningCard(warning: _credit!, compact: true),
                        if (running > 0)
                          _Banner(
                            icon: Icons.card_giftcard,
                            color: BeatproColors.amberInk,
                            background: BeatproColors.amberSoft,
                            text: '$running ${running == 1 ? 'scheme' : 'schemes'} running · they apply by themselves',
                          ),
                      ]);
                    }
                    final p = visible[index - 1];
                    final line = _cart[p.id];
                    final qty = line?.qty ?? 0;
                    final unit = _unitOf(p);
                    final inVan = _stock?.hasVan == true ? _stock!.leftOf(p.id) : null;
                    final have = inVan ?? p.qtyAvailable;
                    final price = line?.unitPrice ?? _pricing.unitPrice(p, unit, p.perUnit(unit));
                    final next = _pricing.nextBreak(p, line?.baseQty ?? 0);
                    final schemes = _schemes.where((s) => s.productIds.contains(p.id)).toList();
                    return ListTile(
                      title: Text(p.name),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          if (p.caseUnit != null) _UnitSwitch(product: p, unit: unit, onChanged: (u) => _setUnit(p, u)),
                          Text('${money(price)} / ${unit.short}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (line != null && line.unitPrice + 0.005 < line.listPrice)
                            const StatusChip('Qty price', color: BeatproColors.success),
                          StatusChip(
                            have > 0
                                ? '${p.packText(have)} ${inVan != null ? 'in van' : 'in stock'}'
                                : (inVan != null ? '0 in van' : 'Out of stock'),
                            color: have > 0 ? BeatproColors.success : BeatproColors.danger,
                          ),
                          for (final s in schemes)
                            StatusChip(_nudge(p, s) ?? s.badge, color: BeatproColors.amberInk, icon: Icons.card_giftcard),
                          if (next != null)
                            Text('${money(_pricing.unitPrice(p, unit, next.$1))} / ${unit.short} from ${p.packText(next.$1)}',
                                style: const TextStyle(fontSize: 12, color: BeatproColors.muted)),
                        ]),
                      ),
                      trailing: _QtyStepper(qty: qty, onChanged: (q) => _setQty(p, q)),
                    );
                  },
                ),
      bottomNavigationBar: _cart.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: _saving ? null : _openCart,
                  child: Row(children: [
                    Flexible(
                      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(count)),
                    ),
                    const SizedBox(width: 12),
                    Text('Review  ${money(totals.total)}'),
                  ]),
                ),
              ),
            ),
    );
  }
}

/// Case or pieces, for products sold in cases.
class _UnitSwitch extends StatelessWidget {
  const _UnitSwitch({required this.product, required this.unit, required this.onChanged});

  final Product product;
  final ProductUnit unit;
  final ValueChanged<ProductUnit> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = [(product.caseUnit!, 'Case'), (product.baseUnit, 'Pcs')];
    return Container(
      decoration: BoxDecoration(border: Border.all(color: BeatproColors.line), borderRadius: BorderRadius.circular(8)),
      clipBehavior: Clip.antiAlias,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (u, label) in options)
          Semantics(
            button: true,
            selected: u.factor == unit.factor,
            child: InkWell(
              onTap: () => onChanged(u),
              child: Container(
                constraints: const BoxConstraints(minHeight: 32),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                color: u.factor == unit.factor ? BeatproColors.brand : Colors.white,
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: u.factor == unit.factor ? Colors.white : BeatproColors.muted)),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.background, required this.text});

  final IconData icon;
  final Color color;
  final Color background;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13))),
        ]),
      );
}

/// A shop over its credit limit or with an overdue invoice. Only a warning:
/// the rep can still take the order.
class CreditWarningCard extends ConsumerWidget {
  const CreditWarningCard({super.key, required this.warning, this.compact = false});

  final CreditWarning warning;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final info = warning.info;
    final lines = [
      if (warning.overLimit) 'Owes ${money(warning.owed)}, over its ${money(info.limit)} credit limit.',
      if (info.overdueDays > 0)
        '${info.overdueName ?? 'An invoice'} is ${info.overdueDays} days overdue · ${money(info.overdueAmount)} overdue in all.',
    ];
    return Container(
      margin: EdgeInsets.fromLTRB(16, 12, 16, compact ? 4 : 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BeatproColors.amberSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BeatproColors.amber),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.warning_amber_rounded, color: BeatproColors.amberInk),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(warning.overLimit ? 'Over the credit limit' : 'Overdue invoice',
                style: const TextStyle(fontWeight: FontWeight.w800, color: BeatproColors.amberInk)),
            for (final l in lines) Text(l, style: const TextStyle(fontSize: 13, color: BeatproColors.amberInk)),
            if (!compact)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('You can still take the order. Try to collect a payment first.',
                    style: TextStyle(fontSize: 12, color: BeatproColors.amberInk)),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _QtyStepper extends StatelessWidget {
  const _QtyStepper({required this.qty, required this.onChanged});

  final double qty;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    if (qty == 0) {
      return OutlinedButton(onPressed: () => onChanged(1), child: const Text('Add'));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton.outlined(onPressed: () => onChanged(qty - 1), icon: const Icon(Icons.remove), tooltip: tr('Less')),
      SizedBox(
        width: 36,
        child: Text(formatQty(qty), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ),
      IconButton.filled(
        onPressed: () => onChanged(qty + 1),
        icon: const Icon(Icons.add),
        tooltip: tr('More'),
        // ListTile tints trailing icons; keep the plus readable on the filled button.
        color: Theme.of(context).colorScheme.onPrimary,
      ),
    ]);
  }
}

class _CartResult {
  const _CartResult(this.note, this.delivery);

  final String note;
  final DeliveryMode? delivery;
}

class _CartSheet extends ConsumerStatefulWidget {
  const _CartSheet({required this.lines, required this.onChanged, required this.credit, this.stock});

  /// The order's lines, free goods included; they change as discounts change.
  final List<CartLine> Function() lines;
  final VoidCallback onChanged;

  /// The shop's credit position with this order added.
  final Future<CreditWarning?> Function() credit;

  /// The van's stock, for reps with a van: they choose how the order is delivered.
  final VanStockView? stock;

  @override
  ConsumerState<_CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends ConsumerState<_CartSheet> {
  final _note = TextEditingController();
  DeliveryMode? _delivery;
  CreditWarning? _credit;

  @override
  void initState() {
    super.initState();
    _loadCredit();
  }

  Future<void> _loadCredit() async {
    final credit = await widget.credit();
    if (mounted) setState(() => _credit = credit);
  }

  List<CartLine> get _lines => widget.lines();
  bool get _vanHasAll => Repository.vanHasAll(_lines, widget.stock!);
  bool _inVan(CartLine l) => (widget.stock?.leftOf(l.product.id) ?? 0) + 1e-9 >= l.baseQty;
  bool get _vanHasSome => _lines.any(_inVan);

  DeliveryMode? get _mode {
    if (widget.stock == null) return null;
    final picked = _delivery ?? (_vanHasAll ? DeliveryMode.van : (_vanHasSome ? DeliveryMode.split : DeliveryMode.warehouse));
    return picked == DeliveryMode.van && !_vanHasAll ? DeliveryMode.split : picked;
  }

  String _optionText(DeliveryMode mode) {
    final stock = widget.stock!;
    final main = stock.van?.mainWarehouse ?? 'the main warehouse';
    final need = Repository.piecesNeeded(_lines);
    final names = {for (final l in _lines) l.product.id: l.product.name};
    final short = [for (final e in need.entries) if (stock.leftOf(e.key) + 1e-9 < e.value) names[e.key]!];
    final now = [for (final e in need.entries) if (stock.leftOf(e.key) + 1e-9 >= e.value) names[e.key]!];
    return switch (mode) {
      DeliveryMode.van => short.isEmpty
          ? 'Hand everything over now, free goods included.'
          : 'Not possible: ${short.join(', ')} ${short.length == 1 ? 'is' : 'are'} short in the van.',
      DeliveryMode.split => now.isEmpty
          ? 'Nothing in this order is in the van.'
          : short.isEmpty
              ? 'Everything is in the van.'
              : '${now.join(', ')} handed over now. ${short.join(', ')} delivered by $main.',
      DeliveryMode.warehouse => 'Delivered by $main. The order is still yours: it counts in your sales.',
    };
  }

  String _ctaFor(DeliveryMode? mode, String total) {
    if (mode == null) return 'Place order · $total';
    final nowCount = Repository.vanLinesFor(mode, _lines, widget.stock!).length;
    return switch (mode) {
      DeliveryMode.van => 'Deliver now · $total',
      DeliveryMode.split => 'Place order · deliver $nowCount item${nowCount == 1 ? '' : 's'} now',
      DeliveryMode.warehouse => 'Place order for warehouse delivery',
    };
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _editDiscount(CartLine line) async {
    final controller = TextEditingController(text: line.discount == 0 ? '' : formatQty(line.discount));
    final value = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discount on ${line.product.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(suffixText: '%'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, double.tryParse(controller.text.trim()) ?? 0),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (value != null) {
      line.discount = value.clamp(0, 100).toDouble();
      widget.onChanged();
      setState(() {});
      unawaited(_loadCredit());
    }
  }

  String _lineText(CartLine l, Money money) {
    final qty = '${formatQty(l.qty)} ${l.unit.short}';
    if (l.free) return '$qty · ${l.schemeName ?? 'Scheme'}';
    final parts = ['$qty × ${money(l.unitPrice)}'];
    if (l.unitPrice + 0.005 < l.listPrice) parts.add('qty price (was ${money(l.listPrice)})');
    if (l.schemeDiscount > l.discount) {
      parts.add('${formatQty(l.schemeDiscount)}% off · ${l.schemeName}');
    } else if (l.discount > 0) {
      parts.add('${formatQty(l.discount)}% off');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final limit = ref.watch(appContextProvider).value?.discountLimit ?? 0;
    final lines = _lines;
    final totals = OrderTotals.of(lines);
    final saved = lines.fold<double>(0, (s, l) => s + l.saved);
    final freeNames = [for (final l in lines.where((l) => l.free)) '${formatQty(l.qty)} ${l.unit.short} ${l.product.name} free'];
    final needsApproval = lines.any((l) => !l.free && l.discount > limit);
    final need = Repository.piecesNeeded(lines);
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(children: [
        Expanded(
          child: ListView(controller: scroll, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Order summary', style: theme.textTheme.titleLarge),
            ),
            for (final l in lines)
              Container(
                color: l.free ? BeatproColors.successSoft : null,
                child: ListTile(
                  title: Text(l.free ? '${l.product.name} · FREE' : l.product.name),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_lineText(l, money),
                        style: l.free || l.schemeDiscount > l.discount || l.unitPrice + 0.005 < l.listPrice
                            ? const TextStyle(color: BeatproColors.success, fontWeight: FontWeight.w600)
                            : null),
                    if (widget.stock != null && !l.free)
                      Builder(builder: (context) {
                        final left = widget.stock!.leftOf(l.product.id);
                        final enough = left + 1e-9 >= (need[l.product.id] ?? l.baseQty);
                        return Text(
                          enough
                              ? '${l.product.packText(need[l.product.id] ?? l.baseQty)} of ${l.product.packText(left)} in van'
                              : '${l.product.packText(left)} in van · warehouse has ${l.product.packText(widget.stock!.mainOf(l.product.id))}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: enough ? BeatproColors.success : BeatproColors.danger,
                          ),
                        );
                      }),
                  ]),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(money(l.subtotal),
                        style: TextStyle(fontWeight: FontWeight.w600, color: l.free ? BeatproColors.success : null)),
                    if (!l.free)
                      IconButton(tooltip: tr('Discount'), icon: const Icon(Icons.percent, size: 20), onPressed: () => _editDiscount(l))
                    else
                      const SizedBox(width: 48),
                  ]),
                ),
              ),
            const Divider(),
            _TotalRow(label: 'Before tax', value: money(totals.untaxed)),
            _TotalRow(label: 'Tax (estimate)', value: money(totals.tax)),
            _TotalRow(label: 'Total', value: money(totals.total), bold: true),
            if (saved >= 0.01)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: BeatproColors.successSoft, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('The shop saves ${money(saved)}',
                          style: const TextStyle(fontWeight: FontWeight.w800, color: BeatproColors.success)),
                      if (freeNames.isNotEmpty)
                        Text(freeNames.join(' · '), style: const TextStyle(fontSize: 12, color: BeatproColors.success)),
                    ]),
                  ),
                  const Icon(Icons.card_giftcard, color: BeatproColors.success),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Odoo confirms the final prices, schemes and taxes when the order syncs.', style: theme.textTheme.bodySmall),
            ),
            if (_credit != null) CreditWarningCard(warning: _credit!),
            if (needsApproval)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Card(
                  color: BeatproColors.amber.withValues(alpha: 0.18),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('A discount is above your limit of ${formatQty(limit)}%. '
                        'The order will wait for your supervisor to approve it.'),
                  ),
                ),
              ),
            if (widget.stock != null) ...[
              const Eyebrow('How will it be delivered?'),
              for (final mode in DeliveryMode.values)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _DeliveryOption(
                    title: mode.label,
                    text: _optionText(mode),
                    selected: _mode == mode,
                    enabled: mode != DeliveryMode.van || _vanHasAll,
                    onTap: () => setState(() => _delivery = mode),
                  ),
                ),
            ],
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(controller: _note, decoration: InputDecoration(labelText: tr('Note for the order (optional)'))),
            ),
          ]),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, _CartResult(_note.text.trim(), _mode)),
                child: Text(_ctaFor(_mode, money(totals.total))),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DeliveryOption extends StatelessWidget {
  const _DeliveryOption({
    required this.title,
    required this.text,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String title;
  final String text;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        inMutuallyExclusiveGroup: true,
        checked: selected,
        enabled: enabled,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? BeatproColors.brandSoft : (enabled ? Colors.white : BeatproColors.ground),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? BeatproColors.brand : BeatproColors.line, width: selected ? 2 : 1),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(color: selected ? BeatproColors.brand : const Color(0xFFB9A6A8), width: selected ? 6 : 2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: enabled ? null : BeatproColors.muted)),
                  const SizedBox(height: 2),
                  Text(text, style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.value, this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold ? Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(children: [Text(label, style: style), const Spacer(), Text(value, style: style)]),
    );
  }
}
