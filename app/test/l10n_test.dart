import 'package:beatpro/src/l10n/ar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exact texts, capitals and texts in parts', () {
    expect(translateAr('Collect payment'), 'تحصيل دفعة');
    expect(translateAr('OPEN INVOICES'), 'الفواتير المفتوحة');
    expect(translateAr('0 of 4 visited · 3.5 km · Andheri East'), 'تمت زيارة 0 من 4 · 3.5 كم · Andheri East');
    expect(translateAr('Skipped · closed'), 'تم التخطي · مغلق');
  });

  test('numbers, amounts and names stay as they are', () {
    expect(translateAr('4 shops left today'), 'بقي 4 محلات اليوم');
    expect(translateAr('3 cs + 5 pc'), '3 كرتون + 5 حبة');
    expect(translateAr('560.00 د.إ / pc'), '560.00 د.إ / حبة');
    expect(translateAr('Patel Kirana moved to tomorrow.'), 'نُقل Patel Kirana إلى الغد.');
    expect(translateAr('Sharma General Store'), 'Sharma General Store');
    expect(translateAr('9 Nov'), '9 نوفمبر');
  });

  test('texts with no Arabic are listed', () {
    final misses = <String>{};
    translateAr('A text nobody wrote', misses: misses);
    expect(misses, {'A text nobody wrote'});
  });
}
