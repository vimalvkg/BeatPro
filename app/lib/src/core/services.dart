import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import 'models.dart';
import 'odoo_client.dart';
import 'repository.dart';

/// Keeps the Odoo address and API key in the phone's secure storage.
abstract class CredentialStore {
  Future<OdooCredentials?> read();
  Future<void> write(OdooCredentials credentials);
  Future<void> clear();
}

class SecureCredentialStore implements CredentialStore {
  const SecureCredentialStore();

  static const _key = 'beatpro_credentials';
  static const _storage = FlutterSecureStorage();

  @override
  Future<OdooCredentials?> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null ? null : OdooCredentials.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> write(OdooCredentials credentials) =>
      _storage.write(key: _key, value: jsonEncode(credentials.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([this._value]);

  OdooCredentials? _value;

  @override
  Future<OdooCredentials?> read() async => _value;

  @override
  Future<void> write(OdooCredentials credentials) async => _value = credentials;

  @override
  Future<void> clear() async => _value = null;
}

/// Gets the phone's position for check-in, check-out and new customers.
abstract class LocationService {
  /// The current position, or null when location is off or refused.
  Future<GeoPoint?> current();

  /// Positions about every [interval], also while the app is in the background,
  /// for the supervisor's Live Map. Empty when location is off or refused.
  Stream<GeoPoint> watch(Duration interval);
}

class GpsLocationService implements LocationService {
  const GpsLocationService();

  @override
  Future<GeoPoint?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      return GeoPoint(position.latitude, position.longitude);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<GeoPoint> watch(Duration interval) async* {
    if (!await Geolocator.isLocationServiceEnabled()) return;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;
    final LocationSettings settings;
    if (!kIsWeb && Platform.isAndroid) {
      // A foreground service with a notification keeps positions coming when the app is closed.
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        intervalDuration: interval,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'BeatPro is sharing your location',
          notificationText: 'Until you close the day. Your supervisor sees it on the Live Map.',
          notificationChannelName: 'Location while working',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    } else if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      settings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 50,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    } else {
      settings = const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 50);
    }
    yield* Geolocator.getPositionStream(locationSettings: settings)
        .map((p) => GeoPoint(p.latitude, p.longitude))
        .handleError((Object _) {});
  }
}

class FixedLocationService implements LocationService {
  const FixedLocationService(this.point);

  final GeoPoint? point;

  @override
  Future<GeoPoint?> current() async => point;

  @override
  Stream<GeoPoint> watch(Duration interval) => const Stream.empty();
}

/// Formats amounts in the company currency: "AED 1,200.00" for dirhams.
class Money {
  Money(this.context);

  final AppContext? context;

  String call(num amount) {
    final symbol = context?.currencySymbol ?? '';
    final decimals = context?.currencyDecimals ?? 2;
    final locale = symbol == '₹' ? 'en_IN' : 'en_US';
    final number = NumberFormat.decimalPatternDigits(locale: locale, decimalDigits: decimals).format(amount);
    // UAE reps and shops write dirhams as "AED 1,200.00", not with the Arabic sign.
    if (context?.currencyCode == 'AED') return 'AED $number';
    if (symbol.isEmpty) return number;
    return (context?.currencyBefore ?? true) ? '$symbol$number' : '$number $symbol';
  }
}

String formatQty(num qty) => qty == qty.roundToDouble() ? qty.toInt().toString() : qty.toStringAsFixed(2);

String formatTime(DateTime t) => DateFormat.jm().format(t.toLocal());

String formatDate(DateTime t) => DateFormat.yMMMd().format(t.toLocal());
