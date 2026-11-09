import 'dart:io';

import '../l10n/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/growth.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../providers.dart';
import '../theme.dart';
import '../widgets/common.dart';

Widget _bar(double pct, {Color? color, double height = 10}) => ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: (pct / 100).clamp(0, 1).toDouble(),
        minHeight: height,
        backgroundColor: BeatproColors.lineSoft,
        color: color ?? (pct >= 100 ? BeatproColors.success : BeatproColors.brand),
      ),
    );

/// The rep's target this month on Home. Reps on monthly salary only don't see it.
class TargetCard extends ConsumerWidget {
  const TargetCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(myTargetProvider).value;
    if (t == null) return const SizedBox.shrink();
    final money = ref.watch(moneyProvider);
    final next = t.nextStep;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/target'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('My target · ${t.monthLabel}', style: const TextStyle(fontWeight: FontWeight.w800))),
                Text('${t.daysLeft} days left', style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
              ]),
              const SizedBox(height: 6),
              Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 6, children: [
                Text(money(t.achieved), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text('of ${money(t.target)}', style: const TextStyle(color: BeatproColors.muted, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 8),
              _bar(t.progress),
              const SizedBox(height: 6),
              Row(children: [
                Text('${t.progress.round()}%', style: const TextStyle(fontWeight: FontWeight.w800, color: BeatproColors.brand)),
                const Spacer(),
                if (t.perDay > 0 && t.progress < 100)
                  Text('${money(t.perDay)} a day to reach it', style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
              ]),
              if (next != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(color: BeatproColors.amberSoft, borderRadius: BorderRadius.circular(10)),
                  child: Text(next['text'] as String,
                      style: const TextStyle(fontSize: 13, color: BeatproColors.amberInk, fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// The month's target, what the incentive pays, and product targets.
class TargetScreen extends ConsumerWidget {
  const TargetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyProvider);
    final t = ref.watch(myTargetProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('My target'),
          if (t != null) Text('${t.monthLabel} · Salary + incentive', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: t == null
          ? const EmptyState(icon: Icons.flag_outlined, title: 'No target this month', message: 'Your supervisor sets targets in Odoo.')
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Expanded(child: Text('Sales value', style: TextStyle(fontWeight: FontWeight.w800))),
                      Text('${t.progress.round()}%', style: const TextStyle(fontWeight: FontWeight.w800, color: BeatproColors.brand)),
                    ]),
                    Text('${money(t.achieved)} of ${money(t.target)} · invoiced, after returns',
                        style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
                    const SizedBox(height: 8),
                    _bar(t.progress),
                    const SizedBox(height: 10),
                    _Line(t.approved ? 'Incentive approved' : 'Incentive earned so far', money(t.earned)),
                    _Line('At this pace by month end', '${money(t.projected)} · ${money(t.projectedEarned)}',
                        color: BeatproColors.success),
                  ]),
                ),
              ),
              const Eyebrow('How the incentive works', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final (i, l) in t.lines.indexed) ...[
                    if (i > 0) const Divider(height: 1, color: BeatproColors.lineSoft),
                    Container(
                      color: t.nextStep != null && (t.nextStep!['rate'] as num) == (l['rate'] as num) ? BeatproColors.amberSoft : null,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(children: [
                        Expanded(child: Text(l['from'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
                        Flexible(child: Text(l['text'] as String, textAlign: TextAlign.end, style: const TextStyle(fontSize: 13))),
                      ]),
                    ),
                  ],
                  if (t.lines.isEmpty)
                    const Padding(padding: EdgeInsets.all(14), child: Text('No commission lines yet.')),
                ]),
              ),
              if (t.products.isNotEmpty) ...[
                const Eyebrow('Product targets', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Column(children: [
                      for (final p in t.products)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
                              Text('${formatQty(p['achieved'] as num)} / ${formatQty(p['qty'] as num)} ${p['unit'] ?? ''}',
                                  style: const TextStyle(fontWeight: FontWeight.w800)),
                            ]),
                            const SizedBox(height: 6),
                            _bar((p['qty'] as num) == 0 ? 0 : (p['achieved'] as num) * 100 / (p['qty'] as num), height: 8),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ],
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Your supervisor sets targets in Odoo. Figures update when you sync.',
                    style: TextStyle(fontSize: 12, color: BeatproColors.muted)),
              ),
            ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color)),
          ),
        ]),
      );
}

/// Shelf photos and the shop survey, on the visit screen.
class VisitExtras extends ConsumerWidget {
  const VisitExtras({super.key, required this.visit});

