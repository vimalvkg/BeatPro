import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/common.dart';

class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(customerSearchProvider(_search));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
        actions: const [SyncButton()],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search customers',
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v.trim()),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/customers/new'),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('New customer'),
      ),
      body: AsyncBody(
        value: customers,
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.storefront_outlined,
                title: _search.isEmpty ? 'No customers yet' : 'No customer matches "$_search"',
                message: _search.isEmpty ? 'Customers on your routes appear here after a sync.' : null,
              )
            : ListView.separated(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                itemBuilder: (context, i) {
                  final c = list[i];
                  return ListTile(
                    leading: CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name[0].toUpperCase())),
                    title: Text(c.name),
                    subtitle: Text([c.city, c.phone].whereType<String>().join(' · ')),
                    trailing: c.isLocal && c.serverId == null ? const Icon(Icons.cloud_upload_outlined, size: 18) : null,
                    onTap: () => context.push('/customer/${Uri.encodeComponent(c.key)}'),
                  );
                },
              ),
      ),
    );
  }
}
