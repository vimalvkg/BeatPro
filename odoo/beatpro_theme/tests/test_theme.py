from lxml import etree

from odoo import fields
from odoo.exceptions import AccessError
from odoo.fields import Command
from odoo.tests import HttpCase, new_test_user, tagged
from odoo.tools import file_path

from odoo.addons.account.tests.common import AccountTestInvoicingCommon


@tagged('post_install', '-at_install')
class TestBeatproTheme(AccountTestInvoicingCommon):

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        common = {'company_id': cls.env.company.id, 'company_ids': [(6, 0, cls.env.company.ids)]}
        cls.rep = new_test_user(cls.env, login='theme_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(
            cls.env, login='theme_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        cls.shop = cls.env['res.partner'].create({'name': 'Patel Kirana'})
        cls.route = cls.env['beatpro.route'].with_user(cls.supervisor).create({
            'name': 'Andheri East', 'user_id': cls.rep.id,
            'line_ids': [Command.create({'partner_id': cls.shop.id})],
        })
        categ = cls.env['product.category'].create({'name': 'Biscuits'})
        cls.product = cls.env['product.product'].create({
            'name': 'Parle-G', 'type': 'consu', 'list_price': 100.0, 'taxes_id': False, 'categ_id': categ.id,
        })

    def test_side_menu_follows_access(self):
        rep_items = {i['key']: i for i in self.env['beatpro.theme'].with_user(self.rep).beatpro_sidebar()['items']}
        my_day = self.env.ref('beatpro_field_sales.action_beatpro_my_day_screen')
        self.assertEqual(rep_items['dashboard']['action_id'], my_day.id, "reps land on My Day")
        self.assertEqual(rep_items['vans']['action_id'], self.env.ref('beatpro_field_sales.action_beatpro_my_van').id)
        self.assertIn('orders', rep_items)
        self.assertNotIn('settings', rep_items)
        self.assertNotIn('invoices', rep_items, "reps have no accounting rights")

        sup_items = {i['key']: i for i in self.env['beatpro.theme'].with_user(self.supervisor).beatpro_sidebar()['items']}
        self.assertEqual(sup_items['dashboard']['action_id'], self.env.ref('beatpro_theme.action_van_sales_dashboard').id)
        self.assertEqual(sup_items['vans']['action_id'], self.env.ref('beatpro_field_sales.action_beatpro_van_desk').id)
        self.assertNotIn('settings', sup_items)
        admin_items = self.env['beatpro.theme'].with_user(self.env.ref('base.user_admin')).beatpro_sidebar()['items']
        self.assertIn('settings', {i['key'] for i in admin_items})

    def test_sales_dashboard(self):
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id,
            'order_line': [Command.create({'product_id': self.product.id, 'product_uom_qty': 3})],
        })
        order.action_confirm()
        Dashboard = self.env['beatpro.theme'].with_user(self.supervisor)
        for period in ('week', 'month', 'quarter', 'year'):
            data = Dashboard.get_sales_dashboard(period)
            kpis = {k['key']: k for k in data['kpis']}
            self.assertEqual(kpis['orders']['value'], '1', period)
            self.assertEqual(kpis['shops']['value'], '1')
            self.assertEqual(sum(c['count'] for c in data['chart']), 1)
        self.assertEqual(data['categories'], [{'name': 'Biscuits', 'share': 100}])
        self.assertEqual(data['top_shops'][0]['name'], 'Patel Kirana')
        self.assertEqual(data['routes_sales'][0]['name'], 'Andheri East')
        self.assertIn('S', data['activity'][0]['text'])
        self.assertEqual(len(Dashboard.get_sales_dashboard('week')['chart']), 7)

        other_route = self.env['beatpro.route'].with_user(self.supervisor).create({'name': 'Powai', 'user_id': self.rep.id})
        self.assertEqual(Dashboard.get_sales_dashboard('month', other_route.id)['kpis'][1]['value'], '0')

        with self.assertRaises(AccessError):
            self.env['beatpro.theme'].with_user(self.rep).get_sales_dashboard()

    def test_emails_have_no_odoo_promotion(self):
        for xmlid in ('mail.mail_notification_layout', 'mail.mail_notification_light'):
            arch = etree.tostring(self.env.ref(xmlid)._get_combined_arch(), encoding='unicode')
            self.assertNotIn('Powered by', arch, xmlid)
            self.assertIn('mail_unfollow', arch, xmlid)


@tagged('post_install', '-at_install')
class TestBeatproThemePages(HttpCase):

    def test_sign_in_page_is_branded(self):
        page = self.url_open('/web/login').text
        self.assertIn('bp-login', page)
        self.assertIn('Drive sales.', page)
        self.assertNotIn('Powered by', page)
        self.assertIn('<title>BeatPro', page.replace('\n', ''))
        self.assertIn('/beatpro_theme/static/img/favicon.png', page)

    def test_logo_when_company_has_none(self):
        self.env.company.logo = False
        with open(file_path('beatpro_theme/static/img/logo_full.png'), 'rb') as f:
            ours = f.read()
        self.assertEqual(self.url_open('/web/binary/company_logo').content, ours)
        self.env.company.logo = self.env.company._get_logo()  # Odoo's "Your logo" placeholder
        self.assertEqual(self.url_open('/web/binary/company_logo').content, ours)

    def test_installed_app_name(self):
        manifest = self.url_open('/web/manifest.webmanifest').json()
        self.assertEqual(manifest['name'], 'BeatPro')
