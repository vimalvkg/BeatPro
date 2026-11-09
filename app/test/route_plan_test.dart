import 'package:beatpro/src/core/route_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shortest order visits the nearest shops first', () {
    const start = (25.20, 55.20);
    final points = [(25.20, 55.40), (25.20, 55.21), (25.20, 55.30)];
    final order = shortestOrder(start, points);
    expect(order, [1, 2, 0]);
    expect(pathKm(start, [for (final i in order) points[i]]), lessThan(pathKm(start, points)));
    expect(distanceKm((25.20, 55.20), (25.20, 55.30)), closeTo(10.1, 0.2), reason: 'about 10 km at Dubai');
  });

  test('2-opt untangles a crossing path', () {
    final points = [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)];
    final order = shortestOrder(null, points);
    final crossing = pathKm(null, points);
    expect(pathKm(null, [for (final i in order) points[i]]), lessThan(crossing));
  });
}
