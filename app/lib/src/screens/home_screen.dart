import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/repository.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// My Day: progress, the next shop and today's route.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final appContext = ref.watch(appContextProvider).value;
    final summary = ref.watch(daySummaryProvider).value;
    final plan = ref.watch(todayPlanProvider).value ?? const <StopView>[];
    final lastSync = ref.watch(lastSyncProvider).value;
    final pending = ref.watch(pendingCountProvider).value ?? 0;

    final current = plan.where((s) => s.inProgress).firstOrNull;
    final upcoming = plan.where((s) => s.visit == null).firstOrNull;
    final next = current ?? upcoming;
    final routeNames = {for (final s in plan) s.stop.routeName}.join(', ');
    final name = appContext?.userName ?? '';
    final initials = name.split(' ').where((p) => p.isNotEmpty).take(2).map((p) => p[0]).join().toUpperCase();
    final done = summary?.visitsDone ?? 0;
    final planned = summary?.planned ?? plan.length;
    final left = plan.where((s) => !s.visited).length;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncControllerProvider.notifier).run(),
        child: ListView(padding: EdgeInsets.zero, children: [
          // Blue band with the day's title.
          Container(
            color: BeatproColors.navy,
            padding: EdgeInsets.fromLTRB(16, MediaQuery.paddingOf(context).top + 14, 8, 64),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('My Day', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  Text(
                    [DateFormat.EEEE().format(DateTime.now()), if (routeNames.isNotEmpty) routeNames].join(' · '),
                    style: const TextStyle(color: BeatproColors.onNavy, fontSize: 13),
                  ),
                ]),
              ),
              IconTheme(data: const IconThemeData(color: Colors.white), child: const SyncButton()),
              Container(
                width: 36,
                height: 36,
                margin: const EdgeInsets.only(left: 4, right: 8),
                decoration: const BoxDecoration(color: BeatproColors.amber, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(initials, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: BeatproColors.ink)),
              ),
            ]),
          ),
          // Summary card over the band.
          Transform.translate(
            offset: const Offset(0, -50),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Color(0x1A10243A), blurRadius: 18, offset: Offset(0, 6))],
                ),
                child: Row(children: [
                  ProgressRing(done: done, total: planned),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: SmallFigure(label: 'Orders', value: money(summary?.orderValue ?? 0))),
                        Expanded(
                          child: SmallFigure(
                            label: 'Collected',
                            value: money(summary?.totalCollected ?? 0),
                            color: BeatproColors.success,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      Text(
                        planned == 0
                            ? 'Nothing planned for today'
                            : left == 0
                                ? 'Every shop visited. Close the day when you\'re done.'
                                : '$left ${left == 1 ? 'shop' : 'shops'} left today',
                        style: const TextStyle(fontSize: 13, color: BeatproColors.muted),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
          Transform.translate(
            offset: const Offset(0, -50),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (next != null) ...[
                Eyebrow(current != null ? 'Now' : 'Next', padding: const EdgeInsets.fromLTRB(16, 18, 16, 8)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _NextCard(view: next, number: plan.indexOf(next) + 1, isCurrent: current != null),
                ),
              ],
              if (plan.isNotEmpty) ...[
                const Eyebrow("Today's route"),
                for (final (i, view) in plan.indexed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: StopCard(view: view, number: i + 1, isNext: identical(view, next) && current == null),
                  ),
              ] else
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: EmptyState(
                    icon: Icons.route,
                    title: 'Nothing planned for today',
                    message: 'Your supervisor sets your routes in Odoo. Pull down to sync.',
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/customers/new'),
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('New shop'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/day-close'),
                      icon: const Icon(Icons.nightlight_outlined),
                      label: const Text('Close the day'),
                    ),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Card(
                  child: ListTile(
                    leading: Icon(pending == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
                        color: pending == 0 ? BeatproColors.success : BeatproColors.warning),
                    title: Text(pending == 0 ? 'Everything is in Odoo' : '$pending waiting to sync'),
                    subtitle: Text(lastSync == null ? 'Not synced yet' : 'Last synced ${formatTime(lastSync)}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => context.push('/sync'),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _NextCard extends ConsumerWidget {
  const _NextCard({required this.view, required this.number, required this.isCurrent});

  final StopView view;
  final int number;
  final bool isCurrent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final customer = view.customer;
    final due = (ref.watch(invoicesProvider(customer.key)).value ?? const []).fold<double>(0, (s, i) => s + i.amountDue);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BeatproColors.navy, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          NumberMarker(number: number, current: true, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(customer.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              if (customer.city != null) Text(customer.city!, style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
            ]),
          ),
          if (due > 0) Pill('${money(due)} due', background: BeatproColors.dangerSoft, foreground: BeatproColors.danger),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: () => isCurrent
                  ? context.push('/visit/${view.visit!.uuid}')
                  : context.push('/customer/${Uri.encodeComponent(customer.key)}?route=${view.stop.routeId}'),
              icon: const Icon(Icons.location_on_outlined),
              label: Text(isCurrent ? 'Open visit' : 'Start visit'),
            ),
          ),
          if (customer.latitude != null) ...[
            const SizedBox(width: 8),
            _SquareButton(
              icon: Icons.near_me_outlined,
              label: 'Directions',
              onTap: () => launchUrl(
                Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${customer.latitude},${customer.longitude}'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
          if (customer.phone != null) ...[
            const SizedBox(width: 8),
            _SquareButton(icon: Icons.call_outlined, label: 'Call', onTap: () => launchUrl(Uri(scheme: 'tel', path: customer.phone))),
          ],
        ]),
      ]),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 52,
        height: 52,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(52, 52)),
          child: Icon(icon, color: BeatproColors.navy, semanticLabel: label),
        ),
      );
}

/// One shop on today's route.
class StopCard extends ConsumerWidget {
  const StopCard({super.key, required this.view, required this.number, this.isNext = false});

  final StopView view;
  final int number;
  final bool isNext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customer = view.customer;
    final (label, bg, fg) = view.visited
        ? ('Visited', BeatproColors.successSoft, BeatproColors.success)
        : view.inProgress
            ? ('In progress', BeatproColors.amberSoft, BeatproColors.amberInk)
            : isNext
                ? ('Next', BeatproColors.blueSoft, BeatproColors.navy)
                : ('To visit', BeatproColors.lineSoft, const Color(0xFF4A5A6B));
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: BeatproColors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => view.visit != null && !view.visited
            ? context.push('/visit/${view.visit!.uuid}')
            : context.push('/customer/${Uri.encodeComponent(customer.key)}?route=${view.stop.routeId}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            NumberMarker(number: number, done: view.visited, current: isNext || view.inProgress),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(customer.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                if (customer.city != null) Text(customer.city!, style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
              ]),
            ),
            Pill(label, background: bg, foreground: fg),
          ]),
        ),
      ),
    );
  }
}

/// A rounded status label with explicit colours.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, required this.background, required this.foreground});

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: foreground)),
      );
}
