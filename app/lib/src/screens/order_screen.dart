import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/repository.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/scanner.dart';

/// Product catalogue with the customer's prices, and the cart.
class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.customerKey, this.visitUuid});

  final String customerKey;
  final String? visitUuid;

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  List<Product> _products = [];
  Map<int, double> _prices = {};
  final Map<int, CartLine> _cart = {};
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
    final db = ref.read(localDbProvider);
    final customer = await db.customer(widget.customerKey);
    final products = await db.products();
    final prices = await db.pricesFor(customer?.pricelistId);
    final stock = await ref.read(repositoryProvider).vanStock();
    if (mounted) {
      setState(() {
        _products = products;
        _prices = prices;
        _stock = stock;
        _loading = false;
      });
    }
  }

  double _priceOf(Product p) => _prices[p.id] ?? p.listPrice;

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
    return ScanFeedback('Added ${p.name} · ${formatQty(qty)} in the order');
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
          (_cart[p.id] ??= CartLine(product: p, unitPrice: _priceOf(p))).qty = qty;
        }
      });

  Future<void> _repeatLastOrder() async {
    final last = await ref.read(repositoryProvider).lastOrderFor(widget.customerKey);
    if (last == null) {
      if (mounted) showMessage(context, 'No earlier order for this customer on this phone.');
      return;
    }
    setState(() {
      for (final l in (last.data['lines'] as List).cast<Map<String, dynamic>>()) {
        final product = _products.where((p) => p.id == l['productId']).firstOrNull;
        if (product != null) {
          _cart[product.id] = CartLine(product: product, unitPrice: _priceOf(product), qty: (l['qty'] as num).toDouble());
        }
      }
    });
  }

  Future<void> _openCart() async {
    final confirmed = await showModalBottomSheet<_CartResult?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CartSheet(
        lines: _cart.values.toList(),
        stock: _stock?.hasVan == true ? _stock : null,
        onChanged: () => setState(() {}),
      ),
    );
    if (confirmed == null) return;
    setState(() => _saving = true);
    try {
      final order = await ref.read(repositoryProvider).placeOrder(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            lines: _cart.values.toList(),
            note: confirmed.note.isEmpty ? null : confirmed.note,
            delivery: confirmed.delivery,
          );
      ref.read(dataVersionProvider.notifier).bump();
      if (widget.visitUuid == null) unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) context.pushReplacement('/orders/${order.uuid}');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final customer = ref.watch(customerProvider(widget.customerKey)).value;
    final visible = _search.isEmpty
        ? _products
        : _products.where((p) => p.name.toLowerCase().contains(_search) || (p.code ?? '').toLowerCase().contains(_search) || (p.barcode ?? '').contains(_search)).toList();
    final totals = OrderTotals.of(_cart.values);
    final count = _cart.values.fold<double>(0, (s, l) => s + l.qty);

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('New order'),
          Text(customer?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          ScanButton(title: 'Scan products', onCode: _scanned),
          IconButton(tooltip: 'Repeat last order', onPressed: _repeatLastOrder, icon: const Icon(Icons.replay)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchField,
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search), hintText: 'Search or scan products', isDense: true),
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
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final p = visible[i];
                    final qty = _cart[p.id]?.qty ?? 0;
                    final inVan = _stock?.hasVan == true ? _stock!.leftOf(p.id) : null;
                    final have = inVan ?? p.qtyAvailable;
                    return ListTile(
                      title: Text(p.name),
                      subtitle: Row(children: [
                        Text(money(_priceOf(p)), style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        StatusChip(
                          have > 0
                              ? '${formatQty(have)} ${inVan != null ? 'in van' : 'in stock'}'
                              : (inVan != null ? '0 in van' : 'Out of stock'),
                          color: have > 0 ? BeatproColors.success : BeatproColors.danger,
                        ),
                      ]),
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
                    Text('${formatQty(count)} items'),
                    const Spacer(),
                    Text('Review  ${money(totals.total)}'),
                  ]),
                ),
              ),
            ),
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
      IconButton.outlined(onPressed: () => onChanged(qty - 1), icon: const Icon(Icons.remove), tooltip: 'Less'),
      SizedBox(
        width: 36,
        child: Text(formatQty(qty), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ),
      IconButton.filled(
        onPressed: () => onChanged(qty + 1),
        icon: const Icon(Icons.add),
        tooltip: 'More',
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
  const _CartSheet({required this.lines, required this.onChanged, this.stock});

  final List<CartLine> lines;
  final VoidCallback onChanged;

  /// The van's stock, for reps with a van: they choose how the order is delivered.
  final VanStockView? stock;

  @override
  ConsumerState<_CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends ConsumerState<_CartSheet> {
  final _note = TextEditingController();
  DeliveryMode? _delivery;

  bool get _vanHasAll => widget.lines.every((l) => (widget.stock?.leftOf(l.product.id) ?? 0) >= l.qty);
  bool get _vanHasSome => widget.lines.any((l) => (widget.stock?.leftOf(l.product.id) ?? 0) >= l.qty);

  DeliveryMode? get _mode {
    if (widget.stock == null) return null;
    final picked = _delivery ?? (_vanHasAll ? DeliveryMode.van : (_vanHasSome ? DeliveryMode.split : DeliveryMode.warehouse));
    return picked == DeliveryMode.van && !_vanHasAll ? DeliveryMode.split : picked;
  }

  String _optionText(DeliveryMode mode) {
    final stock = widget.stock!;
    final main = stock.van?.mainWarehouse ?? 'the main warehouse';
    final short = [for (final l in widget.lines) if (stock.leftOf(l.product.id) < l.qty) l.product.name];
    final now = [for (final l in widget.lines) if (stock.leftOf(l.product.id) >= l.qty) l.product.name];
    return switch (mode) {
      DeliveryMode.van => short.isEmpty
          ? 'Hand everything over now.'
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
    final nowCount = Repository.vanLinesFor(mode, widget.lines, widget.stock!).length;
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
      setState(() => line.discount = value.clamp(0, 100).toDouble());
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final limit = ref.watch(appContextProvider).value?.discountLimit ?? 0;
    final totals = OrderTotals.of(widget.lines);
    final needsApproval = widget.lines.any((l) => l.discount > limit);
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
            for (final l in widget.lines)
              ListTile(
                title: Text(l.product.name),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${formatQty(l.qty)} × ${money(l.unitPrice)}'
                      '${l.discount > 0 ? ' · ${formatQty(l.discount)}% off' : ''}'),
                  if (widget.stock != null)
                    Text(
                      widget.stock!.leftOf(l.product.id) >= l.qty
                          ? '${formatQty(l.qty)} of ${formatQty(widget.stock!.leftOf(l.product.id))} in van'
                          : '${formatQty(widget.stock!.leftOf(l.product.id))} in van · warehouse has ${formatQty(widget.stock!.mainOf(l.product.id))}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: widget.stock!.leftOf(l.product.id) >= l.qty ? BeatproColors.success : BeatproColors.danger,
                      ),
                    ),
                ]),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(money(l.subtotal), style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(tooltip: 'Discount', icon: const Icon(Icons.percent, size: 20), onPressed: () => _editDiscount(l)),
                ]),
              ),
            const Divider(),
            _TotalRow(label: 'Before tax', value: money(totals.untaxed)),
            _TotalRow(label: 'Tax (estimate)', value: money(totals.tax)),
            _TotalRow(label: 'Total', value: money(totals.total), bold: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text('Odoo confirms the final prices and taxes when the order syncs.', style: theme.textTheme.bodySmall),
            ),
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
              child: TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note for the order (optional)')),
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
