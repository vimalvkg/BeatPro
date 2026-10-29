import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyProvider);
    final appContext = ref.watch(appContextProvider).value;
    final summary = ref.watch(daySummaryProvider);
    final plan = ref.watch(todayPlanProvider);
    final active = ref.watch(activeVisitProvider).value;
    final lastSync = ref.watch(lastSyncProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Hello, ${appContext?.userName.split(' ').first ?? ''}'),
          Text(appContext?.companyName ?? '', style: theme.textTheme.bodySmall),
        ]),
        actions: const [SyncButton()],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).run(),
        child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: AsyncBody(
              value: summary,
              builder: (s) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Today', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: s.planned == 0 ? 0 : (s.visitsDone / s.planned).clamp(0, 1),
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 6),
                    Text('${s.visitsDone} of ${s.planned} visits done', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 16),
                    Row(children: [
                      Expanded(child: Figure(label: 'Orders', value: '${s.orderCount}')),
                      Expanded(child: Figure(label: 'Order value', value: money(s.orderValue))),
                      Expanded(child: Figure(label: 'Collected', value: money(s.totalCollected), color: BeatproColors.success)),
                    ]),
                  ]),
                ),
              ),
            ),
          ),
          if (active != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _ActiveVisitCard(visitUuid: active.uuid, customerKey: active.data['customerKey'] as String),
            )
          else
            plan.maybeWhen(
              data: (stops) {
                final next = stops.where((s) => s.visit == null).firstOrNull;
                if (next == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Card(
                    color: theme.colorScheme.primaryContainer,
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      title: Text('Next visit', style: theme.textTheme.labelMedium),
                      subtitle: Text(next.customer.name, style: theme.textTheme.titleMedium),
                      trailing: FilledButton(
                        onPressed: () => context.push('/customer/${Uri.encodeComponent(next.customer.key)}?route=${next.stop.routeId}'),
                        child: const Text('Go'),
                      ),
                    ),
                  ),
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
          Section(
            title: 'Quick actions',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                ActionChip(avatar: const Icon(Icons.route, size: 18), label: const Text("Today's route"), onPressed: () => context.go('/route')),
                ActionChip(avatar: const Icon(Icons.person_add_alt, size: 18), label: const Text('New customer'), onPressed: () => context.push('/customers/new')),
                ActionChip(avatar: const Icon(Icons.nightlight_outlined, size: 18), label: const Text('Close day'), onPressed: () => context.push('/day-close')),
              ]),
            ),
          ),
          Section(
            title: 'Sync',
            child: ListTile(
              leading: Icon(pending == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
                  color: pending == 0 ? BeatproColors.success : BeatproColors.warning),
              title: Text(pending == 0 ? 'Everything is in Odoo' : '$pending waiting to sync'),
              subtitle: Text(lastSync == null ? 'Not synced yet' : 'Last synced ${formatDate(lastSync)}, ${formatTime(lastSync)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/sync'),
            ),
          ),
        ]),
      ),
    );
  }
}

class _ActiveVisitCard extends ConsumerWidget {
  const _ActiveVisitCard({required this.visitUuid, required this.customerKey});

  final String visitUuid;
  final String customerKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = ref.watch(customerProvider(customerKey)).value;
    final theme = Theme.of(context);
    return Card(
      color: BeatproColors.amber.withValues(alpha: 0.18),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        leading: const Icon(Icons.storefront, color: BeatproColors.warning),
        title: Text('Visit in progress', style: theme.textTheme.labelMedium),
        subtitle: Text(customer?.name ?? '', style: theme.textTheme.titleMedium),
        trailing: FilledButton(onPressed: () => context.push('/visit/$visitUuid'), child: const Text('Open')),
      ),
    );
  }
}
