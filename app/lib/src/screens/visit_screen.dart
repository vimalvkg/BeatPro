import 'dart:async';
import 'dart:math' as math;

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

/// Metres between two GPS points.
double _distance(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final a = math.pow(math.sin(rad(lat2 - lat1) / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(rad(lon2 - lon1) / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a));
}

String _clock(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

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
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
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
    final money = ref.watch(moneyProvider);
    final visitValue = ref.watch(_visitProvider(widget.visitUuid));
    final orders = ref.watch(ordersProvider).value ?? const <LocalRecord>[];
    final records = ref.watch(recordsProvider).value ?? const <LocalRecord>[];
    final payments =
        records.where((r) => r.kind == RecordKind.payment && r.data['visitUuid'] == widget.visitUuid).toList();
    final returns =
        records.where((r) => r.kind == RecordKind.shopReturn && r.data['visitUuid'] == widget.visitUuid).toList();

    return AsyncBody(
      value: visitValue,
      builder: (visit) {
        if (visit == null) return const Scaffold(body: EmptyState(icon: Icons.error_outline, title: 'Visit not found'));
        final customerKey = visit.data['customerKey'] as String;
        final customer = ref.watch(customerProvider(customerKey)).value;
        final invoices = ref.watch(invoicesProvider(customerKey)).value ?? const <OpenInvoice>[];
        final visitOrders = orders.where((o) => o.data['visitUuid'] == visit.uuid).toList();
        final pastOrders = orders.where((o) => o.data['customerKey'] == customerKey && o.data['visitUuid'] != visit.uuid).toList();
        final inProgress = visit.data['state'] == 'in_progress';
        final checkIn = DateTime.parse(visit.data['checkIn'] as String).toLocal();
        final checkOut = visit.data['checkOut'] == null ? null : DateTime.parse(visit.data['checkOut'] as String).toLocal();
        final elapsed = (checkOut ?? DateTime.now()).difference(checkIn);
        final lat = (visit.data['checkInLat'] as num?)?.toDouble();
        final lng = (visit.data['checkInLng'] as num?)?.toDouble();
        String location = 'No location recorded';
        if (lat != null && lng != null) {
          location = 'Location recorded';
          if (customer?.latitude != null && customer?.longitude != null) {
            final m = _distance(lat, lng, customer!.latitude!, customer.longitude!);
            location += m < 1000 ? ' · ${m.round()} m from the shop pin' : ' · ${(m / 1000).toStringAsFixed(1)} km from the shop pin';
          }
        }
        final due = invoices.fold<double>(0, (s, i) => s + i.amountDue);
        double total(LocalRecord o) => ((o.data['amountTotal'] ?? o.data['total']) as num).toDouble();
        final lastOrder = pastOrders.isEmpty ? null : pastOrders.first;
        final usual = pastOrders.isEmpty ? null : pastOrders.take(5).fold<double>(0, (s, o) => s + total(o)) / pastOrders.take(5).length;
        final result = VisitResult.values.where((r) => r.code == visit.data['result']).firstOrNull;

        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(customer?.name ?? 'Visit'),
              if (customer?.city != null)
                Text(customer!.city!, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: BeatproColors.muted)),
            ]),
          ),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
            // Status panel.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: inProgress ? BeatproColors.bandGradient : null,
                color: inProgress ? null : BeatproColors.ink,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: inProgress ? const Color(0x38F2B233) : const Color(0x402E8B57),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: inProgress ? BeatproColors.amber : const Color(0xFF5FD08F),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        inProgress ? 'Checked in' : 'Visit finished',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: inProgress ? const Color(0xFFFFE3A3) : const Color(0xFFC8F0DA),
                        ),
                      ),
                    ]),
                  ),
                  const Spacer(),
                  Text(
                    inProgress ? 'since ${formatTime(checkIn)}' : (result?.label ?? ''),
                    style: const TextStyle(fontSize: 13, color: BeatproColors.onBrand),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                  Text(_clock(elapsed),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        height: 1,
                        fontFeatures: [FontFeature.tabularFigures()],
                      )),
                  const SizedBox(width: 8),
                  const Text('at the shop', style: TextStyle(color: BeatproColors.onBrand, fontSize: 14)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  const Icon(Icons.location_on_outlined, size: 16, color: BeatproColors.onBrand),
                  const SizedBox(width: 6),
                  Expanded(child: Text(location, style: const TextStyle(color: BeatproColors.onBrand, fontSize: 13))),
                ]),
              ]),
            ),
            const SizedBox(height: 14),
            // Quick actions.
            Row(children: [
              if (inProgress) ...[
                Expanded(
                  child: _Tile(
                    icon: Icons.add_shopping_cart,
                    label: 'Take order',
                    onTap: () => context.push('/order/new?customer=${Uri.encodeComponent(customerKey)}&visit=${visit.uuid}'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: _Tile(
                  icon: Icons.payments_outlined,
                  label: 'Collect payment',
                  warm: true,
                  onTap: () => context.push('/payment/new?customer=${Uri.encodeComponent(customerKey)}&visit=${visit.uuid}'),
                ),
              ),
            ]),
            if (inProgress) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => context.push('/return/new?customer=${Uri.encodeComponent(customerKey)}&visit=${visit.uuid}'),
                icon: const Icon(Icons.undo),
                label: const Text('Take back goods'),
              ),
            ],
            const SizedBox(height: 14),
            // Customer at a glance.
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(children: [
                  Expanded(child: _Fact(label: 'Amount due', value: money(due), color: due > 0 ? BeatproColors.danger : null)),
                  Expanded(
                    child: _Fact(
                      label: 'Last order',
                      value: lastOrder == null ? '—' : '${DateTime.now().difference(lastOrder.createdAt).inDays} days',
                    ),
                  ),
                  Expanded(child: _Fact(label: 'Usual order', value: usual == null ? '—' : money(usual))),
                ]),
              ),
            ),
            const Eyebrow('In this visit', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
            if (visitOrders.isEmpty && payments.isEmpty && returns.isEmpty)
              const Text('No order or payment yet.', style: TextStyle(color: BeatproColors.muted))
            else
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final o in visitOrders)
                    _Item(
                      icon: Icons.receipt_long_outlined,
                      title: 'Order ${(o.data['name'] as String?) ?? ''}'.trim(),
                      subtitle: '${(o.data['lines'] as List).length} products · '
                          '${o.state == SyncState.synced ? (o.data['approval'] == 'waiting' ? 'Waiting for approval' : 'Confirmed') : 'Waiting to sync'}',
                      amount: money(total(o)),
                      onTap: () => context.push('/orders/${o.uuid}'),
                    ),
                  for (final p in payments)
                    _Item(
                      icon: Icons.check,
                      paid: true,
                      title: '${paymentMethodName(p.data)} payment',
                      subtitle: (p.data['invoiceIds'] as List?)?.isNotEmpty ?? false
                          ? 'Settles ${(p.data['invoiceIds'] as List).length} invoice(s)'
                          : 'Advance on account',
                      amount: money((p.data['amount'] as num).toDouble()),
                    ),
                  for (final r in returns)
                    _Item(
                      icon: Icons.undo,
                      title: 'Goods taken back ${(r.data['name'] as String?) ?? ''}'.trim(),
                      subtitle: '${formatQty((r.data['lines'] as List).fold<num>(0, (s, l) => s + ((l as Map)['qty'] as num)))} items · '
                          '${r.state == SyncState.synced ? 'credit note ${r.data['creditNote'] ?? 'made'}' : 'Waiting to sync'}',
                      amount: '− ${money((r.data['total'] as num).toDouble())}',
                    ),
                ]),
              ),
          ]),
          bottomNavigationBar: inProgress
              ? Container(
                  decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: BeatproColors.ink),
                        onPressed: () => _checkOut(visit, visitOrders.isNotEmpty),
                        icon: const Icon(Icons.logout),
                        label: const Text('Check out'),
                      ),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.label, required this.onTap, this.warm = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool warm;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 104,
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: warm ? BeatproColors.amberSoft : BeatproColors.brandSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: warm ? const Color(0xFF8A5A00) : BeatproColors.brand),
              ),
              Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: BeatproColors.muted)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color)),
      ]);
}

class _Item extends StatelessWidget {
  const _Item({required this.icon, required this.title, required this.subtitle, required this.amount, this.paid = false, this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final String amount;
  final bool paid;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: paid ? BeatproColors.successSoft : BeatproColors.brandSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: paid ? BeatproColors.success : BeatproColors.brand),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Text(amount, style: TextStyle(color: paid ? BeatproColors.success : null)),
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
        Row(children: [
          for (final r in VisitResult.values) ...[
            if (r != VisitResult.values.first) const SizedBox(width: 8),
            Expanded(
              child: _Choice(label: r.label, selected: _result == r, onTap: () => setState(() => _result = r)),
            ),
          ],
        ]),
        if (_result == VisitResult.noOrder) ...[
          const Eyebrow('Why no order?', padding: EdgeInsets.fromLTRB(0, 18, 0, 8)),
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

class _Choice extends StatelessWidget {
  const _Choice({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? BeatproColors.brandSoft : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: selected ? BeatproColors.brand : BeatproColors.line, width: selected ? 2 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(
              height: 52,
              child: Center(
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.w700, color: selected ? BeatproColors.brand : BeatproColors.ink)),
              ),
            ),
          ),
        ),
      );
}
