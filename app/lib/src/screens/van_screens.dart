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

// -- Van stock ----------------------------------------------------------------

/// What is in the van now, and what the main warehouse has.
class VanStockScreen extends ConsumerStatefulWidget {
  const VanStockScreen({super.key});

  @override
  ConsumerState<VanStockScreen> createState() => _VanStockScreenState();
}

class _VanStockScreenState extends ConsumerState<VanStockScreen> {
  bool _main = false;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final stock = ref.watch(vanStockProvider);
    final lastSync = ref.watch(lastSyncProvider).value;
    final money = ref.watch(moneyProvider);
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Stock'),
          Text(lastSync == null ? 'Not synced yet' : 'Updated ${formatTime(lastSync)}',
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        actions: const [SyncButton()],
      ),
      body: AsyncBody<VanStockView>(
        value: stock,
        builder: (s) {
          final showMain = _main || !s.hasVan;
          final list = (showMain ? s.mainItems : s.items)
              .where((i) => _search.isEmpty || i.name.toLowerCase().contains(_search))
              .toList();
          return RefreshIndicator(
            onRefresh: () async => ref.read(syncControllerProvider.notifier).run(),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (s.hasVan)
                _Segmented(
                  options: [('My van', !showMain), (s.van!.mainWarehouse, showMain)],
                  onTap: (i) => setState(() => _main = i == 1),
                ),
              if (s.hasVan && !showMain) ...[
                const SizedBox(height: 14),
                _VanHero(stock: s, money: money),
                const SizedBox(height: 12),
                _VanActions(stock: s),
              ],
              if (!s.hasVan)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('You have no van. This is the main warehouse\'s stock.',
                      style: TextStyle(color: BeatproColors.muted)),
                ),
              const SizedBox(height: 14),
              TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search products', isDense: true),
                onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
              ),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Nothing here yet. Sync to update.', style: TextStyle(color: BeatproColors.muted)),
                      )
                    : Column(children: [
                        for (final (n, i) in list.indexed) ...[
                          if (n > 0) const Divider(height: 1),
                          _StockRow(item: i, main: showMain, mainName: s.van?.mainWarehouse ?? 'Main warehouse'),
                        ],
                      ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.options, required this.onTap});

  final List<(String, bool)> options;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: BeatproColors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          for (final (i, (label, active)) in options.indexed)
            Expanded(
              child: Semantics(
                selected: active,
                button: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => onTap(i),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 40),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: active ? BeatproColors.brandSoft : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                          color: active ? BeatproColors.brand : BeatproColors.muted,
                        )),
                  ),
                ),
              ),
            ),
        ]),
      );
}

class _VanHero extends StatelessWidget {
  const _VanHero({required this.stock, required this.money});

  final VanStockView stock;
  final Money money;

  @override
  Widget build(BuildContext context) {
    Widget figure(String label, double v) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: BeatproColors.onBrand)),
            Text(formatQty(v), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(gradient: BeatproColors.bandGradient, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('In the van now', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: BeatproColors.onBrand)),
        Text('${formatQty(stock.inVan)} cases',
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white, height: 1.2)),
        Text('${money(stock.value)} at sale price',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: BeatproColors.onBrand)),
        const SizedBox(height: 12),
        const Divider(color: Color(0x29FFFFFF), height: 1),
        const SizedBox(height: 12),
        Row(children: [
          figure('Loaded', stock.loaded),
          figure('Delivered', stock.sold),
          figure('Returned in', stock.returned),
        ]),
      ]),
    );
  }
}

class _VanActions extends StatelessWidget {
  const _VanActions({required this.stock});

  final VanStockView stock;

