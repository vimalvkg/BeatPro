import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/common.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appContext = ref.watch(appContextProvider).value;
    final session = ref.watch(sessionProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('More')),
      body: ListView(children: [
        ListTile(
          leading: CircleAvatar(child: Text((appContext?.userName ?? '?')[0])),
          title: Text(appContext?.userName ?? ''),
          subtitle: Text(appContext?.companyName ?? ''),
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.cloud_sync_outlined),
          title: const Text('Sync'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/sync'),
        ),
        ListTile(
          leading: const Icon(Icons.nightlight_outlined),
          title: const Text('Close the day'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/day-close'),
        ),
        ListTile(
          leading: const Icon(Icons.person_add_alt),
          title: const Text('New customer'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push('/customers/new'),
        ),
        Section(
          title: 'Account',
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Odoo'),
              subtitle: Text([session?.url, session?.database].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
            ),
            ListTile(
              leading: const Icon(Icons.percent),
              title: const Text('Your discount limit'),
              trailing: Text('${appContext?.discountLimit.toStringAsFixed(0) ?? 0}%'),
            ),
            if (appContext?.isSupervisor ?? false)
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('Supervisor'),
                subtitle: const Text('Approve discounts and reopen closed days in Odoo'),
              ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () async {
                final pending = await ref.read(pendingCountProvider.future);
                if (!context.mounted) return;
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Sign out?'),
                    content: Text(pending == 0
                        ? 'The data on this phone is removed. Everything is already in Odoo.'
                        : '$pending records haven\'t reached Odoo yet and will be lost. Sync first if you can.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay signed in')),
                      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
                    ],
                  ),
                );
                if (ok == true) {
                  await ref.read(sessionProvider.notifier).signOut();
                  ref.read(dataVersionProvider.notifier).bump();
                }
              },
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('BeatPro 1.0.0', textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}
