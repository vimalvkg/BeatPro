import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'home_screen.dart';

class RouteScreen extends ConsumerWidget {
  const RouteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(todayPlanProvider);
    return Scaffold(
      appBar: AppBar(title: const Text("Today's route"), actions: const [SyncButton()]),
      body: AsyncBody(
        value: plan,
        builder: (stops) {
          if (stops.isEmpty) {
            return const EmptyState(
              icon: Icons.route,
              title: 'Nothing planned for today',
              message: 'Your supervisor sets your routes in Odoo. Sync to get the latest plan.',
            );
          }
          final done = stops.where((s) => s.visited).length;
          final next = stops.where((s) => s.visit == null).firstOrNull;
          return RefreshIndicator(
            onRefresh: () => ref.read(syncControllerProvider.notifier).run(),
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Text(
                  '$done of ${stops.length} visited · ${{for (final s in stops) s.stop.routeName}.join(', ')}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: BeatproColors.muted),
                ),
              ),
              for (final (i, view) in stops.indexed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: StopCard(view: view, number: i + 1, isNext: identical(view, next)),
                ),
            ]),
          );
        },
      ),
    );
  }
}
