import 'dart:convert';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

Color _stateColor(String? state) => switch (state) {
      'red' => BeatproColors.danger,
      'amber' => BeatproColors.warning,
      'green' => BeatproColors.success,
      _ => BeatproColors.muted,
    };

/// The Inventory figures from Odoo, with the last ones kept for when there is no
/// signal. Supervisors only.
class _InventoryLoader {
  _InventoryLoader(this.ref);

  final WidgetRef ref;

  Future<(Map<String, dynamic>?, bool cached, String? error)> load() async {
    final sync = ref.read(syncServiceProvider);
    String? error;
    if (sync != null) {
      try {
        return (await sync.inventory(), false, null);
      } catch (e) {
        error = describeError(e);
      }
    }
    final raw = await ref.read(localDbProvider).getValue('inventory');
    if (raw == null) return (null, false, error);
    return ((jsonDecode(raw) as Map).cast<String, dynamic>(), true, error);
  }
}

mixin _InventoryState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Map<String, dynamic>? data;
  bool cached = false;
  bool loading = true;
  String? error;

  Future<void> reload() async {
    setState(() => loading = true);
    final (d, c, e) = await _InventoryLoader(ref).load();
    if (!mounted) return;
    setState(() {
      data = d;
      cached = c;
      error = e;
      loading = false;
    });
  }

  Widget? notLoaded() {
    if (data != null) return null;
    if (loading) return const Center(child: CircularProgressIndicator());
    return EmptyState(
      icon: Icons.signal_wifi_off,
      title: 'Inventory not available',
      message: error ?? 'The Inventory figures come from Odoo. Try again when you have signal.',
    );
  }

  Widget cachedBanner() => cached
      ? const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('No signal: these are the figures fetched last time.',
              style: TextStyle(color: BeatproColors.warning, fontWeight: FontWeight.w700)),
        )
      : const SizedBox.shrink();
}

/// Supervisor: stock in every van today, with what needs acting on.
class FleetStockScreen extends ConsumerStatefulWidget {
  const FleetStockScreen({super.key});

  @override
  ConsumerState<FleetStockScreen> createState() => _FleetStockScreenState();
}

class _FleetStockScreenState extends ConsumerState<FleetStockScreen> with _InventoryState {
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    final vans = (d?['vans'] as List? ?? const []).cast<Map<String, dynamic>>();
    final kpis = (d?['kpis'] as Map?)?.cast<String, dynamic>() ?? const {};
    final alerts = (d?['alerts'] as List? ?? const []).cast<Map<String, dynamic>>();
    final red = alerts.where((a) => a['kind'] == 'red').toList();
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Van stock'),
          if (d != null)
            Text(tr('Today · ${d['van_count']} vans'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: BeatproColors.muted)),
        ]),
        actions: [
          IconButton(
            tooltip: tr('Stock alerts'),
            onPressed: () => context.push('/inventory/alerts'),
            icon: Badge(isLabelVisible: alerts.isNotEmpty, label: Text('${alerts.length}'), child: const Icon(Icons.notifications_outlined)),
          ),
          IconButton(tooltip: tr('Refresh'), onPressed: loading ? null : reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: notLoaded() ??
          RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              cachedBanner(),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.9,
                children: [
                  _Mini(label: 'Stock in vans', value: kpis['van_stock'] ?? '', note: kpis['van_stock_note'] ?? ''),
                  _Mini(label: 'Short today', value: kpis['short'] ?? '', note: kpis['short_note'] ?? '', color: BeatproColors.warning),
                  _Mini(
                      label: 'Expiring in ${d!['expiry_days']} days',
                      value: kpis['expiring'] ?? '',
                      note: kpis['expiring_note'] ?? '',
                      color: BeatproColors.danger),
                  _Mini(label: 'Unload difference', value: kpis['unload_diff'] ?? '', note: kpis['unload_diff_note'] ?? '', color: BeatproColors.danger),
                ],
              ),
              for (final a in red.take(2)) ...[
                const SizedBox(height: 10),
                _AlertBanner(alert: a),
              ],
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Eyebrow('Vans', padding: EdgeInsets.fromLTRB(0, 12, 0, 4)),
                    if (vans.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('No vans yet.')),
                    for (final v in vans) _VanRow(van: v),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Top-ups and purchase orders are made in Odoo › Inventory.',
                  textAlign: TextAlign.center, style: TextStyle(color: BeatproColors.muted, fontSize: 12)),
            ]),
          ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({required this.label, required this.value, required this.note, this.color});

  final String label;
  final String value;
  final String note;
  final Color? color;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: BeatproColors.muted, fontWeight: FontWeight.w700)),
            FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
            Text(note, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: color ?? BeatproColors.muted, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.alert});

  final Map<String, dynamic> alert;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BeatproColors.dangerSoft,
          border: Border.all(color: const Color(0xFFF2C4C7)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(alert['title'] as String, style: const TextStyle(color: BeatproColors.danger, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(alert['text'] as String),
        ]),
      );
}

class _VanRow extends StatelessWidget {
  const _VanRow({required this.van});

