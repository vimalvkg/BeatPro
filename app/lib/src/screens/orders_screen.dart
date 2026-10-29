import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Odoo's state for an order, in the rep's words.
Widget orderStatus(LocalRecord order) {
  if (order.state != SyncState.synced) return SyncStateChip(order);
  if (order.data['approval'] == 'waiting') {
    return const StatusChip('Waiting for approval', color: BeatproColors.warning, icon: Icons.hourglass_top);
  }
  return switch (order.data['odooState']) {
    'sale' => const StatusChip('Confirmed', color: BeatproColors.success, icon: Icons.check_circle_outline),
    'cancel' => const StatusChip('Cancelled', color: BeatproColors.danger),
    _ => const StatusChip('Quotation', color: Colors.blueGrey),
  };
}

class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final orders = ref.watch(ordersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('My orders'), actions: const [SyncButton()]),
      body: AsyncBody(
        value: orders,
        builder: (list) => list.isEmpty
            ? const EmptyState(icon: Icons.receipt_long_outlined, title: 'No orders yet', message: 'Orders you take appear here.')
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final o = list[i];
                  final customer = ref.watch(customerProvider(o.data['customerKey'] as String)).value;
                  return ListTile(
                    title: Text(customer?.name ?? ''),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(children: [
                        Text('${(o.data['name'] as String?) ?? 'New'} · ${formatDate(o.createdAt)}'),
                        const SizedBox(width: 8),
                        Flexible(child: orderStatus(o)),
                      ]),
                    ),
                    trailing: Text(money(((o.data['amountTotal'] ?? o.data['total']) as num).toDouble()),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    onTap: () => context.push('/orders/${o.uuid}'),
                  );
                },
              ),
      ),
    );
  }
}

final _orderProvider = FutureProvider.family<LocalRecord?, String>((ref, uuid) {
  ref.watch(dataVersionProvider);
  return ref.watch(localDbProvider).record(uuid);
});

class OrderDetailScreen extends ConsumerWidget {
  const OrderDetailScreen({super.key, required this.uuid});

  final String uuid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final theme = Theme.of(context);
    return AsyncBody(
      value: ref.watch(_orderProvider(uuid)),
      builder: (order) {
        if (order == null) return const Scaffold(body: EmptyState(icon: Icons.receipt_long_outlined, title: 'Order not found'));
        final customer = ref.watch(customerProvider(order.data['customerKey'] as String)).value;
        final lines = (order.data['lines'] as List).cast<Map<String, dynamic>>();
        final total = ((order.data['amountTotal'] ?? order.data['total']) as num).toDouble();
        return Scaffold(
          appBar: AppBar(
            title: Text((order.data['name'] as String?) ?? 'New order'),
            actions: [
              if (order.state != SyncState.synced)
                IconButton(
                  tooltip: 'Cancel order',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Cancel this order?'),
                        content: const Text("It hasn't reached Odoo yet, so it's removed from the phone."),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel order')),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    await ref.read(repositoryProvider).cancelOrder(uuid);
                    ref.read(dataVersionProvider.notifier).bump();
                    if (context.mounted) context.pop();
                  },
                ),
            ],
          ),
          body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            ListTile(
              title: Text(customer?.name ?? '', style: theme.textTheme.titleMedium),
              subtitle: Text('${formatDate(order.createdAt)}, ${formatTime(order.createdAt)}'),
              trailing: orderStatus(order),
            ),
            if (order.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(order.error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            Section(
              title: 'Products',
              child: Column(children: [
                for (final l in lines)
                  ListTile(
                    dense: true,
                    title: Text(l['name'] as String),
                    subtitle: Text('${formatQty(l['qty'] as num)} × ${money((l['unitPrice'] as num).toDouble())}'
                        '${(l['discount'] as num) > 0 ? ' · ${formatQty(l['discount'] as num)}% off' : ''}'),
                    trailing: Text(money((l['qty'] as num) * (l['unitPrice'] as num) * (1 - (l['discount'] as num) / 100))),
                  ),
              ]),
            ),
            const Divider(),
            ListTile(
              title: Text('Total', style: theme.textTheme.titleMedium),
              subtitle: Text(order.state == SyncState.synced ? 'As confirmed by Odoo' : 'Estimate until it syncs'),
              trailing: Text(money(total), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if ((order.data['note'] as String?)?.isNotEmpty ?? false)
              Section(title: 'Note', child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(order.data['note'] as String))),
          ]),
        );
      },
    );
  }
}
