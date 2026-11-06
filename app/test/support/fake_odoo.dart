import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A stand-in for an Odoo 19 server with the BeatPro module, answering the
/// JSON-2 calls the app makes with the same shapes the real module returns.
class FakeOdoo {
  final calls = <String>[];
  final uploaded = <String, List<Map<String, dynamic>>>{};
  bool offline = false;
  bool onlinePaid = false;
  int _nextId = 1000;

  /// The rep has a van (MH 02 AB 4521), loaded from the main warehouse.
  bool withVan = false;

  /// The user is a supervisor with the Van Sales Dashboard.
  bool supervisor = false;

  /// The van's stock per product: loaded, sold, returned, left.
  final van = <int, Map<String, double>>{};
  Map<String, dynamic>? openLoad;
  Map<String, dynamic>? unload;

  /// The storekeeper confirms the waiting load request.
  void storekeeperLoads() {
    final load = uploaded['beatpro.van.transfer.load']!.last;
    for (final l in (load['line_ids'] as List)) {
      final vals = (l as List)[2] as Map<String, dynamic>;
      final row = van[vals['product_id'] as int] ??= {'loaded': 0, 'sold': 0, 'returned': 0, 'left': 0};
      row['loaded'] = row['loaded']! + (vals['qty'] as num);
      row['left'] = row['left']! + (vals['qty'] as num);
    }
    openLoad = null;
  }

  static const shops = [
    {'id': 8, 'name': 'Sharma General Store', 'city': 'Andheri East', 'phone': '+91 98200 10000', 'lat': 19.1136, 'lng': 72.8697},
    {'id': 9, 'name': 'Patel Kirana', 'city': 'Andheri East', 'phone': '+91 98200 10001', 'lat': 19.1155, 'lng': 72.8722},
    {'id': 10, 'name': 'New Bombay Traders', 'city': 'Marol', 'phone': '+91 98200 10002', 'lat': 19.1197, 'lng': 72.8826},
    {'id': 11, 'name': 'Shree Ganesh Mart', 'city': 'Saki Naka', 'phone': '+91 98200 10003', 'lat': 19.1032, 'lng': 72.8885},
  ];

  static const products = [
    {'id': 1, 'name': 'Parle-G Biscuits (Box of 24)', 'price': 240.0, 'qty': 120.0, 'barcode': '8901719101038', 'code': 'PG24'},
    {'id': 2, 'name': 'Maggi Noodles (Case of 48)', 'price': 576.0, 'qty': 80.0, 'barcode': '8901058851298', 'code': 'MG48'},
    {'id': 3, 'name': 'Tata Salt 1kg (Bag of 10)', 'price': 280.0, 'qty': 0.0, 'barcode': '8904043901015', 'code': 'TS10'},
    {'id': 4, 'name': 'Amul Butter 100g (Pack of 20)', 'price': 1100.0, 'qty': 35.0, 'barcode': '8901262150064', 'code': 'AB20'},
    {'id': 5, 'name': 'Surf Excel 1kg (Case of 12)', 'price': 1560.0, 'qty': 18.0, 'barcode': '8901030704116', 'code': 'SE12'},
  ];

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    if (offline) throw http.ClientException('No signal');
    if (request.url.path == '/beatpro/app/login') return _appLogin(request);
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

  /// Devices that signed in with a password, with the database they asked for.
  final signIns = <Map<String, dynamic>>[];

