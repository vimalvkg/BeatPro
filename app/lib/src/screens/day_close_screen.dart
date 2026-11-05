import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/repository.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class DayCloseScreen extends ConsumerStatefulWidget {
  const DayCloseScreen({super.key});

  @override
  ConsumerState<DayCloseScreen> createState() => _DayCloseScreenState();
}

class _DayCloseScreenState extends ConsumerState<DayCloseScreen> {
  final _distance = TextEditingController();
  final _note = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _distance.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).closeDay(
            distanceKm: double.tryParse(_distance.text.trim()) ?? 0,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      ref.read(dataVersionProvider.notifier).bump();
      unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) showMessage(context, 'Day closed. It reaches your supervisor when it syncs.');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final summary = ref.watch(daySummaryProvider);
    final closed = ref.watch(todayCloseProvider).value;
    final appContext = ref.watch(appContextProvider).value;
    final repo = ref.watch(repositoryProvider);
    final today = (ref.watch(recordsProvider).value ?? const <LocalRecord>[])
        .where((r) => !r.createdAt.toLocal().isBefore(repo.startOfToday))
        .toList();
    final cheques = today.where((r) => r.kind == RecordKind.payment && paymentKind(r.data) == 'cheque').length;
    final visits = today.where((r) => r.kind == RecordKind.visit && r.data['state'] == 'done').toList().reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Close the day'),
          Text('${appContext?.userName ?? ''} · ${formatDate(DateTime.now())}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: BeatproColors.muted)),
        ]),
      ),
      body: AsyncBody<DaySummary>(
        value: summary,
        builder: (s) {
          final cash = s.collected['cash'] ?? 0;
          final cheque = s.collected['cheque'] ?? 0;
          final bank = s.collected['bank'] ?? 0;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 140), children: [
            if (closed != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  color: BeatproColors.successSoft,
                  child: ListTile(
                    leading: const Icon(Icons.lock_outline, color: BeatproColors.success),
                    title: const Text('Today is closed'),
                    trailing: SyncStateChip(closed),
                  ),
                ),
              ),
            // What to hand in.
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: BeatproColors.ink, borderRadius: BorderRadius.circular(18)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Hand in to the office', style: TextStyle(color: BeatproColors.onNavy, fontSize: 13, fontWeight: FontWeight.w700)),
                Text(money(cash + cheque),
                    style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w800, height: 1.15)),
                const SizedBox(height: 12),
                const Divider(color: Color(0x29FFFFFF), height: 1),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _HandInPart(label: 'Cash', amount: money(cash))),
                  Expanded(child: _HandInPart(label: 'Cheque', amount: money(cheque), note: '$cheques ${cheques == 1 ? 'cheque' : 'cheques'}')),
                  Expanded(child: _HandInPart(label: 'Bank and UPI', amount: money(bank), note: 'already in bank')),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _StatTile(label: 'Visits', value: '${s.visitsDone} / ${s.planned}')),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(label: 'Orders', value: '${s.orderCount}')),
              const SizedBox(width: 10),
              Expanded(child: _StatTile(label: 'Value', value: money(s.orderValue))),
            ]),
            if (visits.isNotEmpty) ...[
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, v) in visits.indexed) ...[
                    if (i > 0) const Divider(height: 1, color: BeatproColors.lineSoft),
                    _VisitRecap(visit: v, today: today),
                  ],
                ]),
              ),
            ],
            if (closed == null) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _distance,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Distance travelled', suffixText: 'km'),
              ),
              const SizedBox(height: 12),
              TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note for your supervisor (optional)')),
            ],
          ]);
        },
      ),
      bottomNavigationBar: closed != null
          ? null
          : Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    FilledButton(
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                      onPressed: _saving ? null : _close,
                      child: const Text('Close day and send to supervisor'),
                    ),
                    const SizedBox(height: 6),
                    const Text("After closing, only your supervisor can change today's figures.",
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: BeatproColors.muted)),
                  ]),
                ),
              ),
            ),
    );
  }
}

class _HandInPart extends StatelessWidget {
  const _HandInPart({required this.label, required this.amount, this.note});

  final String label;
  final String amount;
  final String? note;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: BeatproColors.onNavy, fontSize: 12, fontWeight: FontWeight.w700)),
        Text(amount, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
        if (note != null) Text(note!, style: const TextStyle(color: BeatproColors.onNavy, fontSize: 12)),
      ]);
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: SmallFigure(label: label, value: value)),
        ),
      );
}

class _VisitRecap extends ConsumerWidget {
  const _VisitRecap({required this.visit, required this.today});

  final LocalRecord visit;
  final List<LocalRecord> today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final customer = ref.watch(customerProvider(visit.data['customerKey'] as String)).value;
    final orders = today.where((r) => r.kind == RecordKind.order && r.data['visitUuid'] == visit.uuid);
    final payments = today.where((r) => r.kind == RecordKind.payment && r.data['visitUuid'] == visit.uuid);
    final value = orders.fold<double>(0, (s, o) => s + ((o.data['amountTotal'] ?? o.data['total']) as num).toDouble());
    final result = visit.data['result'] as String?;
    final parts = <String>[
      if (result == 'order') 'Order' else if (result == 'closed') 'Shop closed' else 'No order',
      if (result == 'no_order' && visit.data['noOrderReason'] != null) noOrderReasons[visit.data['noOrderReason']]!.toLowerCase(),
      for (final p in payments) '${paymentMethodName(p.data)} ${money((p.data['amount'] as num).toDouble())}',
    ];
    return ListTile(
      leading: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: result == 'order' ? BeatproColors.successDot : const Color(0xFFE3A21A),
          shape: BoxShape.circle,
        ),
      ),
      minLeadingWidth: 10,
      title: Text(customer?.name ?? ''),
      subtitle: Text(parts.join(' · ')),
      trailing: Text(value > 0 ? money(value) : '—'),
    );
  }
}
