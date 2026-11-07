import 'dart:async';

import 'repository.dart';
import 'services.dart';

/// Keeps the rep's position for the supervisor's Live Map, from the first
/// check-in of the day until the day is closed, when location sharing is on
/// for the rep in Odoo.
///
/// While the rep works, a background location service (with a notification
/// on Android) sends a position about every few minutes, also with the app
/// closed. Positions wait on the phone and are sent as soon as there is signal.
class LocationTracker {
  LocationTracker(this.repo, this.location, {this.upload});

  final Repository repo;
  final LocationService location;

  /// Sends waiting positions to Odoo; failures are fine, they are sent later.
  final Future<void> Function()? upload;

  Timer? _check;
  StreamSubscription<GeoPoint>? _watching;
  Duration _interval = const Duration(minutes: 5);
  DateTime? _lastQueued;

  bool get watching => _watching != null;

  /// Checks every minute whether the rep is working, and starts or stops the
  /// background positions to match.
  Future<void> start() async {
    _check ??= Timer.periodic(const Duration(minutes: 1), (_) => refresh());
    await refresh();
  }

  void stop() {
    _check?.cancel();
    _check = null;
    _stopWatching();
  }

  /// Starts positions when the rep starts working, stops them at day close
  /// (or when sharing is switched off in Odoo).
  Future<void> refresh() async {
    final context = await repo.appContext();
    final sharing = context?.trackLocation == true && await repo.workingNow();
    if (!sharing) {
      _stopWatching();
      return;
    }
    final interval = Duration(minutes: context!.locationMinutes);
    if (_watching != null && interval == _interval) return;
    _stopWatching();
    _interval = interval;
    _watching = location.watch(interval).listen(_position);
  }

  void _stopWatching() {
    _watching?.cancel();
    _watching = null;
  }

  Future<void> _position(GeoPoint at) async {
    final now = DateTime.now();
    // The phone may report more often than asked: keep one position per interval.
    if (_lastQueued != null && now.difference(_lastQueued!) < _interval - const Duration(seconds: 30)) return;
    _lastQueued = now;
    await repo.queueLocation(at);
    try {
      await upload?.call();
    } catch (_) {
      // No signal: sent with the next sync.
    }
  }

  /// Records one position now, if the rep is working and shares their location.
  Future<bool> tick() async {
    final context = await repo.appContext();
    if (context?.trackLocation != true || !await repo.workingNow()) return false;
    final at = await location.current();
    if (at == null) return false;
    await repo.queueLocation(at);
    return true;
  }
}
