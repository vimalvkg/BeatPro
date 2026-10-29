import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stand-in for an Odoo 19 server with the BeatPro module, answering the
/// JSON-2 calls the app makes with the same shapes the real module returns.
class FakeOdoo {
  final calls = <String>[];
  final uploaded = <String, List<Map<String, dynamic>>>{};
  bool offline = false;
  int _nextId = 1000;

  static const shops = [
    {'id': 8, 'name': 'Sharma General Store', 'city': 'Andheri East', 'phone': '+91 98200 10000', 'lat': 19.1136, 'lng': 72.8697},
    {'id': 9, 'name': 'Patel Kirana', 'city': 'Andheri East', 'phone': '+91 98200 10001', 'lat': 19.1155, 'lng': 72.8722},
    {'id': 10, 'name': 'New Bombay Traders', 'city': 'Marol', 'phone': '+91 98200 10002', 'lat': 19.1197, 'lng': 72.8826},
    {'id': 11, 'name': 'Shree Ganesh Mart', 'city': 'Saki Naka', 'phone': '+91 98200 10003', 'lat': 19.1032, 'lng': 72.8885},
  ];

  static const products = [
    {'id': 1, 'name': 'Parle-G Biscuits (Box of 24)', 'price': 240.0, 'qty': 120.0},
    {'id': 2, 'name': 'Maggi Noodles (Case of 48)', 'price': 576.0, 'qty': 80.0},
    {'id': 3, 'name': 'Tata Salt 1kg (Bag of 10)', 'price': 280.0, 'qty': 0.0},
    {'id': 4, 'name': 'Amul Butter 100g (Pack of 20)', 'price': 1100.0, 'qty': 35.0},
    {'id': 5, 'name': 'Surf Excel 1kg (Case of 12)', 'price': 1560.0, 'qty': 18.0},
  ];

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    if (offline) throw http.ClientException('No signal');
    final parts = request.url.path.split('/'); // /json/2/<model>/<method>
    final model = parts[3];
    final method = parts[4];
    calls.add('$model.$method');
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;
    if (request.headers['Authorization'] != 'bearer ${'k' * 40}') {
      return http.Response(jsonEncode({'name': 'odoo.exceptions.AccessDenied', 'message': 'Access Denied'}), 401);
    }
    return http.Response.bytes(utf8.encode(jsonEncode(_answer(model, method, body))), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  dynamic _answer(String model, String method, Map<String, dynamic> body) {
    switch ('$model.$method') {
      case 'res.users.beatpro_app_context':
        return {
          'user_id': 5,
          'name': 'Ravi Kumar',
          'partner_id': 6,
          'lang': 'en_IN',
          'tz': 'Asia/Kolkata',
          'company_id': 1,
          'company_name': 'Mumbai Distributors Pvt Ltd',
          'currency': {'id': 20, 'name': 'INR', 'symbol': '₹', 'position': 'before', 'decimals': 2},
          'is_rep': true,
          'is_supervisor': false,
          'discount_limit': 5.0,
          'warehouse_id': 1,
          'server_time': '2026-10-29 06:00:00',
        };
      case 'beatpro.route.beatpro_today_plan':
        return [
          for (final (i, s) in shops.indexed)
            {'route_id': 1, 'route_name': 'Andheri East', 'sequence': i, 'partner_id': s['id'], 'partner_name': s['name']},
        ];
      case 'res.partner.search_read':
        return [
          for (final s in shops)
            {
              'id': s['id'],
              'name': s['name'],
              'phone': s['phone'],
              'street': false,
              'city': s['city'],
              'partner_latitude': s['lat'],
              'partner_longitude': s['lng'],
              'property_product_pricelist': [1, 'Default (INR)'],
            },
        ];
      case 'product.product.search_read':
        return [
          for (final p in products)
            {
              'id': p['id'],
              'display_name': p['name'],
              'lst_price': p['price'],
              'qty_available': p['qty'],
              'default_code': false,
              'uom_id': [1, 'Units'],
              'categ_id': [1, 'All'],
              'taxes_id': [1],
            },
        ];
      case 'account.tax.search_read':
        return [
          {'id': 1, 'amount': 18.0, 'amount_type': 'percent'},
        ];
      case 'product.pricelist.beatpro_prices':
        return {
          '1': {for (final p in products) '${p['id']}': p['id'] == 2 ? 560.0 : p['price']},
        };
      case 'res.partner.beatpro_open_invoices':
        return [
          {
            'id': 77,
            'partner_id': 8,
            'name': 'INV/2026/00042',
            'invoice_date': '2026-10-01',
            'due_date': '2026-10-15',
            'amount_total': 1200.0,
            'amount_due': 1200.0,
            'overdue': true,
          },
        ];
      case 'sale.order.beatpro_submit_orders':
        return {
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            v['mobile_uuid']: () {
              _record(model, v);
              return {'id': _nextId++, 'name': 'S0004${_nextId % 10}', 'state': 'sale', 'approval': false, 'amount_total': 1321.6};
            }(),
        };
      case 'account.payment.beatpro_register_payment':
      case 'res.partner.beatpro_upsert':
      case 'beatpro.visit.beatpro_upsert':
      case 'beatpro.day.close.beatpro_upsert':
        return {
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            v['mobile_uuid']: () {
              _record(model, v);
              return _nextId++;
            }(),
        };
      case 'beatpro.day.close.action_close':
        return true;
    }
    throw StateError('FakeOdoo has no answer for $model.$method');
  }

  void _record(String model, Map<String, dynamic> vals) => (uploaded[model] ??= []).add(vals);
}
