{
    'name': 'BeatPro Field Sales',
    'version': '19.0.1.0.0',
    'category': 'Sales/Sales',
    'summary': 'Routes, shop visits and day-end close for field sales reps using the BeatPro mobile app',
    'description': """
BeatPro Field Sales
===================
Server side of the BeatPro mobile app for Odoo Community.

* Routes (beat plans): which customers each rep visits, and on which weekday
* Visits: check-in and check-out with GPS, visit result and reason
* Day-end close: each rep's orders and collections for the day
* Idempotent sync: every record made on the phone carries a mobile UUID,
  so a retried upload never creates a duplicate
* Rep and Supervisor access groups
""",
    'author': 'BeatPro',
    'license': 'LGPL-3',
    'depends': ['sale_stock', 'account'],
    'data': [
        'security/beatpro_security.xml',
        'security/ir.model.access.csv',
        'data/ir_sequence_data.xml',
        'views/beatpro_route_views.xml',
        'views/beatpro_visit_views.xml',
        'views/beatpro_day_close_views.xml',
        'views/res_users_views.xml',
        'views/sale_order_views.xml',
        'views/account_payment_views.xml',
        'views/beatpro_menus.xml',
    ],
    'installable': True,
    'application': True,
}
