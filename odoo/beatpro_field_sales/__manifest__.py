{
    'name': 'BeatPro Field Sales',
    'version': '19.0.1.10.0',
    'category': 'Sales/Sales',
    'summary': 'Routes, shop visits and day-end close for field sales reps using the BeatPro mobile app',
    'description': """
BeatPro Field Sales
===================
Server side of the BeatPro mobile app for Odoo Community.

* Routes (beat plans): which customers each rep visits, and on which weekday
* Visits: check-in and check-out with GPS, visit result and reason
* Van sales: morning van load, deliveries from the van or the main warehouse,
  goods taken back from shops with a reason, day-end unload with counted stock
* Schemes: free goods and quantity discounts, applied on the phone and again in Odoo
* Cases and pieces: sell and count stock in a product's packagings
* Credit warnings: credit limit and overdue invoices shown before taking an order
* Targets and incentives for reps paid on salary + incentive, with commission lines
* Shelf photos and shop surveys taken during visits, also offline
* Live map of reps and today's routes for supervisors
* Rep expenses (fuel, parking, Salik...) from the app, approved by supervisors and posted
* Day-end cash hand over counted by accountants; differences approved and written off
* Inventory for supervisors: van stock, low warehouse stock against the next 7 days,
  expiring lots (vans load the earliest expiry first), returns and stock lost by rep
* Day-end close: each rep's orders and collections for the day
* Idempotent sync: every record made on the phone carries a mobile UUID,
  so a retried upload never creates a duplicate
* Rep and Supervisor access groups
""",
    'author': 'BeatPro',
    'license': 'LGPL-3',
    'depends': ['sale_stock', 'account', 'account_payment', 'product_expiry'],
    'data': [
        'security/beatpro_security.xml',
        'security/ir.model.access.csv',
        'data/ir_sequence_data.xml',
        'data/beatpro_expense_data.xml',
        'views/beatpro_route_views.xml',
        'views/beatpro_visit_views.xml',
        'views/beatpro_day_close_views.xml',
        'views/res_users_views.xml',
        'views/sale_order_views.xml',
        'views/account_payment_views.xml',
        'views/beatpro_my_day_views.xml',
        'views/res_partner_views.xml',
        'views/account_payment_method_views.xml',
        'views/account_move_views.xml',
        'report/beatpro_invoice_slip.xml',
        'report/beatpro_statement.xml',
        'views/beatpro_scheme_views.xml',
        'views/beatpro_growth_views.xml',
        'views/beatpro_expense_views.xml',
        'views/res_config_settings_views.xml',
        'wizard/beatpro_payment_wizard_views.xml',
        'views/beatpro_van_views.xml',
        'views/beatpro_shop_return_views.xml',
        'views/beatpro_inventory_views.xml',
        'views/beatpro_menus.xml',
    ],
    'assets': {
        'web.assets_backend': [
            'beatpro_field_sales/static/src/scss/*.scss',
            'beatpro_field_sales/static/src/**/*.js',
            'beatpro_field_sales/static/src/**/*.xml',
        ],
    },
    'installable': True,
    'application': True,
}
