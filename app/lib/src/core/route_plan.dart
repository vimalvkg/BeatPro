import 'dart:math' as math;

/// Straight-line distance in km between two (lat, lng) points.
double distanceKm((double, double) a, (double, double) b) {
  double rad(double d) => d * math.pi / 180;
  final h = math.pow(math.sin(rad(b.$1 - a.$1) / 2), 2) +
      math.cos(rad(a.$1)) * math.cos(rad(b.$1)) * math.pow(math.sin(rad(b.$2 - a.$2) / 2), 2);
  return 2 * 6371 * math.asin(math.sqrt(h));
}

double pathKm((double, double)? start, List<(double, double)> points) {
  var total = 0.0;
  var here = start;
  for (final p in points) {
    if (here != null) total += distanceKm(here, p);
    here = p;
  }
  return total;
}

/// Visiting order for [points] from [start]: nearest first, then shortened by
/// reversing stretches while that helps (2-opt), as Odoo does. Indexes into [points].
List<int> shortestOrder((double, double)? start, List<(double, double)> points) {
  if (points.length < 2) return List.generate(points.length, (i) => i);
  final left = List.generate(points.length, (i) => i);
  var here = start ?? points.first;
  final order = <int>[];
  while (left.isNotEmpty) {
    left.sort((a, b) => distanceKm(here, points[a]).compareTo(distanceKm(here, points[b])));
    final nearest = left.removeAt(0);
    order.add(nearest);
    here = points[nearest];
  }
  double length(List<int> o) => pathKm(start, [for (final i in o) points[i]]);
  var improved = true;
  var best = order;
  while (improved) {
    improved = false;
    for (var i = 0; i < best.length - 1; i++) {
      for (var j = i + 1; j < best.length; j++) {
        final candidate = [...best.sublist(0, i), ...best.sublist(i, j + 1).reversed, ...best.sublist(j + 1)];
        if (length(candidate) + 1e-9 < length(best)) {
          best = candidate;
          improved = true;
        }
      }
    }
  }
  return best;
}
