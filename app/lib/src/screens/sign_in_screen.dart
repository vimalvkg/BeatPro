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
      await ref
          .read(sessionProvider.notifier)
          .signIn(OdooCredentials(url: _url.text.trim(), database: _database.text.trim(), apiKey: _apiKey.text.trim()));
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
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Maroon band with the brand, as on the Odoo sign-in page.
            Container(
              decoration: const BoxDecoration(gradient: BeatproColors.bandGradient),
              padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 20, 24, 72),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Image.asset('assets/images/logo_light.png', width: 36, height: 36, semanticLabel: 'BeatPro'),
                      const SizedBox(width: 10),
                      const Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'BeatPro ',
                              style: TextStyle(fontWeight: FontWeight.w800),
                            ),
                            TextSpan(
                              text: 'Van Sales',
                              style: TextStyle(fontWeight: FontWeight.w500, color: BeatproColors.onBrand),
                            ),
                          ],
                        ),
                        style: TextStyle(color: Colors.white, fontSize: 20),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Expanded(
                        child: Text(
                          'Drive sales.\nGrow your business.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                      ),
                      Image.asset('assets/images/van.png', width: 120, excludeFromSemantics: true),
                    ],
                  ),
                ],
              ),
            ),
            // The form, on a card over the band.
            Transform.translate(
              offset: const Offset(0, -48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                      child: Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
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
                              decoration: const InputDecoration(
                                labelText: 'Odoo address',
                                hintText: 'https://mycompany.odoo.com',
                              ),
                              validator: (v) {
                                final uri = Uri.tryParse(v?.trim() ?? '');
                                return uri == null || !uri.hasScheme || uri.host.isEmpty
                                    ? 'Enter the address you use to open Odoo.'
                                    : null;
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
                                  ? const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2),
                                        ),
                                        SizedBox(width: 12),
                                        Text('Downloading your customers…'),
                                      ],
                                    )
                                  : const Text('Sign in'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