  @override
  Widget build(BuildContext context) {
    final unload = stock.todayUnload;
    final serverUnload = stock.serverUnload;
    if (unload != null || serverUnload != null) {
      final state = serverUnload?['state'] ?? unload?.data['odooState'];
      return _Note(
        color: BeatproColors.successSoft,
        ink: BeatproColors.success,
        text: unload != null && unload.state != SyncState.synced
            ? 'Unload counted. It goes to the storekeeper when you sync.'
            : state == 'done'
                ? 'The van is unloaded for today.'
                : 'Unload sent. The storekeeper receives the van.',
      );
    }
    return Row(children: [
      Expanded(
        child: stock.loadWaiting
            ? const _Note(
                color: BeatproColors.amberSoft,
                ink: BeatproColors.amberInk,
                text: 'Load request sent. Stock moves into the van when the storekeeper confirms.',
              )
            : FilledButton.icon(
                onPressed: () => context.push('/van/load'),
                icon: const Icon(Icons.local_shipping_outlined),
                label: Text(stock.loaded > 0 ? 'Load more' : 'Load the van'),
              ),
      ),
      if (stock.inVan > 0) ...[
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => context.push('/van/unload'),
            icon: const Icon(Icons.move_to_inbox_outlined),
            label: const Text('Unload'),
          ),
        ),
      ],
    ]);
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.color, required this.ink});

  final String text;
  final Color color;
  final Color ink;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: Text(text, style: TextStyle(color: ink, fontSize: 13, fontWeight: FontWeight.w600)),
      );
}

class _StockRow extends StatelessWidget {
  const _StockRow({required this.item, required this.main, required this.mainName});

  final VanItem item;
  final bool main;
  final String mainName;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (item.status) {
      'out' => ('none left', BeatproColors.dangerSoft, BeatproColors.danger),
      'low' => ('running low', BeatproColors.amberSoft, BeatproColors.amberInk),
      _ => ('in van', BeatproColors.successSoft, BeatproColors.success),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text(
              main
                  ? 'Delivered by $mainName'
                  : 'Loaded ${formatQty(item.loaded)} · delivered ${formatQty(item.sold)} · returned ${formatQty(item.returned)}',
              style: const TextStyle(fontSize: 12, color: BeatproColors.muted),
            ),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(formatQty(main ? item.mainQty : item.left), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          if (!main)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
              child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
            ),
        ]),
      ]),
    );
  }
}

// -- Morning load ---------------------------------------------------------------

class VanLoadScreen extends ConsumerStatefulWidget {
  const VanLoadScreen({super.key});

  @override
  ConsumerState<VanLoadScreen> createState() => _VanLoadScreenState();
}

class _VanLoadScreenState extends ConsumerState<VanLoadScreen> {
  final Map<int, double> _qty = {};
  Map<int, Product> _products = {};
  VanStockView? _stock;
  double _suggested = 0;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final products = {for (final p in await repo.db.products()) p.id: p};
    final stock = await repo.vanStock();
    final suggestion = await repo.loadSuggestion();
    if (!mounted) return;
    setState(() {
      _products = products;
      _stock = stock;
      for (final s in suggestion) {
        if (products.containsKey(s['product_id'])) _qty[s['product_id'] as int] = (s['qty'] as num).toDouble();
      }
      _suggested = _qty.values.fold(0.0, (a, b) => a + b);
      _loading = false;
    });
  }

  double get _total => _qty.values.fold(0.0, (a, b) => a + b);

  Future<void> _addProduct() async {
    final picked = await pickProduct(context, _products.values.where((p) => !_qty.containsKey(p.id)).toList());
    if (picked != null) setState(() => _qty[picked.id] = 1);
  }

  Future<void> _send() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).requestLoad({
        for (final e in _qty.entries)
          if (_products[e.key] != null) _products[e.key]!: e.value,
      });
      ref.read(dataVersionProvider.notifier).bump();
      unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) {
        showMessage(context, _stock?.van?.selfLoad == true ? 'Van loaded.' : 'Load request sent to the storekeeper.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final van = _stock?.van;
    final value = _qty.entries.fold(0.0, (s, e) => s + e.value * (_products[e.key]?.listPrice ?? 0));
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Load the van'),
          Text([van?.vehicle, 'from ${van?.mainWarehouse ?? 'main warehouse'}'].whereType<String>().join(' · '),
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
              if (_suggested > 0)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(gradient: BeatproColors.bandGradient, borderRadius: BorderRadius.circular(16)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Suggested for today',
                        style: TextStyle(color: BeatproColors.amber, fontWeight: FontWeight.w800, fontSize: 13)),
                    const SizedBox(height: 6),
                    Text('${formatQty(_suggested)} cases',
                        style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                    const Text("Based on today's shops' last 4 orders.",
                        style: TextStyle(color: BeatproColors.onBrand, fontSize: 13)),
                  ]),
                ),
              Row(children: [
                const Expanded(child: Eyebrow('Products to load', padding: EdgeInsets.fromLTRB(0, 20, 0, 8))),
                TextButton(onPressed: _addProduct, child: const Text('+ Add product')),
              ]),
              if (_qty.isEmpty)
                const Text('No suggestion for today. Add the products you need.', style: TextStyle(color: BeatproColors.muted))
              else
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    for (final (n, id) in _qty.keys.toList().indexed) ...[
                      if (n > 0) const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(_products[id]?.name ?? '', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                              Text('Main warehouse has ${formatQty(_stock?.mainOf(id) ?? 0)}',
                                  style: const TextStyle(fontSize: 12, color: BeatproColors.muted)),
                            ]),
                          ),
                          QtyStepper(qty: _qty[id]!, onChanged: (q) => setState(() => q <= 0 ? _qty.remove(id) : _qty[id] = q)),
                        ]),
                      ),
                    ],
                  ]),
                ),
              const SizedBox(height: 12),
              if (van?.selfLoad != true)
                const _Note(
                  color: BeatproColors.amberSoft,
                  ink: BeatproColors.amberInk,
                  text: 'The storekeeper checks the request, loads the van and confirms. Stock moves into your van only then.',
                ),
            ]),
      bottomNavigationBar: _BottomButton(
        label: van?.selfLoad == true
            ? 'Load the van · ${formatQty(_total)} cases'
            : 'Send load request · ${formatQty(_total)} cases',
        sub: _total > 0 ? money(value) : null,
        onPressed: _saving || _total <= 0 ? null : _send,
      ),
    );
  }
}

