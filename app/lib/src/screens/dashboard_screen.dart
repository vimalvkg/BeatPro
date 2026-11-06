import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _categoryColors = [BeatproColors.brand, Color(0xFFE0A12F), Color(0xFFE79AA3), Color(0xFF9DB4D6), Color(0xFFB9A6A8)];

/// The Van Sales Dashboard, for supervisors: the same figures as in Odoo. Needs signal.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  String _period = 'week';
  int? _routeId;
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = ref.read(syncServiceProvider);
      if (service == null) throw StateError('Sign in first.');
      final data = await service.salesDashboard(period: _period, routeId: _routeId);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Van Sales Dashboard'),
        actions: [IconButton(tooltip: 'Refresh', onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
      ),
      body: d == null
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : EmptyState(icon: Icons.signal_wifi_off, title: 'Dashboard not available', message: _error ?? ''),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(16), children: [
                _Hero(company: d['company'] as String? ?? ''),
                const SizedBox(height: 12),
                _Filters(
                  period: _period,
                  routeId: _routeId,
                  routes: (d['routes'] as List).cast<Map<String, dynamic>>(),
                  onPeriod: (p) {
                    _period = p;
                    _load();
                  },
                  onRoute: (r) {
                    _routeId = r;
                    _load();
                  },
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: const TextStyle(color: BeatproColors.danger)),
                  ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.25,
                  children: [for (final k in (d['kpis'] as List).cast<Map<String, dynamic>>()) _Kpi(kpi: k)],
                ),
                const SizedBox(height: 12),
                _Card(title: 'Sales overview', child: _SalesChart(d: d)),
                const SizedBox(height: 12),
                _Card(title: 'Sales by category', child: _Categories(d: d)),
                const SizedBox(height: 12),
                _Card(title: 'Top shops', child: _TopShops(rows: (d['top_shops'] as List).cast<Map<String, dynamic>>())),
                const SizedBox(height: 12),
                _Card(title: 'Sales by route', child: _Routes(rows: (d['routes_sales'] as List).cast<Map<String, dynamic>>())),
                const SizedBox(height: 12),
                _Card(title: 'Collections', child: _Collections(d: d)),
                const SizedBox(height: 12),
                _Card(title: 'Recent activity', child: _Activity(rows: (d['activity'] as List).cast<Map<String, dynamic>>())),
              ]),
            ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.company});

  final String company;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
        decoration: BoxDecoration(gradient: BeatproColors.bandGradient, borderRadius: BorderRadius.circular(18)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Sales on the move',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(company, style: const TextStyle(color: BeatproColors.onBrand, fontSize: 13)),
            ]),
          ),
          Image.asset('assets/images/van.png', width: 120, excludeFromSemantics: true),
        ]),
      );
}

class _Filters extends StatelessWidget {
  const _Filters({required this.period, required this.routeId, required this.routes, required this.onPeriod, required this.onRoute});

  final String period;
  final int? routeId;
  final List<Map<String, dynamic>> routes;
  final ValueChanged<String> onPeriod;
  final ValueChanged<int?> onRoute;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'week', label: Text('Week')),
            ButtonSegment(value: 'month', label: Text('Month')),
            ButtonSegment(value: 'quarter', label: Text('Quarter')),
            ButtonSegment(value: 'year', label: Text('Year')),
          ],
          selected: {period},
          onSelectionChanged: (s) => onPeriod(s.first),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int?>(
          initialValue: routeId,
          decoration: const InputDecoration(labelText: 'Route', isDense: true),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('All routes')),
            for (final r in routes) DropdownMenuItem<int?>(value: r['id'] as int, child: Text(r['name'] as String)),
          ],
          onChanged: onRoute,
        ),
      ]);
}

IconData _kpiIcon(String key) => switch (key) {
      'sales' => Icons.show_chart,
      'orders' => Icons.shopping_bag_outlined,
      'shops' => Icons.storefront_outlined,
      _ => Icons.savings_outlined,
    };

class _Kpi extends StatelessWidget {
  const _Kpi({required this.kpi});

  final Map<String, dynamic> kpi;

