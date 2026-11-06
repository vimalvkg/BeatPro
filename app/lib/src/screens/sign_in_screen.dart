import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/odoo_client.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Sign in with the Odoo login and password (Odoo then gives this phone an
/// API key of its own), or with an API key for users with two-step sign-in.
///
/// With [again], the rep is already signed in and their sign-in expired or
/// was turned off: the work on the phone is kept.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.again = false});

  final bool again;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController(text: 'https://');
  final _database = TextEditingController();
  final _login = TextEditingController();
  final _password = TextEditingController();
  final _apiKey = TextEditingController();
  bool _useKey = false;
  bool _busy = false;
  bool _showSecret = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final current = ref.read(sessionProvider);
    if (widget.again && current != null) {
      _url.text = current.url;
      _database.text = current.database;
      _login.text = current.login ?? '';
      _useKey = current.login == null;
    }
  }

  @override
  void dispose() {
    for (final c in [_url, _database, _login, _password, _apiKey]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionProvider.notifier);
      if (_useKey) {
        await session.signIn(OdooCredentials(
          url: _url.text.trim(),
          database: _database.text.trim(),
          apiKey: _apiKey.text.trim(),
        ));
      } else {
        await session.signInWithPassword(
          url: _url.text.trim(),
          database: _database.text.trim(),
          login: _login.text.trim(),
          password: _password.text,
        );
      }
      _password.clear();
      ref.read(dataVersionProvider.notifier).bump();
      if (widget.again && mounted) {
        showMessage(context, 'Signed in again. Your work on the phone is kept.');
        context.go('/home');
      }
    } catch (e) {
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secretToggle = IconButton(
      tooltip: _showSecret ? 'Hide' : 'Show',
      icon: Icon(_showSecret ? Icons.visibility_off : Icons.visibility),
      onPressed: () => setState(() => _showSecret = !_showSecret),
    );
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Maroon band with the brand, as on the Odoo sign-in page.
          Container(
            decoration: const BoxDecoration(gradient: BeatproColors.bandGradient),
            padding: EdgeInsets.fromLTRB(24, MediaQuery.paddingOf(context).top + 20, 24, 72),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (widget.again)
                  IconButton(
                    tooltip: 'Back',
                    color: Colors.white,
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Image.asset('assets/images/logo_light.png', width: 36, height: 36, semanticLabel: 'BeatPro'),
                const SizedBox(width: 10),
                const Text.rich(
                  TextSpan(children: [
                    TextSpan(text: 'BeatPro ', style: TextStyle(fontWeight: FontWeight.w800)),
                    TextSpan(text: 'Van Sales', style: TextStyle(fontWeight: FontWeight.w500, color: BeatproColors.onBrand)),
                  ]),
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
              ]),
              const SizedBox(height: 24),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                const Expanded(
                  child: Text('Drive sales.\nGrow your business.',
                      style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, height: 1.15)),
                ),
                Image.asset('assets/images/van.png', width: 120, excludeFromSemantics: true),
              ]),
            ]),
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
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                    child: Form(
                      key: _form,
                      child: AutofillGroup(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Text(widget.again ? 'Sign in again' : "Sign in to your company's Odoo",
                              style: theme.textTheme.titleLarge),
                          const SizedBox(height: 6),
                          Text(
                            widget.again
                                ? 'Your work on this phone is kept.'
                                : 'Use the same email and password as in Odoo.',
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _url,
                            keyboardType: TextInputType.url,
                            autocorrect: false,
                            enabled: !widget.again,
                            decoration: const InputDecoration(labelText: 'Odoo address', hintText: 'https://mycompany.odoo.com'),
                            validator: (v) {
                              final uri = Uri.tryParse(v?.trim() ?? '');
                              return uri == null || !uri.hasScheme || uri.host.isEmpty
                                  ? 'Enter the address you use to open Odoo.'
                                  : null;
                            },
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _database,
                            autocorrect: false,
                            enabled: !widget.again,
                            decoration: const InputDecoration(
                              labelText: 'Database (optional)',
                              helperText: 'Only needed if your server has more than one database.',
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (_useKey)
                            TextFormField(
                              controller: _apiKey,
                              autocorrect: false,
                              obscureText: !_showSecret,
                              decoration: InputDecoration(
                                labelText: 'API key',
                                helperText: 'In Odoo: your profile > Security > New API Key.',
                                suffixIcon: secretToggle,
                              ),
                              validator: (v) => (v ?? '').trim().length < 20 ? 'Paste the API key from Odoo.' : null,
                              onFieldSubmitted: (_) => _signIn(),
                            )
                          else ...[
                            TextFormField(
                              controller: _login,
                              keyboardType: TextInputType.emailAddress,
                              autocorrect: false,
                              autofillHints: const [AutofillHints.username, AutofillHints.email],
                              decoration: const InputDecoration(labelText: 'Email or username'),
                              validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your Odoo email or username.' : null,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _password,
                              obscureText: !_showSecret,
                              autocorrect: false,
                              autofillHints: const [AutofillHints.password],
                              decoration: InputDecoration(labelText: 'Password', suffixIcon: secretToggle),
                              validator: (v) => (v ?? '').isEmpty ? 'Enter your password.' : null,
                              onFieldSubmitted: (_) => _signIn(),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _busy ? null : _signIn,
                            child: _busy
                                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                                    SizedBox(width: 12),
                                    Text('Signing in…'),
                                  ])
                                : const Text('Sign in'),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                      _useKey = !_useKey;
                                      _error = null;
                                    }),
                            child: Text(_useKey ? 'Sign in with email and password' : 'Two-step sign-in? Use an API key'),
                          ),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
