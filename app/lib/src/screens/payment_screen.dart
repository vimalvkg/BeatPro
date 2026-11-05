import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/models.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _methodIcons = {'cash': Icons.currency_rupee, 'upi': Icons.swap_horiz, 'cheque': Icons.edit_note};
const _methodOrder = ['cash', 'upi', 'cheque'];

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
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _chequeNumber.dispose();
    _upiReference.dispose();
    super.dispose();
  }

  double get _amountValue => double.tryParse(_amount.text.replaceAll(',', '').trim()) ?? 0;

  void _toggle(OpenInvoice invoice, List<OpenInvoice> all) {
    setState(() {
      _selected.contains(invoice.id) ? _selected.remove(invoice.id) : _selected.add(invoice.id);
      final sum = all.where((i) => _selected.contains(i.id)).fold<double>(0, (s, i) => s + i.amountDue);
      _amount.text = sum == 0 ? '' : (sum == sum.roundToDouble() ? sum.toInt().toString() : sum.toStringAsFixed(2));
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      String two(int v) => v.toString().padLeft(2, '0');
      await ref.read(repositoryProvider).collectPayment(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            amount: _amountValue,
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
    final customer = ref.watch(customerProvider(widget.customerKey)).value;
    final invoices = ref.watch(invoicesProvider(widget.customerKey)).value ?? const <OpenInvoice>[];
    final due = invoices.fold<double>(0, (s, i) => s + i.amountDue);
    final left = (due - _amountValue).clamp(0, double.infinity).toDouble();
    final symbol = ref.watch(appContextProvider).value?.currencySymbol ?? '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: 'Close', onPressed: () => context.pop()),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Collect payment'),
          Text(customer?.name ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: BeatproColors.muted)),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
        // The amount, big.
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Column(children: [
              const Text('Amount collected', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: BeatproColors.muted)),
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
                due == 0 ? 'No unpaid invoices · kept as an advance' : 'of ${money(due)} due · ${money(left)} left after this',
                style: const TextStyle(fontSize: 13, color: BeatproColors.muted),
              ),
            ]),
          ),
        ),
        const Eyebrow('Paid by', padding: EdgeInsets.fromLTRB(0, 18, 0, 8)),
        Row(children: [
          for (final m in _methodOrder) ...[
            if (m != _methodOrder.first) const SizedBox(width: 8),
            Expanded(child: _MethodTile(method: m, selected: _method == m, onTap: () => setState(() => _method = m))),
          ],
        ]),
        if (_method == 'upi') ...[
          const SizedBox(height: 16),
          TextField(controller: _upiReference, decoration: const InputDecoration(labelText: 'UPI transaction ID (optional)')),
        ],
        if (_method == 'cheque') ...[
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _chequeNumber,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Cheque number'),
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
        if (invoices.isEmpty)
          const Text("No unpaid invoices. The payment is kept as an advance on the customer's account.",
              style: TextStyle(color: BeatproColors.muted))
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (final (index, i) in invoices.indexed) ...[
                if (index > 0) const Divider(height: 1, color: BeatproColors.lineSoft),
                CheckboxListTile(
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _selected.contains(i.id),
                  onChanged: (_) => _toggle(i, invoices),
                  title: Text(i.name),
                  subtitle: Text(
                    i.dueDate == null ? '' : '${i.overdue ? 'Overdue since' : 'Due'} ${i.dueDate}',
                    style: TextStyle(color: i.overdue ? BeatproColors.danger : null, fontWeight: i.overdue ? FontWeight.w600 : null),
                  ),
                  secondary: Text(money(i.amountDue), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                ),
              ],
            ]),
          ),
      ]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_amountValue > 0 ? 'Record ${money(_amountValue)} by ${paymentMethods[_method]}' : 'Record payment'),
            ),
          ),
        ),
      ),
    );
  }
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({required this.method, required this.selected, required this.onTap});

  final String method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? BeatproColors.blueSoft : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: selected ? BeatproColors.navy : BeatproColors.line, width: selected ? 2 : 1),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: SizedBox(
              height: 64,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(_methodIcons[method], size: 20, color: selected ? BeatproColors.navy : BeatproColors.ink),
                const SizedBox(height: 2),
                Text(paymentMethods[method]!,
                    style: TextStyle(fontWeight: FontWeight.w800, color: selected ? BeatproColors.navy : BeatproColors.ink)),
              ]),
            ),
          ),
        ),
      );
}
