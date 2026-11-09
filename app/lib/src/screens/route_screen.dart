import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/repository.dart';
import '../core/route_plan.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

/// Where the rep is now, for the shortest way through the shops left.
final _hereProvider = FutureProvider<GeoPoint?>((ref) => ref.watch(locationProvider).current());

final _shortestProvider = FutureProvider<(List<String>, double)?>((ref) async {
  ref.watch(dataVersionProvider);
  final here = await ref.watch(_hereProvider.future);
  return ref.watch(repositoryProvider).shortestRoute(here);
});

class RouteScreen extends ConsumerWidget {
  const RouteScreen({super.key});

  Future<void> _move(BuildContext context, WidgetRef ref, StopView view, {required bool skip}) async {
    await ref.read(repositoryProvider).moveStop(view, skip: skip);
    ref.read(dataVersionProvider.notifier).bump();
    if (context.mounted) {
      showMessage(context, skip ? '${view.customer.name} skipped today: shop closed.' : '${view.customer.name} moved to tomorrow.');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(todayPlanProvider);
    final shortest = ref.watch(_shortestProvider).value;
    final here = ref.watch(_hereProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text("Today's route"), actions: const [SyncButton()]),
      body: AsyncBody(
        value: plan,
        builder: (stops) {
          if (stops.isEmpty) {
            return const EmptyState(
              icon: Icons.route,
              title: 'Nothing planned for today',
              message: 'Your supervisor sets your routes in Odoo. Sync to get the latest plan.',
            );
          }
          final done = stops.where((s) => s.visited).length;
          final next = stops.where((s) => s.visit == null && !s.skipped).firstOrNull;
          final pinned = [
            for (final s in stops)
              if (s.customer.latitude != null && s.customer.longitude != null) s,
          ];
          final points = [for (final s in pinned) (s.customer.latitude!, s.customer.longitude!)];
          final start = here == null ? null : (here.latitude, here.longitude);
          final km = pathKm(start, points);
          return RefreshIndicator(
            onRefresh: () => ref.read(syncControllerProvider.notifier).run(),
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Text(
                  '$done of ${stops.length} visited${km > 0 ? ' · ${km.toStringAsFixed(1)} km' : ''}'
                  ' · ${{for (final s in stops) s.stop.routeName}.join(', ')}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: BeatproColors.muted),
                ),
              ),
              if (shortest != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  decoration: BoxDecoration(color: const Color(0xFFE6EEF7), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Expanded(
                      child: Text('Shortest way from where you are: saves ${shortest.$2.toStringAsFixed(1)} km',
                          style: const TextStyle(color: Color(0xFF184878), fontWeight: FontWeight.w700, fontSize: 13)),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF184878)),
                      onPressed: () async {
                        await ref.read(repositoryProvider).useRouteOrder(shortest.$1);
                        ref.read(dataVersionProvider.notifier).bump();
                      },
                      child: const Text('Use this order'),
                    ),
                  ]),
                ),
              if (points.length >= 2)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      height: 150,
                      child: CustomPaint(
                        painter: _RoutePainter(
                          start: start,
                          stops: [for (final s in pinned) ((s.customer.latitude!, s.customer.longitude!), s.visited)],
                        ),
                      ),
                    ),
                  ),
                ),
              for (final (i, view) in stops.indexed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: StopCard(
                    view: view,
                    number: i + 1,
                    isNext: identical(view, next),
                    subtitle: start != null && view.customer.latitude != null
                        ? '${view.customer.city ?? ''} · ${distanceKm(start, (view.customer.latitude!, view.customer.longitude!)).toStringAsFixed(1)} km'
                            .replaceFirst(RegExp(r'^ · '), '')
                        : null,
                    trailing: view.visit != null
                        ? null
                        : PopupMenuButton<String>(
                            tooltip: 'More for this shop',
                            icon: const Icon(Icons.more_vert, color: BeatproColors.muted),
                            onSelected: (choice) async {
                              switch (choice) {
                                case 'tomorrow':
                                  await _move(context, ref, view, skip: false);
                                case 'skip':
                                  await _move(context, ref, view, skip: true);
                                case 'directions':
                                  final c = view.customer;
                                  await launchUrl(
                                    c.latitude != null
                                        ? Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${c.latitude},${c.longitude}')
                                        : Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent('${c.name} ${c.city ?? ''}')}'),
                                    mode: LaunchMode.externalApplication,
                                  );
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'tomorrow', child: Text('Move to tomorrow')),
                              if (!view.skipped) const PopupMenuItem(value: 'skip', child: Text('Skip today · shop closed')),
                              const PopupMenuItem(value: 'directions', child: Text('Directions')),
                            ],
                          ),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}

/// A small sketch of the route: where the rep is, and the shops in order.
class _RoutePainter extends CustomPainter {
  _RoutePainter({required this.start, required this.stops});

  final (double, double)? start;
  final List<((double, double), bool)> stops;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFEFE9E3));
    final all = [?start, for (final s in stops) s.$1];
    final lats = all.map((p) => p.$1);
    final lngs = all.map((p) => p.$2);
    final minLat = lats.reduce((a, b) => a < b ? a : b), maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLng = lngs.reduce((a, b) => a < b ? a : b), maxLng = lngs.reduce((a, b) => a > b ? a : b);
    Offset at((double, double) p) {
      const pad = 18.0;
      final x = maxLng == minLng ? 0.5 : (p.$2 - minLng) / (maxLng - minLng);
      final y = maxLat == minLat ? 0.5 : 1 - (p.$1 - minLat) / (maxLat - minLat);
      return Offset(pad + x * (size.width - 2 * pad), pad + y * (size.height - 2 * pad));
    }

    final path = Path();
    final first = start ?? stops.first.$1;
    path.moveTo(at(first).dx, at(first).dy);
    for (final s in stops) {
      path.lineTo(at(s.$1).dx, at(s.$1).dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = BeatproColors.brand
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );
    for (final s in stops) {
      canvas.drawCircle(at(s.$1), 7, Paint()..color = s.$2 ? BeatproColors.success : BeatproColors.brand);
    }
    if (start != null) canvas.drawCircle(at(start!), 8, Paint()..color = const Color(0xFF184878));
  }

  @override
  bool shouldRepaint(_RoutePainter old) => old.start != start || old.stops != stops;
}
