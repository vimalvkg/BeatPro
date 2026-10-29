import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/repository.dart';
import '../providers.dart';
import '../widgets/common.dart';

class AddCustomerScreen extends ConsumerStatefulWidget {
  const AddCustomerScreen({super.key});

  @override
  ConsumerState<AddCustomerScreen> createState() => _AddCustomerScreenState();
}

class _AddCustomerScreenState extends ConsumerState<AddCustomerScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _street = TextEditingController();
  final _city = TextEditingController();
  GeoPoint? _location;
  bool _locating = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ref.read(locationProvider).current().then((p) {
      if (mounted) {
        setState(() {
          _location = p;
          _locating = false;
        });
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _street, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      String? text(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
      final customer = await ref.read(repositoryProvider).addCustomer(
            name: _name.text,
            phone: text(_phone),
            street: text(_street),
            city: text(_city),
            at: _location,
          );
      ref.read(dataVersionProvider.notifier).bump();
      if (!mounted) return;
      showMessage(context, '${customer.name} added. It reaches Odoo at the next sync.');
      context.pushReplacement('/customer/${Uri.encodeComponent(customer.key)}');
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New customer')),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Shop name'),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Enter the shop name.' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _street,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Address'),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _city,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Area or city'),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(_location == null ? Icons.location_off_outlined : Icons.location_on_outlined),
            title: Text(_locating
                ? 'Getting the shop location…'
                : _location == null
                    ? "Location isn't available"
                    : 'Shop location saved'),
            subtitle: _location == null
                ? const Text('Stand at the shop with location turned on to pin it.')
                : Text('${_location!.latitude.toStringAsFixed(5)}, ${_location!.longitude.toStringAsFixed(5)}'),
          ),
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save customer')),
        ),
      ),
    );
  }
}