  @override
  Widget build(BuildContext context) {
    final trend = (kpi['trend'] as num?)?.toDouble();
    final spark = ((kpi['spark'] as List?) ?? const []).map((v) => (v as num).toDouble()).toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: const Border(left: BorderSide(color: BeatproColors.brand, width: 4)),
        boxShadow: const [BoxShadow(color: Color(0x0F4A0E14), blurRadius: 14, offset: Offset(0, 4))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        Positioned(left: 40, right: 0, bottom: 0, height: 34, child: CustomPaint(painter: _SparkPainter(spark))),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: BeatproColors.brand,
                child: Icon(_kpiIcon(kpi['key'] as String), size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(kpi['label'] as String,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: BeatproColors.muted)),
              ),
            ]),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(kpi['value'] as String, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            Text(
              trend == null ? 'No earlier figures' : '${trend >= 0 ? '↑' : '↓'} ${trend.abs()}% vs last period',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: trend == null ? BeatproColors.muted : (trend >= 0 ? BeatproColors.success : BeatproColors.danger),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values);

  final List<double> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final max = values.reduce(math.max).clamp(1, double.infinity);
    final path = Path();
    for (final (i, v) in values.indexed) {
      final p = Offset(size.width * i / (values.length - 1), size.height - (v / max) * (size.height - 4) - 2);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = BeatproColors.red.withValues(alpha: 0.10));
    canvas.drawPath(
      path,
      Paint()
        ..color = BeatproColors.red
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

class _SalesChart extends StatelessWidget {
  const _SalesChart({required this.d});

  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final chart = (d['chart'] as List).cast<Map<String, dynamic>>();
    final maxAmount = (d['chart_max_amount'] as num).toDouble();
    return Column(children: [
      SizedBox(
        height: 150,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final c in chart)
            Expanded(
              child: Semantics(
                label: '${c['label']}: ${c['count']} orders',
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if ((c['count'] as num) > 0)
                    Text('${c['count']}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: BeatproColors.muted)),
                  const SizedBox(height: 2),
                  FractionallySizedBox(
                    widthFactor: 0.6,
                    child: Container(
                      height: math.max(3, 120 * (c['amount'] as num).toDouble() / (maxAmount <= 0 ? 1 : maxAmount)),
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [BeatproColors.red, BeatproColors.brandDeep],
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
      const Divider(height: 1),
      const SizedBox(height: 6),
      Row(children: [
        for (final c in chart)
          Expanded(
            child: Text(c['label'] as String,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: BeatproColors.muted)),
          ),
      ]),
      const SizedBox(height: 4),
      const Text('Bars: sales · numbers: orders', style: TextStyle(fontSize: 11, color: BeatproColors.muted)),
    ]);
  }
}

class _Categories extends StatelessWidget {
  const _Categories({required this.d});

  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final rows = (d['categories'] as List).cast<Map<String, dynamic>>();
    if (rows.isEmpty) return const Text('No sales yet', style: TextStyle(color: BeatproColors.muted));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(d['sales_total'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 14,
          child: Row(children: [
            for (final (i, c) in rows.indexed)
              if ((c['share'] as num) > 0)
                Expanded(flex: (c['share'] as num).toInt(), child: ColoredBox(color: _categoryColors[i % _categoryColors.length])),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      for (final (i, c) in rows.indexed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: _categoryColors[i % _categoryColors.length], shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(c['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text('${c['share']}%', style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
    ]);
  }
}

class _TopShops extends StatelessWidget {
  const _TopShops({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text('No orders yet', style: TextStyle(color: BeatproColors.muted));
    return Column(children: [
      for (final (i, r) in rows.indexed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: BeatproColors.brandSoft,
              child: Text('${i + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: BeatproColors.brand)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(r['amount'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
    ]);
  }
}

class _Routes extends StatelessWidget {
  const _Routes({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text('No orders yet', style: TextStyle(color: BeatproColors.muted));
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
              Text(r['amount'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (r['pct'] as num).toDouble() / 100,
                minHeight: 10,
                backgroundColor: BeatproColors.brandSoft,
                color: BeatproColors.brand,
              ),
            ),
          ]),
        ),
    ]);
  }
}

class _Collections extends StatelessWidget {
  const _Collections({required this.d});

  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final pct = (d['collected_pct'] as num).toDouble();
    Widget row(Color color, String label, String value, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            if (!bold) Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            if (!bold) const SizedBox(width: 8),
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        );
    return Row(children: [
      SizedBox(
        width: 96,
        height: 96,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 88,
            height: 88,
            child: CircularProgressIndicator(
              value: pct / 100,
              strokeWidth: 12,
              backgroundColor: const Color(0xFFE0A12F),
              color: BeatproColors.successDot,
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${pct.round()}%', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const Text('collected', style: TextStyle(fontSize: 10, color: BeatproColors.muted)),
          ]),
        ]),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Column(children: [
          row(BeatproColors.successDot, 'Collected', d['collected'] as String),
          row(const Color(0xFFE0A12F), 'Still due', d['due'] as String),
          const Divider(),
          row(BeatproColors.ink, 'Total', d['collect_total'] as String, bold: true),
        ]),
      ),
    ]);
  }
}

class _Activity extends StatelessWidget {
  const _Activity({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const Text('Nothing yet', style: TextStyle(color: BeatproColors.muted));
    Color dot(String kind) => switch (kind) {
          'order' => BeatproColors.red,
          'payment' => BeatproColors.successDot,
          'alert' => const Color(0xFFE0A12F),
          _ => BeatproColors.brand,
        };
    return Column(children: [
      for (final a in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(color: dot(a['kind'] as String), shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(a['text'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            Text(a['time'] as String, style: const TextStyle(fontSize: 12, color: BeatproColors.muted)),
          ]),
        ),
    ]);
  }
}
