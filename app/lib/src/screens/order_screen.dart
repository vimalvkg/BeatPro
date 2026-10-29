import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

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
    if (mounted) {
      setState(() {
        _products = products;
        _prices = prices;
        _loading = false;
      });
    }
  }

  double _priceOf(Product p) => _prices[p.id] ?? p.listPrice;

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
    final confirmed = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CartSheet(lines: _cart.values.toList(), onChanged: () => setState(() {})),
    );
    if (confirmed == null) return;
    setState(() => _saving = true);
    try {
      final order = await ref.read(repositoryProvider).placeOrder(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            lines: _cart.values.toList(),
            note: confirmed.isEmpty ? null : confirmed,
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
        : _products.where((p) => p.name.toLowerCase().contains(_search) || (p.code ?? '').toLowerCase().contains(_search)).toList();
    final totals = OrderTotals.of(_cart.values);
    final count = _cart.values.fold<double>(0, (s, l) => s + l.qty);

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('New order'),
          Text(customer?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: [
          IconButton(tooltip: 'Repeat last order', onPressed: _repeatLastOrder, icon: const Icon(Icons.replay)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search products', isDense: true),
              onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
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
                    return ListTile(
                      title: Text(p.name),
                      subtitle: Row(children: [
                        Text(money(_priceOf(p)), style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        StatusChip(
                          p.qtyAvailable > 0 ? '${formatQty(p.qtyAvailable)} in stock' : 'Out of stock',
                          color: p.qtyAvailable > 0 ? BeatproColors.success : BeatproColors.danger,
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

class _CartSheet extends ConsumerStatefulWidget {
  const _CartSheet({required this.lines, required this.onChanged});

  final List<CartLine> lines;
  final VoidCallback onChanged;

  @override
  ConsumerState<_CartSheet> createState() => _CartSheetState();
}

class _CartSheetState extends ConsumerState<_CartSheet> {
  final _note = TextEditingController();

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
                subtitle: Text('${formatQty(l.qty)} × ${money(l.unitPrice)}'
                    '${l.discount > 0 ? ' · ${formatQty(l.discount)}% off' : ''}'),
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
                onPressed: () => Navigator.pop(context, _note.text.trim()),
                child: Text('Place order · ${money(totals.total)}'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
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
