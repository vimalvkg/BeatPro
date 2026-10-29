import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

class PaymentScreen extends ConsumerStatefulWidget {
  const PaymentScreen({super.key, required this.customerKey, this.visitUuid});

  final String customerKey;
  final String? visitUuid;

  @override
  ConsumerState<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends ConsumerState<PaymentScreen> {
  final _amount = TextEditingController();
  final _chequeNumber = TextEditingController();
  final _upiReference = TextEditingController();
  final Set<int> _selected = {};
  String _method = 'cash';
  DateTime? _chequeDate;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _chequeNumber.dispose();
    _upiReference.dispose();
    super.dispose();
  }

  void _toggle(OpenInvoice invoice, List<OpenInvoice> all) {
    setState(() {
      _selected.contains(invoice.id) ? _selected.remove(invoice.id) : _selected.add(invoice.id);
      final sum = all.where((i) => _selected.contains(i.id)).fold<double>(0, (s, i) => s + i.amountDue);
      _amount.text = sum == 0 ? '' : sum.toStringAsFixed(2);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      String two(int v) => v.toString().padLeft(2, '0');
      await ref.read(repositoryProvider).collectPayment(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            amount: double.tryParse(_amount.text.replaceAll(',', '').trim()) ?? 0,
            method: _method,
            invoiceIds: _selected.toList(),
            chequeNumber: _method == 'cheque' ? _chequeNumber.text.trim() : null,
            chequeDate: _method == 'cheque' && _chequeDate != null
                ? '${_chequeDate!.year}-${two(_chequeDate!.month)}-${two(_chequeDate!.day)}'
                : null,
            upiReference: _method == 'upi' && _upiReference.text.trim().isNotEmpty ? _upiReference.text.trim() : null,
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

  @override
  Widget build(BuildContext context) {
    final money = ref.watch(moneyProvider);
    final theme = Theme.of(context);
    final customer = ref.watch(customerProvider(widget.customerKey)).value;
    final invoices = ref.watch(invoicesProvider(widget.customerKey)).value ?? const <OpenInvoice>[];

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Collect payment'),
          Text(customer?.name ?? '', style: theme.textTheme.bodySmall),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
        Section(
          title: 'Invoices this settles',
          child: invoices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('No unpaid invoices. The payment is kept as an advance on the customer\'s account.'),
                )
              : Column(children: [
                  for (final i in invoices)
                    CheckboxListTile(
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _selected.contains(i.id),
                      onChanged: (_) => _toggle(i, invoices),
                      title: Text(i.name),
                      subtitle: Text(i.dueDate == null ? '' : '${i.overdue ? 'Overdue since' : 'Due'} ${i.dueDate}',
                          style: TextStyle(color: i.overdue ? BeatproColors.danger : null)),
                      secondary: Text(money(i.amountDue), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                ]),
        ),
        Section(
          title: 'Payment',
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SegmentedButton<String>(
                segments: [for (final e in paymentMethods.entries) ButtonSegment(value: e.key, label: Text(e.value))],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.first),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: theme.textTheme.headlineSmall,
                decoration: InputDecoration(
                  labelText: 'Amount collected',
                  prefixText: '${ref.watch(appContextProvider).value?.currencySymbol ?? ''} ',
                ),
              ),
              if (_method == 'cheque') ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _chequeNumber,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Cheque number'),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event),
                  title: Text(_chequeDate == null
                      ? 'Cheque date'
                      : MaterialLocalizations.of(context).formatMediumDate(_chequeDate!)),
                  onTap: () async {
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
              ],
              if (_method == 'upi') ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _upiReference,
                  decoration: const InputDecoration(labelText: 'UPI transaction ID (optional)'),
                ),
              ],
            ]),
          ),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Record payment')),
        ),
      ),
    );
  }
}
