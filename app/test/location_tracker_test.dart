import 'dart:async';
import 'dart:convert';

import 'package:beatpro/src/core/local_db.dart';
import 'package:beatpro/src/core/location_tracker.dart';
import 'package:beatpro/src/core/models.dart';
import 'package:beatpro/src/core/repository.dart';
import 'package:beatpro/src/core/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Positions the test sends, as the phone's background location service would.
class StreamLocationService implements LocationService {
  StreamController<GeoPoint>? controller;
  Duration? asked;

  @override
  Future<GeoPoint?> current() async => const GeoPoint(25.2, 55.3);

  @override
  Stream<GeoPoint> watch(Duration interval) {
    asked = interval;
    controller = StreamController<GeoPoint>();
    return controller!.stream;
  }
}

void main() {
  sqfliteFfiInit();

  test('positions while the rep works, from first check-in until day close', () async {
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    var now = DateTime(2026, 11, 7, 9);
    final repo = Repository(db, clock: () => now);
    await db.setValue('context', jsonEncode({
      'user_id': 5, 'name': 'Ravi', 'company_name': 'Gulf Foods', 'track_location': true, 'location_minutes': 5,
      'currency': {'name': 'AED', 'symbol': 'AED', 'position': 'before', 'decimals': 2},
    }));
    final gps = StreamLocationService();
    var uploads = 0;
    final tracker = LocationTracker(repo, gps, upload: () async => uploads++);

    await tracker.refresh();
    expect(tracker.watching, isFalse, reason: 'not working yet: no check-in today');

    final visit = await repo.startVisit('srv:9', at: const GeoPoint(25.24, 55.30));
    await tracker.refresh();
    expect(tracker.watching, isTrue);
    expect(gps.asked, const Duration(minutes: 5));
    expect((await repo.locationQueue()).length, 1, reason: 'the check-in position');

    gps.controller!.add(const GeoPoint(25.25, 55.31));
    gps.controller!.add(const GeoPoint(25.26, 55.32)); // too soon after the last one: skipped
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await repo.locationQueue()).length, 2);
    expect(uploads, 1, reason: 'sent straight away when there is signal');

    await repo.checkOut(visit.uuid, result: VisitResult.order);
    await repo.closeDay();
    await tracker.refresh();
    expect(tracker.watching, isFalse, reason: 'stops at day close');
    tracker.stop();
    await db.close();
  });

  test('nothing when location sharing is off for the rep', () async {
    final db = await LocalDb.open(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    final repo = Repository(db);
    await db.setValue('context', jsonEncode({
      'user_id': 5, 'name': 'Ravi', 'company_name': 'Gulf Foods', 'track_location': false,
      'currency': {'name': 'AED', 'symbol': 'AED', 'position': 'before', 'decimals': 2},
    }));
    final gps = StreamLocationService();
    final tracker = LocationTracker(repo, gps);
    await repo.startVisit('srv:9', at: const GeoPoint(25.24, 55.30));
    await tracker.refresh();
    expect(tracker.watching, isFalse);
    expect(await repo.locationQueue(), isEmpty);
    await db.close();
  });
}
