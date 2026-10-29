import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/odoo_client.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController(text: 'https://');
  final _database = TextEditingController();
  final _apiKey = TextEditingController();
  bool _busy = false;
  bool _showKey = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _database.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).signIn(OdooCredentials(
            url: _url.text.trim(),
            database: _database.text.trim(),
            apiKey: _apiKey.text.trim(),
          ));
      ref.read(dataVersionProvider.notifier).bump();
    } catch (e) {
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(color: BeatproColors.navy, borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.route, color: BeatproColors.amber, size: 30),
                    ),
                    const SizedBox(width: 12),
                    Text('BeatPro', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 24),
                  Text('Connect to your company\'s Odoo', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    'Get an API key in Odoo: your profile > Security > New API Key.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Odoo address', hintText: 'https://mycompany.odoo.com'),
                    validator: (v) {
                      final uri = Uri.tryParse(v?.trim() ?? '');
                      return uri == null || !uri.hasScheme || uri.host.isEmpty ? 'Enter the address you use to open Odoo.' : null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _database,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Database (optional)',
                      helperText: 'Only needed if your server has more than one database.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _apiKey,
                    autocorrect: false,
                    obscureText: !_showKey,
                    decoration: InputDecoration(
                      labelText: 'API key',
                      suffixIcon: IconButton(
                        tooltip: _showKey ? 'Hide key' : 'Show key',
                        icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ),
                    validator: (v) => (v ?? '').trim().length < 20 ? 'Paste the API key from Odoo.' : null,
                    onFieldSubmitted: (_) => _signIn(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _signIn,
                    child: _busy
                        ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 12),
                            Text('Downloading your customers…'),
                          ])
                        : const Text('Sign in'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
