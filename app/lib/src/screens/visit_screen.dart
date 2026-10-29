import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _visitProvider = FutureProvider.family<LocalRecord?, String>((ref, uuid) {
  ref.watch(dataVersionProvider);
  return ref.watch(localDbProvider).record(uuid);
});

class VisitScreen extends ConsumerStatefulWidget {
  const VisitScreen({super.key, required this.visitUuid});

  final String visitUuid;

  @override
  ConsumerState<VisitScreen> createState() => _VisitScreenState();
}

class _VisitScreenState extends ConsumerState<VisitScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _checkOut(LocalRecord visit, bool hasOrder) async {
    final choice = await showModalBottomSheet<(VisitResult, String?, String?)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CheckOutSheet(hasOrder: hasOrder),
    );
    if (choice == null) return;
    try {
      final at = await ref.read(locationProvider).current();
      await ref.read(repositoryProvider).checkOut(
            visit.uuid,
            result: choice.$1,
            noOrderReason: choice.$2,
            note: choice.$3,
            at: at,
          );
      ref.read(dataVersionProvider.notifier).bump();
      // Upload straight away when there's signal; otherwise it waits on the phone.
      unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) {
        showMessage(context, 'Checked out');
        context.pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyProvider);
    final visitValue = ref.watch(_visitProvider(widget.visitUuid));
    final orders = ref.watch(ordersProvider).value ?? const <LocalRecord>[];
    final payments = (ref.watch(recordsProvider).value ?? const <LocalRecord>[])
        .where((r) => r.kind == RecordKind.payment && r.data['visitUuid'] == widget.visitUuid)
        .toList();

    return AsyncBody(
      value: visitValue,
      builder: (visit) {
        if (visit == null) return const Scaffold(body: EmptyState(icon: Icons.error_outline, title: 'Visit not found'));
        final customerKey = visit.data['customerKey'] as String;
        final customer = ref.watch(customerProvider(customerKey)).value;
        final visitOrders = orders.where((o) => o.data['visitUuid'] == visit.uuid).toList();
        final inProgress = visit.data['state'] == 'in_progress';
        final checkIn = DateTime.parse(visit.data['checkIn'] as String).toLocal();
        final minutes = DateTime.now().difference(checkIn).inMinutes;
        final hasLocation = visit.data['checkInLat'] != null;

        return Scaffold(
          appBar: AppBar(title: Text(customer?.name ?? 'Visit')),
          body: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                color: inProgress ? BeatproColors.amber.withValues(alpha: 0.15) : null,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Icon(inProgress ? Icons.timer_outlined : Icons.check_circle,
                        color: inProgress ? BeatproColors.warning : BeatproColors.success),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(inProgress ? 'Checked in at ${formatTime(checkIn)}' : 'Visit finished',
                            style: theme.textTheme.titleMedium),
                        Text(
                          inProgress
                              ? '$minutes min at the shop · ${hasLocation ? 'location recorded' : 'no location'}'
                              : (VisitResult.values.where((r) => r.code == visit.data['result']).firstOrNull?.label ?? ''),
                          style: theme.textTheme.bodySmall,
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
            ),
            if (inProgress)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Row(children: [
                  Expanded(
                    child: _BigAction(
                      icon: Icons.add_shopping_cart,
                      label: 'Take order',
                      onTap: () => context.push(
                          '/order/new?customer=${Uri.encodeComponent(customerKey)}&visit=${visit.uuid}'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _BigAction(
                      icon: Icons.payments_outlined,
                      label: 'Collect payment',
                      onTap: () => context.push(
                          '/payment/new?customer=${Uri.encodeComponent(customerKey)}&visit=${visit.uuid}'),
                    ),
                  ),
                ]),
              ),
            Section(
              title: 'Orders in this visit',
              child: visitOrders.isEmpty
                  ? const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('No order yet.'))
                  : Column(children: [
                      for (final o in visitOrders)
                        ListTile(
                          title: Text((o.data['name'] as String?) ?? 'New order'),
                          subtitle: Text('${(o.data['lines'] as List).length} products'),
                          trailing: Text(money(((o.data['amountTotal'] ?? o.data['total']) as num).toDouble()),
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          onTap: () => context.push('/orders/${o.uuid}'),
                        ),
                    ]),
            ),
            Section(
              title: 'Payments in this visit',
              child: payments.isEmpty
                  ? const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('No payment collected yet.'))
                  : Column(children: [
                      for (final p in payments)
                        ListTile(
                          title: Text(paymentMethods[p.data['method']] ?? ''),
                          trailing: Text(money((p.data['amount'] as num).toDouble()),
                              style: const TextStyle(fontWeight: FontWeight.w600, color: BeatproColors.success)),
                        ),
                    ]),
            ),
          ]),
          bottomNavigationBar: inProgress
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: FilledButton.icon(
                      onPressed: () => _checkOut(visit, visitOrders.isNotEmpty),
                      icon: const Icon(Icons.logout),
                      label: const Text('Check out'),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }
}

class _BigAction extends StatelessWidget {
  const _BigAction({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(children: [
              Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(label, style: Theme.of(context).textTheme.titleSmall),
            ]),
          ),
        ),
      );
}

class _CheckOutSheet extends StatefulWidget {
  const _CheckOutSheet({required this.hasOrder});

  final bool hasOrder;

  @override
  State<_CheckOutSheet> createState() => _CheckOutSheetState();
}

class _CheckOutSheetState extends State<_CheckOutSheet> {
  late VisitResult _result = widget.hasOrder ? VisitResult.order : VisitResult.noOrder;
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _result != VisitResult.noOrder || _reason != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('How did the visit go?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        SegmentedButton<VisitResult>(
          segments: [
            for (final r in VisitResult.values) ButtonSegment(value: r, label: Text(r.label)),
          ],
          selected: {_result},
          onSelectionChanged: (s) => setState(() => _result = s.first),
        ),
        if (_result == VisitResult.noOrder) ...[
          const SizedBox(height: 16),
          Text('Why no order?', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in noOrderReasons.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _reason == e.key,
                onSelected: (_) => setState(() => _reason = e.key),
              ),
          ]),
        ],
        const SizedBox(height: 16),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)'), maxLines: 2),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: canSave ? () => Navigator.pop(context, (_result, _reason, _note.text.trim().isEmpty ? null : _note.text.trim())) : null,
            child: const Text('Check out'),
          ),
        ),
      ]),
    );
  }
}
