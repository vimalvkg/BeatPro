import 'dart:async';
import 'dart:typed_data';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

const paidFromOptions = [
  ('cash', 'Cash collected today', 'Taken off the cash you hand in tonight'),
  ('own', 'My own money', 'Paid back to you once approved'),
  ('card', 'Company card', 'Nothing to hand in or pay back'),
];

String paidFromLabel(String? code) => switch (code) {
      'cash' => 'cash collected',
      'own' => 'my own money',
      'card' => 'company card',
      _ => '',
    };

/// Fuel, parking, Salik and the rest, with an optional receipt photo.
class AddExpenseScreen extends ConsumerStatefulWidget {
  const AddExpenseScreen({super.key});

  @override
  ConsumerState<AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends ConsumerState<AddExpenseScreen> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  int? _category;
  String _paidFrom = 'cash';
  Uint8List? _receipt;
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _photo() async {
    final bytes = await ref.read(photoServiceProvider).take();
    if (bytes != null && mounted) setState(() => _receipt = bytes);
  }

  Future<void> _save(List<(int, String)> categories) async {
    final category = categories.where((c) => c.$1 == _category).firstOrNull;
    if (category == null) {
      showMessage(context, 'Choose what the expense is for.', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).addExpense(
            categoryId: category.$1,
            categoryName: category.$2,
            amount: double.tryParse(_amount.text.replaceAll(',', '').trim()) ?? 0,
            paidFrom: _paidFrom,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            receipt: _receipt,
            dir: _receipt == null ? null : await ref.read(photoDirProvider.future),
          );
      ref.read(dataVersionProvider.notifier).bump();
      unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) {
        showMessage(context, 'Expense saved. Your supervisor approves it in Odoo.');
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
    final appContext = ref.watch(appContextProvider).value;
    final categories = appContext?.expenseCategories ?? const <(int, String)>[];
    final currency = appContext?.currencyCode ?? '';
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Add expense'),
          Text('Today · ${appContext?.userName ?? ''}', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Eyebrow('What for', padding: EdgeInsets.fromLTRB(0, 0, 0, 8)),
        if (categories.isEmpty)
          const Text('Sync to get the expense types from Odoo.', style: TextStyle(color: BeatproColors.muted))
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (id, name) in categories)
              ChoiceChip(label: Text(name), selected: _category == id, onSelected: (_) => setState(() => _category = id)),
          ]),
        const SizedBox(height: 16),
        TextField(
          controller: _amount,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          decoration: InputDecoration(labelText: tr('Amount'), prefixText: '$currency '),
        ),
        const SizedBox(height: 12),
        TextField(controller: _note, decoration: InputDecoration(labelText: tr('Where (optional)'), hintText: tr('e.g. ENOC Al Quoz'))),
        const Eyebrow('Paid from', padding: EdgeInsets.fromLTRB(0, 18, 0, 8)),
        for (final (code, title, text) in paidFromOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => setState(() => _paidFrom = code),
              child: Semantics(
                selected: _paidFrom == code,
                inMutuallyExclusiveGroup: true,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _paidFrom == code ? BeatproColors.brand : BeatproColors.line, width: _paidFrom == code ? 2 : 1),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text(text, style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
                  ]),
                ),
              ),
            ),
          ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _photo,
          icon: Icon(_receipt == null ? Icons.receipt_long_outlined : Icons.check_circle, color: _receipt == null ? null : BeatproColors.success),
          label: Text(_receipt == null ? 'Receipt photo (optional)' : 'Receipt photo taken · retake'),
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _saving ? null : () => _save(categories),
            child: const Text('Save expense'),
          ),
        ),
      ),
    );
  }
}

/// The rep's expenses with their approval.
class MyExpensesScreen extends ConsumerWidget {
  const MyExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final expenses = ref.watch(myExpensesProvider).value ?? const <Map<String, dynamic>>[];
    double sum(bool Function(Map<String, dynamic>) test) =>
        expenses.where(test).fold<double>(0, (s, e) => s + (e['amount'] as num).toDouble());
    final waiting = sum((e) => e['state'] == 'waiting');
    final payBack = sum((e) => e['state'] == 'approved' && e['paid_from'] == 'own');
    return Scaffold(
      appBar: AppBar(title: const Text('My expenses')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(12), child: SmallFigure(label: 'Waiting', value: money(waiting))))),
          const SizedBox(width: 8),
          Expanded(
            child: Card(
              child: Padding(padding: const EdgeInsets.all(12), child: SmallFigure(label: 'To be paid back to you', value: money(payBack))),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (expenses.isEmpty)
          const EmptyState(icon: Icons.receipt_long_outlined, title: 'No expenses', message: 'Add fuel, parking or Salik when you pay for them.')
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              for (final (i, e) in expenses.indexed) ...[
                if (i > 0) const Divider(height: 1, color: BeatproColors.lineSoft),
                ListTile(
                  title: Text(e['category'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([e['date'], paidFromLabel(e['paid_from'] as String?), if (e['note'] is String) e['note']].join(' · ')),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(money((e['amount'] as num).toDouble()), style: const TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    _ExpenseState(e),
                  ]),
                ),
              ],
            ]),
          ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => context.push('/expense/new'),
            icon: const Icon(Icons.add),
            label: const Text('Add expense'),
          ),
        ),
      ),
    );
  }
}

class _ExpenseState extends StatelessWidget {
  const _ExpenseState(this.expense);

  final Map<String, dynamic> expense;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (expense['state']) {
      'approved' => ('Approved', BeatproColors.success),
      'rejected' => (expense['reject_reason'] is String ? 'Rejected · ${expense['reject_reason']}' : 'Rejected', BeatproColors.danger),
      _ => (expense['on_phone'] == true ? 'Not synced yet' : 'Waiting', BeatproColors.warning),
    };
    return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: StatusChip(label, color: color));
  }
}
