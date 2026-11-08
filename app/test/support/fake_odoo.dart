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

  /// Odoo gives van invoices another number than the phone's (it was used meanwhile).
  bool renumberInvoices = false;

  /// The user is a supervisor with the Van Sales Dashboard.
  bool supervisor = false;

  /// Parle-G sells by the piece (AED 10) and in cases of 24, with a scheme
  /// "buy 10 cases, get 1 free"; Maggi drops to 540 from 10; Patel Kirana is
  /// over its credit limit with an overdue invoice.
  bool withSchemes = false;

  /// The rep is paid on salary + incentive (with a target), shares their location,
  /// and Patel Kirana has a monthly shelf check due.
  bool withGrowth = false;

  /// Expenses the rep sent, with their approval.
  final expenses = <Map<String, dynamic>>[];

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
    signIns.add({...params, 'header_db': request.headers['X-Odoo-Database']});
    final ok = params['login'] == 'ravi@beatpro.test' && params['password'] == 'ravi123';
    final result = ok
        ? {'api_key': 'k' * 40, 'database': 'gulffoods', 'expires': '2027-11-06'}
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
          'lang': 'en_US',
          'tz': 'Asia/Dubai',
          'company_id': 1,
          'company_name': 'Gulf Foods Distribution LLC',
          'currency': {'id': 130, 'name': 'AED', 'symbol': 'د.إ', 'position': 'after', 'decimals': 2},
          'is_rep': true,
          'is_supervisor': false,
          'discount_limit': 5.0,
          'expense_categories': [
            {'id': 1, 'name': 'Fuel'},
            {'id': 2, 'name': 'Parking'},
            {'id': 3, 'name': 'Salik toll'},
          ],
          'pay_type': withGrowth ? 'incentive' : 'salary',
          'track_location': withGrowth,
          'location_minutes': 5,
          'payment_methods': [
            {'id': 31, 'name': 'Cash', 'journal': 'Field Cash', 'kind': 'cash', 'reference': 'none', 'hand_in': true},
            {'id': 32, 'name': 'Bank transfer', 'journal': 'Bank', 'kind': 'bank', 'reference': 'reference', 'hand_in': false},
            {'id': 33, 'name': 'Cheque', 'journal': 'Cheques', 'kind': 'cheque', 'reference': 'cheque', 'hand_in': true},
          ],
          'online_providers': ['Razorpay'],
          if (withVan) ...{
            'van': {'id': 3, 'name': 'Van 1 · Ravi Kumar', 'vehicle': 'MH 02 AB 4521', 'main_warehouse': 'Main warehouse', 'self_load': false},
            'van_invoice': {
              'journal': 'VAN1',
              'year': DateTime.now().year,
              'next': 147,
              'padding': 5,
              'paper': '80',
              'company': {'name': 'Gulf Foods Distribution LLC', 'trn': '100234567800003', 'address': 'Al Quoz Industrial 3, Dubai', 'phone': '+971 4 330 1234'},
            },
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
              'property_product_pricelist': [1, 'Default (AED)'],
              'vat': s['id'] == 9 ? '100987654300003' : false,
            },
        ];
      case 'product.product.search_read':
        return [
          for (final p in products)
            {
              'id': p['id'],
              'display_name': p['name'],
              'lst_price': withSchemes && p['id'] == 1 ? 10.0 : p['price'],
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
          '1': {
            for (final p in products) '${p['id']}': p['id'] == 2 ? 560.0 : (withSchemes && p['id'] == 1 ? 10.0 : p['price']),
          },
        };
      case 'product.product.beatpro_units':
        return {
          for (final id in (body['product_ids'] as List))
            '$id': [
              {'id': 1, 'name': 'Units', 'short': 'pc', 'factor': 1.0},
              if (withSchemes && id == 1) {'id': 7, 'name': 'Case of 24', 'short': 'cs', 'factor': 24.0},
            ],
        };
      case 'product.pricelist.beatpro_price_breaks':
        return {
          for (final id in (body['pricelist_ids'] as List))
            '$id': {
              if (withSchemes)
                '2': [
                  [10.0, 540.0],
                ],
            },
        };
      case 'beatpro.scheme.beatpro_schemes':
        return [
          if (withSchemes)
            {
              'id': 3,
              'name': 'Parle-G: buy 10 cases, get 1 free',
              'kind': 'free_goods',
              'product_ids': [1],
              'min_qty': 240.0,
              'min_label': '10 Case of 24',
              'discount': 0.0,
              'free_product_id': 1,
              'free_qty': 1.0,
              'free_uom_id': 7,
              'date_to': false,
              'rule': 'Buy 10 Case of 24, get 1 Case of 24 Parle-G free',
            },
        ];
      case 'beatpro.target.beatpro_my_target':
        return withGrowth
            ? {
                'id': 1, 'month': '2026-11-01', 'month_label': 'November', 'target': 60000.0, 'achieved': 42300.0,
                'progress': 70.5, 'earned': 1615.0, 'projected': 55100.0, 'projected_earned': 1902.0, 'days_left': 23,
                'per_day': 769.57, 'plan': 'Van sales · standard', 'method': 'tiered', 'approved': false,
                'next_step': null,
                'lines': [
                  {'from': 'From AED 10,000.00', 'from_amount': 10000.0, 'rate': 5.0, 'bonus': 0.0, 'text': '5% on each part'},
                  {'from': 'From AED 40,000.00', 'from_amount': 40000.0, 'rate': 2.0, 'bonus': 0.0, 'text': '2% on each part'},
                ],
                'product_bonus': 100.0,
                'products': [
                  {'product_id': 1, 'name': 'Parle-G Biscuits (Box of 24)', 'qty': 200.0, 'achieved': 132.0, 'unit': 'cs'},
                ],
              }
            : false;
      case 'beatpro.survey.beatpro_surveys':
        return {
          'surveys': [
            if (withGrowth)
              {
                'id': 4,
                'name': 'Monthly shelf check',
                'frequency': 'month',
                'questions': [
                  {'id': 41, 'name': 'Is our display stand in place?', 'kind': 'yes_no', 'choices': [], 'suffix': '', 'required': true},
                  {'id': 42, 'name': 'Shelf facings for Parle-G', 'kind': 'number', 'choices': [], 'suffix': 'facings', 'required': true},
                  {'id': 43, 'name': 'Where is our product placed?', 'kind': 'choice', 'choices': ['Eye level', 'Top shelf'], 'suffix': '', 'required': false},
                ],
                'photos': [
                  {'tag': 'Main shelf', 'count': 2},
                ],
              },
          ],
          'due': {
            if (withGrowth) '9': [4],
          },
          'photo_tags': ['Main shelf', 'Display stand', 'Competitor', 'Out of stock', 'Price label'],
        };
      case 'beatpro.visit.beatpro_submit_extras':
        for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>()) {
          _record('beatpro.visit.extras', v);
        }
        return [
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            for (final p in (v['photos'] as List)) (p as Map)['mobile_uuid'],
        ];
      case 'beatpro.expense.beatpro_submit_expenses':
        return {
          for (final v in (body['vals_list'] as List).cast<Map<String, dynamic>>())
            v['mobile_uuid']: () {
              _record('beatpro.expense', v);
              expenses.add({
                'id': _nextId, 'mobile_uuid': v['mobile_uuid'], 'date': v['date'], 'category': 'Fuel',
                'category_id': v['category_id'], 'amount': v['amount'], 'paid_from': v['paid_from'],
                'note': v['note'], 'state': 'waiting', 'reject_reason': false,
              });
              return {'id': _nextId++, 'state': 'waiting'};
            }(),
        };
      case 'beatpro.expense.beatpro_my_expenses':
        return expenses;
      case 'beatpro.location.beatpro_submit_locations':
        for (final p in (body['points'] as List).cast<Map<String, dynamic>>()) {
          _record('beatpro.location', p);
        }
        return (body['points'] as List).length;
      case 'res.partner.beatpro_credit':
        return {
          for (final id in (body['partner_ids'] as List))
            '$id': withSchemes && id == 9
                ? {'limit': 1000.0, 'owed': 1200.0, 'overdue_name': 'INV/2026/00042', 'overdue_days': 25, 'overdue_amount': 1200.0}
                : {'limit': 0.0, 'owed': 0.0, 'overdue_name': false, 'overdue_days': 0, 'overdue_amount': 0.0},
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
            {'key': 'sales', 'label': 'Total sales', 'value': week ? 'AED 75,484.00' : 'AED 4,86,240.00', 'trend': 12.5, 'spark': [0, 10, 8, 30, 12, 18, 24], 'icon': 'fa-line-chart'},
            {'key': 'orders', 'label': 'Orders', 'value': week ? '5' : '243', 'trend': 8.7, 'spark': [0, 1, 1, 3, 0, 0, 0], 'icon': 'fa-shopping-bag'},
            {'key': 'shops', 'label': 'Active shops', 'value': '4', 'trend': -2.0, 'spark': [0, 1, 1, 3, 0, 0, 0], 'icon': 'fa-users'},
            {'key': 'collected', 'label': 'Collected', 'value': 'AED 34,600.00', 'trend': null, 'spark': [0, 10, 8, 30, 12, 18, 24], 'icon': 'fa-database'},
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
          'sales_total': 'AED 75,484.00',
          'top_shops': [
            {'id': 9, 'name': 'Patel Kirana', 'amount': 'AED 33,312.00'},
            {'id': 8, 'name': 'Sharma General Store', 'amount': 'AED 20,112.00'},
          ],
          'routes_sales': [
            {'name': 'Andheri East', 'amount': 'AED 38,612.00', 'pct': 100},
            {'name': 'Powai', 'amount': 'AED 26,872.00', 'pct': 70},
          ],
          'collected': 'AED 34,600.00',
          'due': 'AED 13,500.00',
          'collect_total': 'AED 48,100.00',
          'collected_pct': 72,
          'activity': [
            {'kind': 'order', 'text': 'Order S00243 · Patel Kirana · AED 9,824.00', 'time': '06 Nov, 04:25 PM'},
            {'kind': 'payment', 'text': 'AED 1,200.00 collected · Sharma General Store', 'time': '06 Nov, 03:50 PM'},
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
              final invoiceName = v['beatpro_van_invoice_name'];
              return {
                'id': _nextId++,
                'name': 'S0004${_nextId % 10}',
                'state': 'sale',
                'approval': false,
                'amount_total': 1321.6,
                'invoice': invoiceName == null
                    ? false
                    : {'id': _nextId++, 'name': renumberInvoices ? 'VAN1/2026/00999' : invoiceName, 'amount_total': 504.0},
              };
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
          'link': 'https://gulffoods.example.com/my/invoices/${body['invoice_id']}?access_token=abc123',
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