// -- Day-end unload ---------------------------------------------------------------

class VanUnloadScreen extends ConsumerStatefulWidget {
  const VanUnloadScreen({super.key});

  @override
  ConsumerState<VanUnloadScreen> createState() => _VanUnloadScreenState();
}

class _VanUnloadScreenState extends ConsumerState<VanUnloadScreen> {
  VanStockView? _stock;
  final Map<int, TextEditingController> _counted = {};
  final _note = TextEditingController();
  int _damaged = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _counted.values) {
      c.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final stock = await repo.vanStock();
    final returns = await repo.db.records(kind: RecordKind.shopReturn, since: repo.startOfToday.toUtc());
    var damaged = 0.0;
    for (final r in returns) {
      for (final l in (r.data['lines'] as List).cast<Map<String, dynamic>>()) {
        if (l['resellable'] != true) damaged += (l['qty'] as num).toDouble();
      }
    }
    if (!mounted) return;
    setState(() {
      _stock = stock;
      _damaged = damaged.round();
      for (final i in _expectedItems) {
        _counted[i.productId] = TextEditingController(text: formatQty(_expected(i)))..addListener(() => setState(() {}));
      }
    });
  }

  List<VanItem> get _expectedItems => _stock?.items.where((i) => i.left != 0 || i.loaded != 0).toList() ?? [];
  double _expected(VanItem i) => i.left > 0 ? i.left : 0;
  double _countOf(VanItem i) => double.tryParse(_counted[i.productId]?.text.trim() ?? '') ?? 0;

  Future<void> _send() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).sendUnload(
        {for (final i in _expectedItems) i.productId: _countOf(i)},
        note: _note.text,
      );
      ref.read(dataVersionProvider.notifier).bump();
      unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) {
        showMessage(context, 'Unload sent. The storekeeper receives the van.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stock = _stock;
    final items = _expectedItems;
    final shortages = [for (final i in items) if (_countOf(i) != _expected(i)) i];
    final counted = items.fold(0.0, (s, i) => s + _countOf(i));
    final expected = items.fold(0.0, (s, i) => s + _expected(i));
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Unload the van'),
          Text("Count what's left · back to ${stock?.van?.mainWarehouse ?? 'main warehouse'}",
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: stock == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
              Row(children: [
                Expanded(child: _Stat(label: 'Loaded', value: stock.loaded)),
                const SizedBox(width: 8),
                Expanded(child: _Stat(label: 'Delivered', value: stock.sold)),
                const SizedBox(width: 8),
                Expanded(child: _Stat(label: 'Expected', value: expected)),
              ]),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Row(children: [
                      Expanded(child: _Head('Product')),
                      SizedBox(width: 64, child: _Head('Expected', center: true)),
                      SizedBox(width: 8),
                      SizedBox(width: 76, child: _Head('Counted', center: true)),
                    ]),
                  ),
                  for (final i in items) ...[
                    const Divider(height: 1),
                    _CountRow(item: i, expected: _expected(i), counted: _countOf(i), controller: _counted[i.productId]!),
                  ],
                ]),
              ),
              if (shortages.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: BeatproColors.dangerSoft, borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      shortages.map((i) {
                        final d = _countOf(i) - _expected(i);
                        return '${formatQty(d.abs())} ${d < 0 ? 'short' : 'extra'}: ${i.name}';
                      }).join('\n'),
                      style: const TextStyle(fontWeight: FontWeight.w800, color: BeatproColors.danger),
                    ),
                    const SizedBox(height: 4),
                    const Text('Add a note. Your supervisor sees the difference when the storekeeper receives the van.',
                        style: TextStyle(fontSize: 13, color: BeatproColors.danger)),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'What happened? For example: one box torn, given to the shop as a free sample.',
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                  ]),
                ),
              ],
              if (_damaged > 0) ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    title: const Text('Damaged returns from shops', style: TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: const Text('Go to the damaged stock area'),
                    trailing: Text('$_damaged items', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ),
              ],
            ]),
      bottomNavigationBar: _BottomButton(
        label: 'Send unload · ${formatQty(counted)} cases',
        onPressed: _saving || stock == null || items.isEmpty ? null : _send,
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: SmallFigure(label: label, value: formatQty(value)),
        ),
      );
}

