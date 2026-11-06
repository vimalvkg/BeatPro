import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Odoo refused the request (wrong key, access rights, a business rule).
/// The [message] is Odoo's own, meant for the user.
class OdooException implements Exception {
  OdooException(this.message, {this.statusCode, this.errorName});

  final String message;
  final int? statusCode;
  final String? errorName;

  bool get isAuth => statusCode == 401;

  @override
  String toString() => message;
}

/// The phone couldn't reach Odoo (no signal, server down). Safe to retry later.
class OfflineException implements Exception {
  OfflineException(this.cause);

  final Object cause;

  @override
  String toString() => "Can't reach Odoo right now. Your work is saved on the phone.";
}

/// Connection details for one Odoo database. The app always talks to Odoo
/// with an API key: either one the user pasted, or one Odoo made for this
/// phone when the user signed in with their login and password.
class OdooCredentials {
  const OdooCredentials({required this.url, required this.database, required this.apiKey, this.login});

  final String url;
  final String database;
  final String apiKey;

  /// The login the user signed in with, when they used a password.
  final String? login;

  String get baseUrl => url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  Map<String, String> toJson() => {'url': url, 'database': database, 'apiKey': apiKey, 'login': ?login};

  static OdooCredentials? fromJson(Map<String, dynamic>? json) {
    if (json == null || json['url'] == null || json['apiKey'] == null) return null;
    return OdooCredentials(
      url: json['url'] as String,
      database: (json['database'] as String?) ?? '',
      apiKey: json['apiKey'] as String,
      login: json['login'] as String?,
    );
  }

  /// Signs in with the user's Odoo login and password. Odoo checks them and
  /// returns an API key made for this phone; the password is not kept.
  static Future<OdooCredentials> signInWithPassword({
    required String url,
    required String database,
    required String login,
    required String password,
    required String device,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    final client = httpClient ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .post(
            Uri.parse('$base/beatpro/app/login'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({
              'jsonrpc': '2.0',
              'method': 'call',
              'params': {
                'login': login,
                'password': password,
                'db': database.isEmpty ? null : database,
                'device': device,
              },
            }),
          )
          .timeout(timeout);
    } on SocketException catch (e) {
      throw OfflineException(e);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } on http.ClientException catch (e) {
      throw OfflineException(e);
    } finally {
      if (httpClient == null) client.close();
    }
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      json = null;
    }
    if (response.statusCode != 200 || json == null || json['result'] is! Map) {
      if (response.statusCode >= 502) throw OfflineException('HTTP ${response.statusCode}');
      throw OdooException(
        "This Odoo server can't sign the app in with a password. Check the address, or ask your "
        'administrator to update the BeatPro module.',
        statusCode: response.statusCode,
      );
    }
    final result = json['result'] as Map<String, dynamic>;
    if (result['error'] != null) throw OdooException(result['error'] as String);
    return OdooCredentials(
      url: url,
      database: (result['database'] as String?) ?? database,
      apiKey: result['api_key'] as String,
      login: login,
    );
  }
}

/// Calls Odoo 19's JSON-2 API: `POST /json/2/<model>/<method>`.
class OdooClient {
  OdooClient(this.credentials, {http.Client? httpClient, this.timeout = const Duration(seconds: 30)})
      : _http = httpClient ?? http.Client();

  final OdooCredentials credentials;
  final http.Client _http;
  final Duration timeout;

  /// Calls [method] on [model]. [ids] are the records the method runs on;
  /// [kwargs] are its named arguments.
  Future<dynamic> call(
    String model,
    String method, {
    List<int>? ids,
    Map<String, dynamic> kwargs = const {},
    Map<String, dynamic>? context,
  }) async {
    final uri = Uri.parse('${credentials.baseUrl}/json/2/$model/$method');
    final body = <String, dynamic>{
      ...kwargs,
      'ids': ?ids,
      'context': ?context,
    };
    final http.Response response;
    try {
      response = await _http
          .post(
            uri,
            headers: {
              'Authorization': 'bearer ${credentials.apiKey}',
              'Content-Type': 'application/json; charset=utf-8',
              if (credentials.database.isNotEmpty) 'X-Odoo-Database': credentials.database,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on SocketException catch (e) {
      throw OfflineException(e);
    } on TimeoutException catch (e) {
      throw OfflineException(e);
    } on http.ClientException catch (e) {
      throw OfflineException(e);
    }

    final text = utf8.decode(response.bodyBytes);
    if (response.statusCode == 200) {
      return text.isEmpty ? null : jsonDecode(text);
    }
    if (response.statusCode >= 500 && response.statusCode != 500) {
      // 502, 503, 504: a proxy or a restarting server. Try again later.
      throw OfflineException('HTTP ${response.statusCode}');
    }
    throw _error(response.statusCode, text);
  }

  Future<List<Map<String, dynamic>>> searchRead(
    String model, {
    List<dynamic> domain = const [],
    required List<String> fields,
    int? limit,
    String? order,
    Map<String, dynamic>? context,
  }) async {
    final result = await call(model, 'search_read', kwargs: {
      'domain': domain,
      'fields': fields,
      'limit': ?limit,
      'order': ?order,
    }, context: context);
    return (result as List).cast<Map<String, dynamic>>();
  }

  OdooException _error(int status, String text) {
    if (status == 401) {
      return OdooException(
        'Your sign-in has expired or was turned off in Odoo. Open More > Sign in again.',
        statusCode: status,
      );
    }
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      final message = (json['message'] as String?)?.trim();
      return OdooException(
        (message == null || message.isEmpty) ? 'Odoo returned an error ($status).' : message,
        statusCode: status,
        errorName: json['name'] as String?,
      );
    } catch (_) {
      if (status == 401) {
        return OdooException('Odoo rejected the API key. Create a new key and sign in again.', statusCode: status);
      }
      if (status == 404) {
        return OdooException(
          "This Odoo server doesn't have the BeatPro module, or the address is wrong.",
          statusCode: status,
        );
      }
      return OdooException('Odoo returned an error ($status).', statusCode: status);
    }
  }

  void close() => _http.close();
}
