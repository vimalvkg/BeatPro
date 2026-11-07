import 'dart:async';

import 'repository.dart';
import 'services.dart';

/// Sends the rep's position for the supervisor's Live Map every few minutes,
/// from the first check-in of the day until the day is closed, when location
/// sharing is on for the rep in Odoo. Positions wait on the phone until a sync.
///
/// Runs while the app is open; check-ins and check-outs add a position too.
class LocationTracker {
  LocationTracker(this.repo, this.location);

  final Repository repo;
  final LocationService location;
  Timer? _timer;
  int _minutes = 0;

  /// Starts (or restarts, if Odoo changed the interval) the timer.
  Future<void> start() async {
    final minutes = (await repo.appContext())?.locationMinutes ?? 5;
    if (_timer != null && minutes == _minutes) return;
    _timer?.cancel();
    _minutes = minutes;
    _timer = Timer.periodic(Duration(minutes: minutes), (_) => tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Records one position, if the rep is working and shares their location.
  Future<bool> tick() async {
    final context = await repo.appContext();
    if (context?.trackLocation != true || !await repo.workingNow()) return false;
    final at = await location.current();
    if (at == null) return false;
    await repo.queueLocation(at);
    return true;
  }
}