class _Head extends StatelessWidget {
  const _Head(this.text, {this.center = false});

  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        textAlign: center ? TextAlign.center : TextAlign.start,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: BeatproColors.muted),
      );
}

class _CountRow extends StatelessWidget {
  const _CountRow({required this.item, required this.expected, required this.counted, required this.controller});

  final VanItem item;
  final double expected;
  final double counted;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final diff = counted - expected;
    final off = diff.abs() > 0.0001;
    return Container(
      color: off ? const Color(0xFFFFF8F7) : null,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            Text(
              off ? '${formatQty(diff.abs())} ${diff < 0 ? 'short' : 'extra'}' : 'Matches',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: off ? BeatproColors.danger : BeatproColors.success),
            ),
          ]),
        ),
        SizedBox(
          width: 64,
          child: Text(formatQty(expected),
              textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700, color: BeatproColors.muted)),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 76,
          child: TextField(
            controller: controller,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              isDense: true,
              semanticCounterText: 'Counted',
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: off ? BeatproColors.danger : BeatproColors.line, width: off ? 2 : 1),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// -- Shared -------------------------------------------------------------------------

class _BottomButton extends StatelessWidget {
  const _BottomButton({required this.label, required this.onPressed, this.sub});

  final String label;
  final String? sub;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: onPressed,
              child: Text(label),
            ),
          ),
        ),
      );
}

/// A minus / quantity / plus control.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.qty, required this.onChanged});

  final double qty;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton.outlined(onPressed: () => onChanged(qty - 1), icon: const Icon(Icons.remove), tooltip: 'Less'),
        SizedBox(
          width: 36,
          child: Text(formatQty(qty), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ),
        IconButton.filled(
          onPressed: () => onChanged(qty + 1),
          icon: const Icon(Icons.add),
          tooltip: 'More',
          color: Theme.of(context).colorScheme.onPrimary,
        ),
      ]);
}

/// Lets the rep pick a product from a searchable list.
Future<T?> pickFrom<T>(BuildContext context, List<T> items, String Function(T) name, {String Function(T)? sub}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _PickerSheet<T>(items: items, name: name, sub: sub),
    );

Future<Product?> pickProduct(BuildContext context, List<Product> products) =>
    pickFrom<Product>(context, products, (p) => p.name);

class _PickerSheet<T> extends StatefulWidget {
  const _PickerSheet({required this.items, required this.name, this.sub});

  final List<T> items;
  final String Function(T) name;
  final String Function(T)? sub;

  @override
  State<_PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<_PickerSheet<T>> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final visible = widget.items.where((i) => widget.name(i).toLowerCase().contains(_search)).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search products', isDense: true),
            onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: ListView.separated(
            controller: scroll,
            itemCount: visible.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => ListTile(
              title: Text(widget.name(visible[i])),
              subtitle: widget.sub == null ? null : Text(widget.sub!(visible[i])),
              onTap: () => Navigator.pop(context, visible[i]),
            ),
          ),
        ),
      ]),
    );
  }
}