  http.Response _appLogin(http.Request request) {
    calls.add('app_login');
    final params = (jsonDecode(request.body) as Map<String, dynamic>)['params'] as Map<String, dynamic>;
    signIns.add(params);
    final ok = params['login'] == 'ravi@beatpro.test' && params['password'] == 'ravi123';
    final result = ok
        ? {'api_key': 'k' * 40, 'database': 'mumbai', 'expires': '2027-11-06'}
        : {'error': 'Wrong login or password.'};
    return http.Response.bytes(utf8.encode(jsonEncode({'jsonrpc': '2.0', 'id': null, 'result': result})), 200,
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
          'payment_methods': [
            {'id': 31, 'name': 'Cash', 'journal': 'Field Cash', 'kind': 'cash', 'reference': 'none', 'hand_in': true},
            {'id': 32, 'name': 'UPI', 'journal': 'Bank', 'kind': 'bank', 'reference': 'reference', 'hand_in': false},
            {'id': 33, 'name': 'Cheque', 'journal': 'Cheques', 'kind': 'cheque', 'reference': 'cheque', 'hand_in': true},
          ],
          'online_providers': ['Razorpay'],
          if (withVan) ...{
            'van': {'id': 3, 'name': 'Van 1 · Ravi Kumar', 'vehicle': 'MH 02 AB 4521', 'main_warehouse': 'Main warehouse', 'self_load': false},
            'return_reasons': [
              {'value': 'damaged', 'label': 'Damaged', 'resellable': false},
              {'value': 'expired', 'label': 'Expired', 'resellable': false},
              {'value': 'not_selling', 'label': 'Not selling', 'resellable': true},
              {'value': 'wrong_item', 'label': 'Wrong item', 'resellable': true},
              {'value': 'other', 'label': 'Other', 'resellable': true},
            ],
          },
          if (supervisor) 'sales_dashboard': true,
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
              'default_code': p['code'],
              'barcode': p['barcode'],
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
      case 'beatpro.theme.get_sales_dashboard':
        final week = body['period'] == 'week';
        return {
          'period': body['period'],
          'route_id': body['route_id'],
          'routes': [
            {'id': 1, 'name': 'Andheri East'},
            {'id': 2, 'name': 'Powai'},
          ],
          'greeting_name': 'Meena Shah',
          'company': 'Mumbai Distributors Pvt Ltd',
          'kpis': [
            {'key': 'sales', 'label': 'Total sales', 'value': week ? '₹75,484.00' : '₹4,86,240.00', 'trend': 12.5, 'spark': [0, 10, 8, 30, 12, 18, 24], 'icon': 'fa-line-chart'},
            {'key': 'orders', 'label': 'Orders', 'value': week ? '5' : '243', 'trend': 8.7, 'spark': [0, 1, 1, 3, 0, 0, 0], 'icon': 'fa-shopping-bag'},
            {'key': 'shops', 'label': 'Active shops', 'value': '4', 'trend': -2.0, 'spark': [0, 1, 1, 3, 0, 0, 0], 'icon': 'fa-users'},
            {'key': 'collected', 'label': 'Collected', 'value': '₹34,600.00', 'trend': null, 'spark': [0, 10, 8, 30, 12, 18, 24], 'icon': 'fa-database'},
          ],
          'chart': [
            for (final (i, d) in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexed)
              {'label': d, 'amount': [8200, 12400, 9800, 21000, 11600, 7400, 5084][i].toDouble(), 'count': [1, 1, 0, 2, 1, 0, 0][i]},
          ],
          'chart_max_amount': 21000.0,
          'chart_max_count': 2,
          'categories': [
            {'name': 'Biscuits', 'share': 35},
            {'name': 'Staples', 'share': 30},
            {'name': 'Dairy', 'share': 20},
            {'name': 'Others', 'share': 15},
          ],
          'sales_total': '₹75,484.00',
          'top_shops': [
            {'id': 9, 'name': 'Patel Kirana', 'amount': '₹33,312.00'},
            {'id': 8, 'name': 'Sharma General Store', 'amount': '₹20,112.00'},
          ],
          'routes_sales': [
            {'name': 'Andheri East', 'amount': '₹38,612.00', 'pct': 100},
            {'name': 'Powai', 'amount': '₹26,872.00', 'pct': 70},
          ],
          'collected': '₹34,600.00',
          'due': '₹13,500.00',
          'collect_total': '₹48,100.00',
          'collected_pct': 72,
          'activity': [
            {'kind': 'order', 'text': 'Order S00243 · Patel Kirana · ₹9,824.00', 'time': '06 Nov, 04:25 PM'},
            {'kind': 'payment', 'text': '₹1,200.00 collected · Sharma General Store', 'time': '06 Nov, 03:50 PM'},
            {'kind': 'alert', 'text': 'Farah Khan: unload 1 short', 'time': '06 Nov, 03:30 PM'},
          ],
        };
      case 'beatpro.van.transfer.beatpro_van_stock':
        Map<String, dynamic> product(int id) => products.firstWhere((p) => p['id'] == id);
        return {
          'has_van': true,
          'van_items': [
            for (final e in van.entries)
              {'product_id': e.key, 'name': product(e.key)['name'], ...e.value, 'main_qty': product(e.key)['qty'], 'price': product(e.key)['price']},
          ],
          'main_items': [
            for (final p in products)
              if ((p['qty'] as double) > 0)
                {'product_id': p['id'], 'name': p['name'], 'loaded': 0, 'sold': 0, 'returned': 0, 'left': 0, 'main_qty': p['qty'], 'price': p['price']},
          ],
          'open_load': openLoad ?? false,
          'unload': unload ?? false,
        };
      case 'beatpro.van.transfer.beatpro_load_suggestion':
        return [
          {'product_id': 1, 'name': products[0]['name'], 'qty': 18, 'main_qty': 120},
          {'product_id': 3, 'name': products[2]['name'], 'qty': 10, 'main_qty': 64},
          {'product_id': 4, 'name': products[3]['name'], 'qty': 8, 'main_qty': 35},
        ];
      case 'beatpro.shop.return.beatpro_return_candidates':
        return [
          {'product_id': 4, 'name': products[3]['name'], 'last_date': '2026-10-22', 'price_unit': 480.0, 'bought': 4},
          {'product_id': 1, 'name': products[0]['name'], 'last_date': '2026-10-29', 'price_unit': 240.0, 'bought': 6},
        ];
      case 'beatpro.van.transfer.beatpro_submit_transfers':
        return {
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            v['mobile_uuid']: () {
              _record('$model.${v['kind']}', v);
              final id = _nextId++;
              final name = v['kind'] == 'load' ? 'LOAD/2026/00004' : 'UNLOAD/2026/00001';
              if (v['kind'] == 'load') {
                openLoad = {'id': id, 'name': name, 'state': 'sent'};
              } else {
                unload = {'id': id, 'name': name, 'state': 'sent'};
              }
              return {'id': id, 'name': name, 'state': 'sent'};
            }(),
        };
      case 'beatpro.shop.return.beatpro_submit_returns':
        return {
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            v['mobile_uuid']: () {
              _record(model, v);
              for (final l in (v['line_ids'] as List)) {
                final vals = (l as List)[2] as Map<String, dynamic>;
                if (vals['resellable'] != true) continue;
                final row = van[vals['product_id'] as int] ??= {'loaded': 0, 'sold': 0, 'returned': 0, 'left': 0};
                row['returned'] = row['returned']! + (vals['qty'] as num);
                row['left'] = row['left']! + (vals['qty'] as num);
              }
              return {'id': _nextId++, 'name': 'RET/2026/00001', 'state': 'done', 'amount_total': 1680.0, 'credit_note': 'RINV/2026/00003'};
            }(),
        };
      case 'sale.order.beatpro_submit_orders':
        return {
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            v['mobile_uuid']: () {
              _record(model, v);
              final mode = v['beatpro_delivery_mode'];
              if (mode == 'van' || mode == 'split') {
                for (final l in (v['order_line'] as List)) {
                  final vals = (l as List)[2] as Map<String, dynamic>;
                  final row = van[vals['product_id'] as int];
                  final qty = (vals['product_uom_qty'] as num).toDouble();
                  if (row == null || (mode == 'split' && row['left']! < qty)) continue;
                  row['sold'] = row['sold']! + qty;
                  row['left'] = row['left']! - qty;
                }
              }
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
      case 'account.payment.beatpro_payment_link':
        return {
          'link': 'https://mumbai.example.com/my/invoices/${body['invoice_id']}?access_token=abc123',
          'amount': body['amount'] ?? 1200.0,
          'invoice': 'INV/2026/00042',
          'providers': ['Razorpay'],
          'warning': false,
        };
      case 'account.payment.beatpro_invoice_status':
        return {
          for (final id in (body['invoice_ids'] as List)) '$id': {'name': 'INV/2026/00042', 'payment_state': 'paid', 'amount_due': 0.0, 'paid': onlinePaid},
        };
    }
    throw StateError('FakeOdoo has no answer for $model.$method');
  }

  void _record(String model, Map<String, dynamic> vals) => (uploaded[model] ??= []).add(vals);
}
