{
    'name': 'BeatPro Theme',
    'version': '19.0.1.0.0',
    'category': 'Themes/Backend',
    'summary': "BeatPro Van Sales look for every Odoo screen: maroon theme, side menu, sales dashboard, own sign-in page",
    'description': """
BeatPro Theme
=============
* Maroon BeatPro Van Sales colours on every backend screen (forms, lists, kanban, buttons, status bars)
* Left side menu with the screens a van sales team uses every day
* Van Sales Dashboard: sales, orders, active shops, collections, sales by day, category, shop and route
* BeatPro sign-in page, browser title, favicon and app name; Odoo's name and links removed from
  the web client, sign-in page, portal and emails
""",
    'author': 'BeatPro',
    'license': 'LGPL-3',
    'depends': ['beatpro_field_sales', 'portal', 'mail'],
    'data': [
        'data/ir_config_parameter_data.xml',
        'views/webclient_templates.xml',
        'views/beatpro_theme_views.xml',
    ],
    'assets': {
        'web._assets_primary_variables': [
            ('before', 'web/static/src/scss/primary_variables.scss',
             'beatpro_theme/static/src/scss/primary_variables.scss'),
        ],
        'web.assets_backend': [
            'beatpro_theme/static/src/scss/theme.scss',
            'beatpro_theme/static/src/sidebar/*',
            'beatpro_theme/static/src/dashboard/*',
            'beatpro_theme/static/src/debrand.js',
        ],
        'web.assets_frontend': [
            'beatpro_theme/static/src/login/login.scss',
        ],
    },
    'installable': True,
    'application': False,
}
