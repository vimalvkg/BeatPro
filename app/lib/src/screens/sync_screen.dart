import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _kindLabels = {
  RecordKind.customer: 'New customer',
  RecordKind.visit: 'Visit',
  RecordKind.order: 'Order',
  RecordKind.payment: 'Payment',
  RecordKind.dayClose: 'Day-end close',
};

class SyncScreen extends ConsumerWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final money = ref.watch(moneyProvider);
    final sync = ref.watch(syncControllerProvider);
    final lastSync = ref.watch(lastSyncProvider).value;
    final records = ref.watch(recordsProvider).value ?? const <LocalRecord>[];
    final waiting = records.where((r) => r.state != SyncState.synced).toList();
    final report = sync.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
        ListTile(
          leading: Icon(waiting.isEmpty ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              color: waiting.isEmpty ? BeatproColors.success : BeatproColors.warning, size: 32),
          title: Text(waiting.isEmpty ? 'Everything is in Odoo' : '${waiting.length} waiting to sync',
              style: theme.textTheme.titleMedium),
          subtitle: Text(lastSync == null ? 'Not synced yet' : 'Last synced ${formatDate(lastSync)}, ${formatTime(lastSync)}'),
        ),
        if (sync.hasError)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(describeError(sync.error!), style: TextStyle(color: theme.colorScheme.error)),
          )
        else if (report?.offlineMessage != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(report!.offlineMessage!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        if (waiting.isNotEmpty)
          Section(
            title: 'Waiting',
            child: Column(children: [
              for (final r in waiting)
                ListTile(
                  title: Text(_kindLabels[r.kind]!),
                  subtitle: Text(r.error ??
                      (r.kind == RecordKind.visit && r.data['state'] == 'in_progress'
                          ? 'Syncs after you check out'
                          : '${formatDate(r.createdAt)}, ${formatTime(r.createdAt)}')),
                  trailing: r.kind == RecordKind.order || r.kind == RecordKind.payment
                      ? Text(money(((r.data['total'] ?? r.data['amount']) as num).toDouble()))
                      : SyncStateChip(r),
                  isThreeLine: r.error != null,
                ),
            ]),
          ),
        Section(
          title: 'Synced today',
          child: Column(children: [
            for (final r in records.where((r) =>
                r.state == SyncState.synced && r.createdAt.isAfter(DateTime.now().subtract(const Duration(hours: 24)))))
              ListTile(
                dense: true,
                leading: const Icon(Icons.check, color: BeatproColors.success),
                title: Text(_kindLabels[r.kind]!),
                subtitle: Text((r.data['name'] as String?) ?? formatTime(r.createdAt)),
              ),
          ]),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: sync.isLoading ? null : () => ref.read(syncControllerProvider.notifier).run(),
            icon: sync.isLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            label: Text(sync.isLoading ? 'Syncing…' : 'Sync now'),
          ),
        ),
      ),
    );
  }
}