  final Map<String, dynamic> van;

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(van['state'] as String?);
    final rep = van['rep'] as String? ?? '';
    return InkWell(
      onTap: () => context.push('/inventory/van/${van['id']}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(rep.isEmpty ? van['name'] as String : '${van['name']} · $rep',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            Text(tr('${van['sold_pct']}% sold'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: ((van['sold_pct'] as num) / 100).clamp(0, 1).toDouble(),
              minHeight: 8,
              color: color,
              backgroundColor: BeatproColors.lineSoft,
            ),
          ),
          const SizedBox(height: 6),
          Text(van['note'] as String, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      ),
    );
  }
}

/// Supervisor: one van's products today.
class InventoryVanScreen extends ConsumerStatefulWidget {
  const InventoryVanScreen({super.key, required this.vanId});

  final int vanId;

  @override
  ConsumerState<InventoryVanScreen> createState() => _InventoryVanScreenState();
}

class _InventoryVanScreenState extends ConsumerState<InventoryVanScreen> {
  Map<String, dynamic>? _van;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sync = ref.read(syncServiceProvider);
      if (sync == null) throw StateError('Sign in first.');
      final van = await sync.inventoryVan(widget.vanId);
      if (mounted) setState(() => _van = van);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _van;
    final rep = v?['rep'] as String? ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v == null ? 'Van' : (rep.isEmpty ? v['name'] as String : '${v['name']} · $rep')),
          if (v != null)
            Text(tr('${v['value_left']} left'), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: BeatproColors.muted)),
        ]),
      ),
      body: v == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.signal_wifi_off, title: 'Van not available', message: _error),
            )
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Expanded(child: SmallFigure(label: 'Sold', value: '${(v['today'] as Map)['sold']}')),
                    Expanded(
                      child: SmallFigure(
                        label: 'Short (went to warehouse)',
                        value: '${(v['today'] as Map)['short_orders']}',
                        color: BeatproColors.warning,
                      ),
                    ),
                    Expanded(child: SmallFigure(label: 'Taken back', value: '${(v['today'] as Map)['returned']}')),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(children: [
                  for (final p in (v['products'] as List).cast<Map<String, dynamic>>())
                    ListTile(
                      dense: true,
                      title: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text(tr('Left ${p['left']} · sold ${p['sold_pct']}% · last sold ${p['last_sold']}')),
                      trailing: _StatusPill(label: p['label'] as String, status: p['status'] as String),
                    ),
                ]),
              ),
              const SizedBox(height: 8),
              Text(v['unload_note'] as String, textAlign: TextAlign.center, style: const TextStyle(color: BeatproColors.muted, fontSize: 12)),
            ]),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.status});

  final String label;
  final String status;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (status) {
      'out' => (BeatproColors.dangerSoft, BeatproColors.danger),
      'expiring' || 'low' => (BeatproColors.amberSoft, BeatproColors.amberInk),
      'selling' => (BeatproColors.successSoft, BeatproColors.success),
      _ => (BeatproColors.lineSoft, BeatproColors.muted),
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 130),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(99)),
      child: Text(label, maxLines: 2, textAlign: TextAlign.center, style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

/// Supervisor: stock alerts from Odoo, newest figures at each refresh or sync.
class StockAlertsScreen extends ConsumerStatefulWidget {
  const StockAlertsScreen({super.key});

  @override
  ConsumerState<StockAlertsScreen> createState() => _StockAlertsScreenState();
}

class _StockAlertsScreenState extends ConsumerState<StockAlertsScreen> with _InventoryState {
  String _filter = 'all';

  static String _group(Map<String, dynamic> a) => switch (a['action']) {
        'purchase' => 'warehouse',
        'expiry' => 'expiry',
        _ => 'vans',
      };

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Widget build(BuildContext context) {
    final alerts = (data?['alerts'] as List? ?? const []).cast<Map<String, dynamic>>();
    final shown = alerts.where((a) => _filter == 'all' || _group(a) == _filter).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock alerts'),
        actions: [IconButton(tooltip: tr('Refresh'), onPressed: loading ? null : reload, icon: const Icon(Icons.refresh))],
      ),
      body: notLoaded() ??
          RefreshIndicator(
            onRefresh: reload,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              cachedBanner(),
              Wrap(spacing: 6, children: [
                for (final (key, label) in [('all', 'All ${alerts.length}'), ('warehouse', 'Warehouse'), ('vans', 'Vans'), ('expiry', 'Expiry')])
                  ChoiceChip(label: Text(label), selected: _filter == key, onSelected: (_) => setState(() => _filter = key)),
              ]),
              const SizedBox(height: 8),
              if (shown.isEmpty)
                const EmptyState(icon: Icons.check_circle_outline, title: 'No stock alerts', message: 'Nothing needs acting on right now.'),
              for (final a in shown)
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  clipBehavior: Clip.antiAlias,
                  child: Container(
                    decoration: BoxDecoration(
                      border: BorderDirectional(start: BorderSide(color: _stateColor(a['kind'] as String?), width: 5)),
                    ),
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(a['title'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(a['text'] as String, style: const TextStyle(color: BeatproColors.muted)),
                    ]),
                  ),
                ),
              const SizedBox(height: 8),
              const Text('Act on them in Odoo › Inventory. You choose the amounts that raise an alert in BeatPro settings.',
                  textAlign: TextAlign.center, style: TextStyle(color: BeatproColors.muted, fontSize: 12)),
            ]),
          ),
    );
  }
}