  final LocalRecord visit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final customerKey = visit.data['customerKey'] as String;
    final surveys = ref.watch(surveysForProvider(customerKey)).value ?? const <Survey>[];
    final photos = ref.watch(photosForProvider(visit.uuid)).value ?? const <LocalRecord>[];
    final needed = surveys.fold<int>(0, (s, v) => s + v.photos.fold<int>(0, (a, p) => a + p.$2));
    final inProgress = visit.data['state'] == 'in_progress';
    if (!inProgress && photos.isEmpty && surveys.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => context.push('/visit/${visit.uuid}/photos'),
            icon: const Icon(Icons.photo_camera_outlined),
            label: Text(needed > 0 ? 'Shelf photos ${photos.length}/$needed' : 'Shelf photos${photos.isEmpty ? '' : ' · ${photos.length}'}'),
          ),
        ),
        for (final s in surveys) ...[
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () => context.push('/visit/${visit.uuid}/survey/${s.id}'),
              icon: const Icon(Icons.checklist),
              label: Text(s.name, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Shelf photos taken during a visit, kept on the phone until they sync.
class VisitPhotosScreen extends ConsumerStatefulWidget {
  const VisitPhotosScreen({super.key, required this.visitUuid});

  final String visitUuid;

  @override
  ConsumerState<VisitPhotosScreen> createState() => _VisitPhotosScreenState();
}

class _VisitPhotosScreenState extends ConsumerState<VisitPhotosScreen> {
  String? _tag;
  bool _busy = false;

  Future<void> _take(List<String> tags) async {
    final tag = _tag ?? tags.first;
    setState(() => _busy = true);
    try {
      final bytes = await ref.read(photoServiceProvider).take();
      if (bytes == null) return;
      final at = await ref.read(locationProvider).current();
      await ref.read(repositoryProvider).addPhoto(
            visitUuid: widget.visitUuid,
            bytes: bytes,
            tag: tag,
            dir: await ref.read(photoDirProvider.future),
            at: at,
          );
      ref.read(dataVersionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visit = ref.watch(recordsProvider).value?.where((r) => r.uuid == widget.visitUuid).firstOrNull;
    final customerKey = visit?.data['customerKey'] as String?;
    final customer = customerKey == null ? null : ref.watch(customerProvider(customerKey)).value;
    final surveys = customerKey == null ? const <Survey>[] : ref.watch(surveysForProvider(customerKey)).value ?? const <Survey>[];
    final photos = ref.watch(photosForProvider(widget.visitUuid)).value ?? const <LocalRecord>[];
    final repoTags = ref.watch(_photoTagsProvider).value ?? const <String>[];
    final needs = <String, int>{};
    for (final s in surveys) {
      for (final (tag, n) in s.photos) {
        needs[tag] = (needs[tag] ?? 0) + n;
      }
    }
    final tags = [...needs.keys, ...repoTags.where((t) => !needs.containsKey(t))];
    if (tags.isEmpty) tags.add('Main shelf');
    // Suggest the first photo still needed.
    final missing = needs.entries.where((e) => photos.where((p) => p.data['tag'] == e.key).length < e.value).map((e) => e.key);
    final tag = _tag ?? missing.firstOrNull ?? tags.first;
    final neededCount = needs.values.fold<int>(0, (a, b) => a + b);
    final takenNeeded = needs.entries.fold<int>(0, (a, e) {
      final n = photos.where((p) => p.data['tag'] == e.key).length;
      return a + (n < e.value ? n : e.value);
    });
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Shelf photos'),
          Text('${customer?.name ?? ''} · visit', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (needs.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFE6EEF7), borderRadius: BorderRadius.circular(12)),
            child: Text(
              'Needed at this shop: ${needs.entries.map((e) => '${e.value} of ${e.key.toLowerCase()}').join(', ')}',
              style: const TextStyle(color: Color(0xFF184878), fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 3 / 4,
          children: [
            for (final p in photos)
              _PhotoTile(
                record: p,
                onDelete: p.state == SyncState.synced
                    ? null
                    : () async {
                        await ref.read(repositoryProvider).deletePhoto(p.uuid);
                        ref.read(dataVersionProvider.notifier).bump();
                      },
              ),
          ],
        ),
        const Eyebrow('Photo of', padding: EdgeInsets.fromLTRB(0, 16, 0, 8)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in tags)
            ChoiceChip(
              label: Text(t),
              selected: t == tag,
              onSelected: (_) => setState(() => _tag = t),
            ),
        ]),
        const SizedBox(height: 12),
        const Text(
          'Photos are kept on the phone and sent with the visit when there is signal. Each photo has the time and place it was taken.',
          style: TextStyle(fontSize: 12, color: BeatproColors.muted),
        ),
      ]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: BeatproColors.line))),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (neededCount > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Text('$takenNeeded of $neededCount needed taken', style: const TextStyle(fontSize: 13, color: BeatproColors.muted)),
                    const Spacer(),
                    if (takenNeeded >= neededCount) ...[
                      const Text('Done', style: TextStyle(color: BeatproColors.success, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 4),
                      const Icon(Icons.check_circle, size: 18, color: BeatproColors.success),
                    ],
                  ]),
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _busy ? null : () => _take([tag]),
                icon: const Icon(Icons.photo_camera),
                label: Text('Take photo of ${tag.toLowerCase()}'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

final _photoTagsProvider = FutureProvider<List<String>>((ref) => ref.watch(repositoryProvider).photoTags());

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({required this.record, this.onDelete});

  final LocalRecord record;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final file = File(record.data['path'] as String);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(fit: StackFit.expand, children: [
        file.existsSync()
            ? Image.file(file, fit: BoxFit.cover, errorBuilder: (_, _, _) => const ColoredBox(color: BeatproColors.lineSoft))
            : const ColoredBox(color: BeatproColors.successSoft, child: Icon(Icons.cloud_done_outlined, color: BeatproColors.success)),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: const Color(0xB82A1215),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Text(record.data['tag'] as String? ?? '',
                maxLines: 2, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ),
        if (onDelete != null)
          Positioned(
            top: 2,
            right: 2,
            child: IconButton(
              tooltip: tr('Remove photo'),
              onPressed: onDelete,
              style: IconButton.styleFrom(backgroundColor: const Color(0x99000000)),
              icon: const Icon(Icons.close, color: Colors.white, size: 18),
            ),
          ),
      ]),
    );
  }
}

