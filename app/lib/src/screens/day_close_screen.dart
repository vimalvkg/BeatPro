import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
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
    final theme = Theme.of(context);
    final money = ref.watch(moneyProvider);
    final summary = ref.watch(daySummaryProvider);
    final closed = ref.watch(todayCloseProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Close the day')),
      body: AsyncBody(
        value: summary,
        builder: (s) => ListView(padding: const EdgeInsets.only(bottom: 120), children: [
          if (closed != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Card(
                color: BeatproColors.success.withValues(alpha: 0.12),
                child: ListTile(
                  leading: const Icon(Icons.lock_outline, color: BeatproColors.success),
                  title: const Text('Today is closed'),
                  trailing: SyncStateChip(closed),
                ),
              ),
            ),
          Section(
            title: 'Visits',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(child: Figure(label: 'Done', value: '${s.visitsDone} of ${s.planned}')),
                Expanded(child: Figure(label: 'With order', value: '${s.visitsWithOrder}')),
                Expanded(child: Figure(label: 'Missed', value: '${(s.planned - s.visitsDone).clamp(0, s.planned)}')),
              ]),
            ),
          ),
          Section(
            title: 'Orders',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Expanded(child: Figure(label: 'Orders', value: '${s.orderCount}')),
                Expanded(flex: 2, child: Figure(label: 'Value', value: money(s.orderValue))),
              ]),
            ),
          ),
          Section(
            title: 'Collections',
            child: Column(children: [
              for (final e in paymentMethods.entries)
                ListTile(dense: true, title: Text(e.value), trailing: Text(money(s.collected[e.key] ?? 0))),
              ListTile(
                title: Text('Total to hand in', style: theme.textTheme.titleMedium),
                trailing: Text(money(s.totalCollected),
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: BeatproColors.success)),
              ),
            ]),
          ),
          if (closed == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(children: [
                TextField(
                  controller: _distance,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Distance travelled', suffixText: 'km'),
                ),
                const SizedBox(height: 12),
                TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note for your supervisor (optional)')),
              ]),
            ),
        ]),
      ),
      bottomNavigationBar: closed != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(onPressed: _saving ? null : _close, child: const Text('Close day')),
              ),
            ),
    );
  }
}
