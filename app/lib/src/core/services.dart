import 'dart:convert';

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
}

class FixedLocationService implements LocationService {
  const FixedLocationService(this.point);

  final GeoPoint? point;

  @override
  Future<GeoPoint?> current() async => point;
}

/// Formats amounts in the company currency, Indian digit grouping for INR.
class Money {
  Money(this.context);

  final AppContext? context;

  String call(num amount) {
    final symbol = context?.currencySymbol ?? '';
    final decimals = context?.currencyDecimals ?? 2;
    final locale = symbol == '₹' ? 'en_IN' : 'en_US';
    final number = NumberFormat.decimalPatternDigits(locale: locale, decimalDigits: decimals).format(amount);
    if (symbol.isEmpty) return number;
    return (context?.currencyBefore ?? true) ? '$symbol$number' : '$number $symbol';
  }
}

String formatQty(num qty) => qty == qty.roundToDouble() ? qty.toInt().toString() : qty.toStringAsFixed(2);

String formatTime(DateTime t) => DateFormat.jm().format(t.toLocal());

String formatDate(DateTime t) => DateFormat.yMMMd().format(t.toLocal());
