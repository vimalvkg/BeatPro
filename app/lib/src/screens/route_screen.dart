import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/repository.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class RouteScreen extends ConsumerWidget {
  const RouteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(todayPlanProvider);
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
          return RefreshIndicator(
            onRefresh: () => ref.read(syncControllerProvider.notifier).run(),
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: stops.length + 1,
              separatorBuilder: (_, i) => i == 0 ? const SizedBox.shrink() : const Divider(height: 1, indent: 72),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text('$done of ${stops.length} visited · ${stops.first.stop.routeName}',
                        style: Theme.of(context).textTheme.bodyMedium),
                  );
                }
                return _StopTile(view: stops[i - 1], number: i);
              },
            ),
          );
        },
      ),
    );
  }
}

class _StopTile extends ConsumerWidget {
  const _StopTile({required this.view, required this.number});

  final StopView view;
  final int number;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final customer = view.customer;
    final (color, label) = view.visited
        ? (BeatproColors.success, 'Visited')
        : view.inProgress
            ? (BeatproColors.warning, 'In progress')
            : (theme.colorScheme.outline, 'To visit');
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      leading: CircleAvatar(
        backgroundColor: view.visited ? BeatproColors.success : theme.colorScheme.primaryContainer,
        foregroundColor: view.visited ? Colors.white : theme.colorScheme.onPrimaryContainer,
        child: view.visited ? const Icon(Icons.check) : Text('$number'),
      ),
      title: Text(customer.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(children: [
          StatusChip(label, color: color),
          if (customer.city != null) ...[
            const SizedBox(width: 8),
            Flexible(child: Text(customer.city!, overflow: TextOverflow.ellipsis)),
          ],
        ]),
      ),
      trailing: customer.latitude == null
          ? null
          : IconButton(
              tooltip: 'Directions',
              icon: const Icon(Icons.directions_outlined),
              onPressed: () => launchUrl(
                Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${customer.latitude},${customer.longitude}'),
                mode: LaunchMode.externalApplication,
              ),
            ),
      onTap: () => view.visit != null && !view.visited
          ? context.push('/visit/${view.visit!.uuid}')
          : context.push('/customer/${Uri.encodeComponent(customer.key)}?route=${view.stop.routeId}'),
    );
  }
}
