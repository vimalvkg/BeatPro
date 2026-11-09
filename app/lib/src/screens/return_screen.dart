import 'dart:async';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../core/models.dart';
import '../core/repository.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/scanner.dart';
import 'van_screens.dart';

/// Goods a shop gives back, with a reason. Goods that can be sold again go
/// back into the van; damaged and expired goods go to the damaged stock area.
class ShopReturnScreen extends ConsumerStatefulWidget {
  const ShopReturnScreen({super.key, required this.customerKey, this.visitUuid});

  final String customerKey;
  final String? visitUuid;

  @override
  ConsumerState<ShopReturnScreen> createState() => _ShopReturnScreenState();
}

class _ShopReturnScreenState extends ConsumerState<ShopReturnScreen> {
  List<ReturnCandidate> _candidates = [];
  List<Product> _products = [];
  List<ReturnReason> _reasons = ReturnReason.defaults;
  final List<ReturnLine> _lines = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final candidates = await repo.returnCandidates(widget.customerKey);
    final products = await repo.db.products();
    if (mounted) {
      setState(() {
        _candidates = candidates;
        _products = products;
      });
    }
  }

  Future<void> _add(List<ReturnReason> reasons) async {
    final taken = {for (final l in _lines) l.productId};
    final picked = await pickFrom<ReturnCandidate>(
      context,
      _candidates.where((c) => !taken.contains(c.productId)).toList(),
      (c) => c.name,
      sub: (c) => c.lastDate == null ? 'Not bought lately' : 'Bought on ${_date(c.lastDate!)}',
    );
    if (picked == null) return;
    setState(() => _lines.add(ReturnLine(
          productId: picked.productId,
          name: picked.name,
          priceUnit: picked.priceUnit,
          lastDate: picked.lastDate,
          reason: reasons.first,
        )));
  }

  /// A scanned barcode: one more of that product taken back (reason: the first one, change it on the card).
  ScanFeedback _scanned(String code) {
    final p = productForCode(_products, code);
    if (p == null) return ScanFeedback('No product with barcode $code. Sync to update the products.', ok: false);
    final line = _lines.where((l) => l.productId == p.id).firstOrNull;
    if (line != null) {
      setState(() => line.qty += 1);
      return ScanFeedback('${p.name} · ${formatQty(line.qty)} taken back');
    }
    final c = _candidates.where((c) => c.productId == p.id).firstOrNull;
    setState(() => _lines.add(ReturnLine(
          productId: p.id,
          name: p.name,
          priceUnit: c?.priceUnit ?? p.listPrice,
          lastDate: c?.lastDate,
          reason: _reasons.first,
        )));
    return ScanFeedback('Added ${p.name} · choose the reason on its card');
  }

  static String _date(String iso) => DateFormat('d MMM').format(DateTime.parse(iso));

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).takeBack(
            customerKey: widget.customerKey,
            visitUuid: widget.visitUuid,
            lines: _lines,
          );
      ref.read(dataVersionProvider.notifier).bump();
      if (widget.visitUuid == null) unawaited(ref.read(syncControllerProvider.notifier).run());
      if (mounted) {
        showMessage(context, 'Goods taken back. The shop gets a credit note.');
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
    final reasons = ref.watch(appContextProvider).value?.returnReasons ?? ReturnReason.defaults;
    _reasons = reasons;
    final hasVan = ref.watch(appContextProvider).value?.van != null;
    final count = _lines.fold(0.0, (s, l) => s + l.qty);
    final credit = _lines.fold(0.0, (s, l) => s + l.subtotal);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), tooltip: tr('Close'), onPressed: () => context.pop()),
        actions: [ScanButton(title: 'Scan goods taken back', onCode: _scanned)],
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Take back goods'),
          Text(customer?.name ?? '', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
        for (final line in _lines) ...[
          _ReturnCard(
            line: line,
            reasons: reasons,
            hasVan: hasVan,
            money: money,
            boughtOn: line.lastDate == null ? null : _date(line.lastDate!),
            onChanged: () => setState(() {
              if (line.qty <= 0) _lines.remove(line);
            }),
          ),
          const SizedBox(height: 12),
        ],
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: () => _add(reasons),
          child: const Text('+ Add product'),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('Credit for the shop', style: TextStyle(color: BeatproColors.muted)),
                const Spacer(),
                Text(money(credit), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              ]),
              const SizedBox(height: 6),
              Text('A credit note reduces what ${customer?.name ?? 'the shop'} owes. Odoo checks it before it counts.',
                  style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
            ]),
          ),
        ),
      ]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _saving || _lines.isEmpty ? null : _save,
              child: Text(_lines.isEmpty ? 'Take back goods' : 'Take back ${formatQty(count)} items · ${money(credit)} credit'),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReturnCard extends StatelessWidget {
  const _ReturnCard({
    required this.line,
    required this.reasons,
    required this.hasVan,
    required this.money,
    required this.onChanged,
    this.boughtOn,
  });

  final ReturnLine line;
  final List<ReturnReason> reasons;
  final bool hasVan;
  final Money money;
  final String? boughtOn;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final resell = line.reason.resellable;
    final goes = resell
        ? (hasVan ? 'Goes back into the van, can be sold again' : 'Goes back into stock, can be sold again')
        : 'Goes to the damaged stock area${hasVan ? ', not back into the van' : ''}';
    final color = resell ? BeatproColors.success : BeatproColors.danger;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(line.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text(
                  [if (boughtOn != null) 'Bought on $boughtOn', '${money(line.priceUnit)} each'].join(' · '),
                  style: const TextStyle(fontSize: 12, color: BeatproColors.muted),
                ),
              ]),
            ),
            QtyStepper(
              qty: line.qty,
              onChanged: (q) {
                line.qty = q < 0 ? 0 : q;
                onChanged();
              },
            ),
          ]),
          const SizedBox(height: 10),
          Semantics(
            label: 'Reason',
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in reasons)
                ChoiceChip(
                  label: Text(r.label),
                  selected: r.value == line.reason.value,
                  showCheckmark: false,
                  selectedColor: BeatproColors.brandSoft,
                  side: BorderSide(
                    color: r.value == line.reason.value ? BeatproColors.brand : BeatproColors.line,
                    width: r.value == line.reason.value ? 2 : 1,
                  ),
                  shape: const StadiumBorder(),
                  onSelected: (_) {
                    line.reason = r;
                    onChanged();
                  },
                ),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(goes, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color))),
          ]),
        ]),
      ),
    );
  }
}