/// A shop survey's questions, answered at the shop.
class SurveyScreen extends ConsumerStatefulWidget {
  const SurveyScreen({super.key, required this.visitUuid, required this.surveyId});

  final String visitUuid;
  final int surveyId;

  @override
  ConsumerState<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends ConsumerState<SurveyScreen> {
  Survey? _survey;
  final Map<int, Object?> _answers = {};
  final Map<int, TextEditingController> _text = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final visit = await repo.db.record(widget.visitUuid);
    final surveys = visit == null ? const <Survey>[] : await repo.surveysFor(visit.data['customerKey'] as String);
    final survey = surveys.where((s) => s.id == widget.surveyId).firstOrNull;
    final saved = await repo.answersFor(widget.visitUuid, widget.surveyId);
    if (!mounted) return;
    setState(() {
      _survey = survey;
      _answers.addAll(saved);
      for (final q in survey?.questions ?? const <SurveyQuestion>[]) {
        if (const ['number', 'price', 'text'].contains(q.kind)) {
          _text[q.id] = TextEditingController(text: saved[q.id]?.toString() ?? '');
        }
      }
      _loading = false;
    });
  }

  Future<void> _save() async {
    for (final e in _text.entries) {
      _answers[e.key] = e.value.text.trim().isEmpty ? null : e.value.text.trim();
    }
    try {
      await ref.read(repositoryProvider).saveSurveyAnswers(visitUuid: widget.visitUuid, survey: _survey!, answers: _answers);
      ref.read(dataVersionProvider.notifier).bump();
      if (mounted) {
        showMessage(context, 'Answers saved. They are sent with the visit.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showMessage(context, describeError(e), error: true);
    }
  }

  Widget _input(SurveyQuestion q) => switch (q.kind) {
        'yes_no' => Row(children: [
            for (final (value, label) in [(true, 'Yes'), (false, 'No')]) ...[
              Expanded(
                child: _answers[q.id] == value
                    ? FilledButton(onPressed: () => setState(() => _answers[q.id] = value), child: Text(label))
                    : OutlinedButton(onPressed: () => setState(() => _answers[q.id] = value), child: Text(label)),
              ),
              if (value) const SizedBox(width: 8),
            ],
          ]),
        'choice' => Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in q.choices)
              ChoiceChip(label: Text(c), selected: _answers[q.id] == c, onSelected: (_) => setState(() => _answers[q.id] = c)),
          ]),
        _ => TextField(
            controller: _text[q.id],
            keyboardType: q.kind == 'text' ? TextInputType.text : const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              prefixText: q.kind == 'price' ? '${ref.read(appContextProvider).value?.currencyCode ?? ''} ' : null,
              suffixText: q.suffix.isEmpty ? null : q.suffix,
            ),
          ),
      };

  @override
  Widget build(BuildContext context) {
    final s = _survey;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Shop survey'),
          if (s != null) Text('${s.name} · ${s.questions.length} questions', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : s == null
              ? const EmptyState(icon: Icons.checklist, title: 'Survey not found', message: 'Sync to update the surveys.')
              : ListView(padding: const EdgeInsets.all(16), children: [
                  for (final (i, q) in s.questions.indexed)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('QUESTION ${i + 1}',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: BeatproColors.muted)),
                          const SizedBox(height: 4),
                          Text(q.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 10),
                          _input(q),
                        ]),
                      ),
                    ),
                ]),
      bottomNavigationBar: s == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                  onPressed: _save,
                  child: const Text('Save answers'),
                ),
              ),
            ),
    );
  }
}
