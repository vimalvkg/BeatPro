import 'dart:async';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/invoice.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

IconData _iconFor(PaymentMethod m) {
  if (m.kind == 'cash') return Icons.payments_outlined;
  if (m.kind == 'cheque') return Icons.edit_note;
  if (m.name.toLowerCase().contains('upi')) return Icons.swap_horiz;
  return Icons.account_balance_outlined;
}

class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key, required this.customerKey, this.visitUuid, this.settle, this.settleName});

  final String customerKey;
  final String? visitUuid;

  /// An invoice to tick from the start ([OpenInvoice.key]), e.g. the one just printed.
  final String? settle;

  /// The same invoice by number, once it is in Odoo.
  final String? settleName;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  final _amount = TextEditingController();
  final _chequeNumber = TextEditingController();
  final _reference = TextEditingController();
  final Set<String> _selected = {};
  bool _preselected = false;
  PaymentMethod? _method;
  DateTime? _chequeDate;
  bool _saving = false;
  bool _online = false;

  // Online payment
  int? _onlineInvoice;
  bool _linkLoading = false;
  Map<String, dynamic>? _link;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _chequeNumber.dispose();
    _reference.dispose();
    super.dispose();
  }

  double get _amountValue => double.tryParse(_amount.text.replaceAll(',', '').trim()) ?? 0;

  String _plain(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  /// Invoices ticked, less the credit notes ticked: what the shop pays in money.
  double _toPay(List<OpenInvoice> all) {
    final sum = all.where((i) => _selected.contains(i.key)).fold<double>(0, (s, i) => s + i.amountDue);
    return sum < 0 ? 0 : ShopInvoice.round2(sum);
  }

  void _toggle(OpenInvoice invoice, List<OpenInvoice> all) {
    setState(() {
      _selected.contains(invoice.key) ? _selected.remove(invoice.key) : _selected.add(invoice.key);
      final pay = _toPay(all);
      _amount.text = pay == 0 ? '' : _plain(pay);
    });
  }

  List<OpenInvoice> _items = const [];

  Future<void> _save(PaymentMethod method) async {
    setState(() => _saving = true);
    try {
      String two(int v) => v.toString().padLeft(2, '0');
      await ref.read(repositoryProvider).collectPayment(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            amount: _amountValue,
            method: method,
            settles: _items.where((i) => _selected.contains(i.key)).toList(),
            chequeNumber: method.reference == 'cheque' ? _chequeNumber.text.trim() : null,
            chequeDate: method.reference == 'cheque' && _chequeDate != null
                ? '${_chequeDate!.year}-${two(_chequeDate!.month)}-${two(_chequeDate!.day)}'
                : null,
            reference: method.reference == 'reference' && _reference.text.trim().isNotEmpty ? _reference.text.trim() : null,
          );
      ref.read(dataVersionProvider.notifier).bump();
      if (widget.visitUuid == null) unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) {
        showMessage(context, 'Payment recorded');
        context.pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _makeLink(OpenInvoice invoice) async {
    final sync = ref.read(syncServiceProvider);
    if (sync == null) return;
    setState(() {
      _linkLoading = true;
      _link = null;
    });
    try {
      final amount = _amountValue > 0 && _amountValue < invoice.amountDue ? _amountValue : null;
      final link = await sync.paymentLink(invoice.id, amount: amount);
      if (mounted) setState(() => _link = link);
    } catch (e) {
      if (mounted) showMessage(context, 'Pay online needs signal. ${describeError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _linkLoading = false);
    }
  }

  Future<void> _checkPaid(int invoiceId) async {
    final sync = ref.read(syncServiceProvider);
    if (sync == null) return;
    setState(() => _checking = true);
    try {
      final paid = await sync.invoicePaid(invoiceId);
      if (!mounted) return;
      if (paid) {
        showMessage(context, 'Paid online. Odoo has marked the invoice paid.');
        await ref.read(syncControllerProvider.notifier).run();
        if (mounted) context.pop();
      } else {
        showMessage(context, 'Not paid yet. Ask the customer to finish paying, then check again.');
      }
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final appContext = ref.watch(appContextProvider).value;
    final methods = appContext?.paymentMethods ?? PaymentMethod.legacy;
    final providers = appContext?.onlineProviders ?? const <String>[];
    final method = _method ?? (methods.isEmpty ? null : methods.first);
    final customer = ref.watch(customerProvider(widget.customerKey)).value;
    final items = ref.watch(openItemsProvider(widget.customerKey)).value ?? const <OpenInvoice>[];
    _items = items;
    final preselect = items
        .where((i) => i.key == widget.settle || (widget.settleName != null && !i.creditNote && i.name == widget.settleName))
        .firstOrNull;
    if (!_preselected && preselect != null) {
      _preselected = true;
      _selected.add(preselect.key);
      final pay = _toPay(items);
      WidgetsBinding.instance.addPostFrameCallback((_) => _amount.text = pay == 0 ? '' : _plain(pay));
    }
    // Online payment works on Odoo's invoices only.
    final invoices = items.where((i) => !i.onPhone && !i.creditNote).toList();
    final due = items.fold<double>(0, (s, i) => s + i.amountDue);
    final invoiceTotal = items.where((i) => !i.creditNote).fold<double>(0, (s, i) => s + i.amountDue);
    final credits = items.where((i) => _selected.contains(i.key) && i.creditNote).fold<double>(0, (s, i) => s - i.amountDue);
    final invoicesPicked = items.any((i) => _selected.contains(i.key) && !i.creditNote);
    final left = (invoiceTotal - _amountValue - (invoicesPicked ? credits : 0)).clamp(0, double.infinity).toDouble();
    final creditOnly = _amountValue <= 0 && credits > 0 && invoicesPicked;
    final symbol = appContext?.currencySymbol ?? '';
    final online = _online && providers.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: tr('Close'), onPressed: () => context.pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Collect payment'),
          Text(customer?.name ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: BeatproColors.muted)),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
        if (providers.isNotEmpty) ...[
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Received now'), icon: Icon(Icons.payments_outlined)),
              ButtonSegment(value: true, label: Text('Pay online'), icon: Icon(Icons.qr_code_2)),
            ],
            selected: {online},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _online = s.first),
          ),
          const SizedBox(height: 16),
        ],
        // The amount, big.
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(children: [
              Text(online ? 'Amount to pay online' : 'Amount collected',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: BeatproColors.muted)),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(symbol, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: BeatproColors.muted)),
                const SizedBox(width: 4),
                IntrinsicWidth(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 60, maxWidth: 260),
                    child: TextField(
                      controller: _amount,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: BeatproColors.ink),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        hintText: '0',
                        isDense: true,
                      ),
                    ),
                  ),
                ),
              ]),
              Text(
                due <= 0
                    ? (due < 0 ? 'The shop has ${money(-due)} credit · kept as an advance' : 'No unpaid invoices · kept as an advance')
                    : credits > 0 && invoicesPicked
                        ? '${money(credits)} credit used · ${money(left)} left after this'
                        : 'of ${money(invoiceTotal)} due · ${money(left)} left after this',
                style: const TextStyle(fontSize: 13, color: BeatproColors.muted),
              ),
            ]),
          ),
        ),
        if (online)
          ..._onlinePart(money, invoices, providers)
        else ...[
          const Eyebrow('Paid by', padding: EdgeInsets.fromLTRB(0, 18, 0, 8)),
          if (methods.isEmpty)
            const Text('No payment methods are set up for reps. Ask your administrator.', style: TextStyle(color: BeatproColors.danger))
          else
            LayoutBuilder(builder: (context, box) {
              final width = (box.maxWidth - 16) / 3;
              return Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in methods)
                  SizedBox(
                    width: width,
                    child: _MethodTile(method: m, selected: identical(m, method) || m.id != null && m.id == method?.id,
                        onTap: () => setState(() => _method = m)),
                  ),
              ]);
            }),
          if (method?.reference == 'reference') ...[
            const SizedBox(height: 16),
            TextField(controller: _reference, decoration: InputDecoration(labelText: tr('${method!.name} reference (optional)'))),
          ],
          if (method?.reference == 'cheque') ...[
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _chequeNumber,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr('Cheque number')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56), backgroundColor: Colors.white),
                  icon: const Icon(Icons.event),
                  label: Text(_chequeDate == null ? 'Cheque date' : MaterialLocalizations.of(context).formatShortDate(_chequeDate!)),
                  onPressed: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: now,
                      firstDate: now.subtract(const Duration(days: 90)),
                      lastDate: now.add(const Duration(days: 180)),
                    );
                    if (picked != null) setState(() => _chequeDate = picked);
                  },
                ),
              ),
            ]),
          ],
          const Eyebrow('Settles invoices', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
          if (items.isEmpty)
            const Text("Nothing unpaid. The payment is kept as an advance on the customer's account.",
                style: TextStyle(color: BeatproColors.muted))
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final (index, i) in items.indexed) ...[
                  if (index > 0) const Divider(height: 1, color: BeatproColors.lineSoft),
                  CheckboxListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selected.contains(i.key),
                    onChanged: (_) => _toggle(i, items),
                    title: Text(i.name),
                    subtitle: Text(
                      i.creditNote
                          ? 'Credit note · use it against an invoice${i.onPhone ? ' · not synced yet' : ''}'
                          : i.onPhone
                              ? 'Printed at the shop · not synced yet'
                              : (i.dueDate == null ? '' : '${i.overdue ? 'Overdue since' : 'Due'} ${i.dueDate}'),
                      style: TextStyle(
                        color: i.creditNote ? BeatproColors.success : (i.overdue ? BeatproColors.danger : null),
                        fontWeight: i.overdue || i.creditNote ? FontWeight.w600 : null,
                      ),
                    ),
                    secondary: Text(i.creditNote ? '− ${money(-i.amountDue)}' : money(i.amountDue),
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800, color: i.creditNote ? BeatproColors.success : null)),
                  ),
                ],
              ]),
            ),
        ],
      ]),
      bottomNavigationBar: online || method == null
          ? null
          : Container(
              decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: FilledButton(
                    onPressed: _saving ? null : () => _save(method),
                    child: Text(creditOnly
                        ? 'Use ${money(credits)} credit'
                        : _amountValue > 0
                            ? 'Record ${money(_amountValue)} by ${method.name}'
                            : 'Record payment'),
                  ),
                ),
              ),
            ),
    );
  }

  List<Widget> _onlinePart(Money money, List<OpenInvoice> invoices, List<String> providers) {
    if (invoices.isEmpty) {
      return const [
        SizedBox(height: 16),
        Text('Online payment is for unpaid invoices. This customer has none.', style: TextStyle(color: BeatproColors.muted)),
      ];
    }
    final chosen = invoices.where((i) => i.id == _onlineInvoice).firstOrNull;
    return [
      const Eyebrow('Invoice to pay', padding: EdgeInsets.fromLTRB(0, 18, 0, 8)),
      Card(
        clipBehavior: Clip.antiAlias,
        child: RadioGroup<int>(
          groupValue: _onlineInvoice,
          onChanged: (v) => setState(() {
            _onlineInvoice = v;
            _link = null;
            final inv = invoices.firstWhere((i) => i.id == v);
            _amount.text = _plain(inv.amountDue);
          }),
          child: Column(children: [
            for (final (index, i) in invoices.indexed) ...[
              if (index > 0) const Divider(height: 1, color: BeatproColors.lineSoft),
              RadioListTile<int>(
                value: i.id,
                title: Text(i.name),
                subtitle: Text(i.dueDate == null ? '' : '${i.overdue ? 'Overdue since' : 'Due'} ${i.dueDate}',
                    style: TextStyle(color: i.overdue ? BeatproColors.danger : null)),
                secondary: Text(money(i.amountDue), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              ),
            ],
          ]),
        ),
      ),
      const SizedBox(height: 16),
      if (_link == null)
        FilledButton.icon(
          onPressed: chosen == null || _linkLoading ? null : () => _makeLink(chosen),
          icon: _linkLoading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.qr_code_2),
          label: Text(chosen == null ? 'Choose an invoice' : 'Show QR code'),
        )
      else
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Text('Scan to pay ${_link!['invoice']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(money((_link!['amount'] as num).toDouble()),
                  style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: BeatproColors.brand)),
              const SizedBox(height: 12),
              QrImageView(
                data: _link!['link'] as String,
                size: 220,
                backgroundColor: Colors.white,
                semanticsLabel: 'QR code to pay ${_link!['invoice']} online',
              ),
              const SizedBox(height: 8),
              Text('Pay with ${providers.join(', ')}', style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
              if (_link!['warning'] is String)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_link!['warning'] as String, style: const TextStyle(fontSize: 13, color: BeatproColors.danger)),
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => SharePlus.instance.share(ShareParams(
                      text: 'Pay ${_link!['invoice']} online: ${_link!['link']}',
                      subject: 'Payment link for ${_link!['invoice']}',
                    )),
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share link'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 14, fontWeight: FontWeight.w800),
                    ),
                    onPressed: _checking ? null : () => _checkPaid(chosen!.id),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Check payment'),
                  ),
                ),
              ]),
            ]),
          ),
        ),
    ];
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({required this.method, required this.selected, required this.onTap});

  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? BeatproColors.brandSoft : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: selected ? BeatproColors.brand : BeatproColors.line, width: selected ? 2 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(
              height: 64,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(_iconFor(method), size: 20, color: selected ? BeatproColors.brand : BeatproColors.ink),
                const SizedBox(height: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(method.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w800, color: selected ? BeatproColors.brand : BeatproColors.ink)),
                ),
              ]),
            ),
          ),
        ),
      );
}
