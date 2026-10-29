import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/odoo_client.dart';
import '../providers.dart';
import '../theme.dart';

/// Shows a short message at the bottom of the screen.
void showMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      behavior: SnackBarBehavior.floating,
    ));
}

/// Turns an exception into words for the rep.
String describeError(Object e) {
  if (e is OdooException || e is OfflineException) return e.toString();
  if (e is ArgumentError) return e.message.toString();
  if (e is StateError) return e.message;
  return 'Something went wrong: $e';
}

/// Shows the value of an [AsyncValue], a spinner while loading and the error otherwise.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder});

  final AsyncValue<T> value;
  final Widget Function(T data) builder;

  @override
  Widget build(BuildContext context) => value.when(
        data: builder,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(padding: const EdgeInsets.all(24), child: Text(describeError(e), textAlign: TextAlign.center)),
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant), textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ]),
      ),
    );
  }
}

/// A small coloured label, for statuses.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, {super.key, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Where a record made on the phone stands with Odoo.
class SyncStateChip extends StatelessWidget {
  const SyncStateChip(this.record, {super.key});

  final LocalRecord record;

  @override
  Widget build(BuildContext context) => switch (record.state) {
        SyncState.synced => const StatusChip('Synced', color: BeatproColors.success, icon: Icons.cloud_done_outlined),
        SyncState.pending => const StatusChip('Waiting to sync', color: BeatproColors.warning, icon: Icons.cloud_upload_outlined),
        SyncState.failed => const StatusChip('Not synced', color: BeatproColors.danger, icon: Icons.error_outline),
      };
}

/// A titled block on a screen.
class Section extends StatelessWidget {
  const Section({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(children: [
            Expanded(
              child: Text(title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        letterSpacing: 0.8,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      )),
            ),
            ?trailing,
          ]),
        ),
        child,
      ]);
}

/// Label above a big number, for summaries.
class Figure extends StatelessWidget {
  const Figure({super.key, required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      Text(value,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          )),
    ]);
  }
}

/// Cloud icon in the app bar: shows how many records wait for Odoo and syncs on tap.
class SyncButton extends ConsumerWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingCountProvider).value ?? 0;
    final running = ref.watch(syncControllerProvider).isLoading;
    return IconButton(
      tooltip: pending == 0 ? 'Sync with Odoo' : '$pending waiting to sync',
      onPressed: running
          ? null
          : () async {
              final report = await ref.read(syncControllerProvider.notifier).run();
              if (!context.mounted) return;
              if (report == null) {
                final error = ref.read(syncControllerProvider).error;
                if (error != null) showMessage(context, describeError(error), error: true);
              } else if (report.offlineMessage != null) {
                showMessage(context, report.offlineMessage!, error: true);
              } else if (report.failed > 0) {
                showMessage(context, '${report.failed} not synced. Open Sync to see why.', error: true);
              } else {
                showMessage(context, 'Synced with Odoo');
              }
            },
      icon: running
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: const Icon(Icons.cloud_sync_outlined),
            ),
    );
  }
}
