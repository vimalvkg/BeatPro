import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class CustomerDetailScreen extends ConsumerStatefulWidget {
  const CustomerDetailScreen({super.key, required this.customerKey, this.routeId});

  final String customerKey;
  final int? routeId;

  @override
  ConsumerState<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends ConsumerState<CustomerDetailScreen> {
  bool _starting = false;

  Future<void> _checkIn() async {
    setState(() => _starting = true);
    try {
      final at = await ref.read(locationProvider).current();
      final visit = await ref.read(repositoryProvider).startVisit(widget.customerKey, routeId: widget.routeId, at: at);
      ref.read(dataVersionProvider.notifier).bump();
      if (!mounted) return;
      if (at == null) showMessage(context, "Location isn't available, so the visit is saved without it.");
      context.pushReplacement('/visit/${visit.uuid}');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyProvider);
    final customer = ref.watch(customerProvider(widget.customerKey));
    final invoices = ref.watch(invoicesProvider(widget.customerKey)).value ?? const <OpenInvoice>[];
    final orders = (ref.watch(ordersProvider).value ?? const <LocalRecord>[])
        .where((o) => o.data['customerKey'] == widget.customerKey)
        .take(5)
        .toList();
    final due = invoices.fold<double>(0, (s, i) => s + i.amountDue);
    final overdue = invoices.where((i) => i.overdue).fold<double>(0, (s, i) => s + i.amountDue);

    return Scaffold(
      appBar: AppBar(title: const Text('Customer')),
      body: AsyncBody(
        value: customer,
        builder: (c) {
          if (c == null) return const EmptyState(icon: Icons.storefront_outlined, title: 'Customer not found');
          return ListView(padding: const EdgeInsets.only(bottom: 120), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                if (c.street != null || c.city != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text([c.street, c.city].whereType<String>().join(', '), style: theme.textTheme.bodyMedium),
                  ),
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  if (c.phone != null)
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(Uri(scheme: 'tel', path: c.phone)),
                      icon: const Icon(Icons.call_outlined),
                      label: const Text('Call'),
                    ),
                  if (c.latitude != null)
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${c.latitude},${c.longitude}'),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.directions_outlined),
                      label: const Text('Directions'),
                    ),
                ]),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Expanded(child: Figure(label: 'Amount due', value: money(due))),
                    Expanded(
                      child: Figure(
                        label: 'Overdue',
                        value: money(overdue),
                        color: overdue > 0 ? BeatproColors.danger : null,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            if (invoices.isNotEmpty)
              Section(
                title: 'Open invoices',
                child: Column(children: [
                  for (final i in invoices)
                    ListTile(
                      dense: true,
                      title: Text(i.name),
                      subtitle: Text(i.dueDate == null ? '' : 'Due ${i.dueDate}'),
                      trailing: Text(money(i.amountDue),
                          style: TextStyle(fontWeight: FontWeight.w600, color: i.overdue ? BeatproColors.danger : null)),
                    ),
                ]),
              ),
            Section(
              title: 'Recent orders',
              child: orders.isEmpty
                  ? const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 0), child: Text('No orders taken on this phone yet.'))
                  : Column(children: [
                      for (final o in orders)
                        ListTile(
                          dense: true,
                          title: Text((o.data['name'] as String?) ?? 'New order'),
                          subtitle: Text('${(o.data['lines'] as List).length} products'),
                          trailing: Text(money(((o.data['amountTotal'] ?? o.data['total']) as num).toDouble())),
                          onTap: () => context.push('/orders/${o.uuid}'),
                        ),
                    ]),
            ),
          ]);
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => context.push('/order/new?customer=${Uri.encodeComponent(widget.customerKey)}'),
                child: const Text('Phone order'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _starting ? null : _checkIn,
                icon: _starting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: const Text('Check in'),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
