from datetime import timedelta

from odoo import fields
from odoo.exceptions import ValidationError
from odoo.fields import Command
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon


@tagged('post_install', '-at_install')
class TestBeatproSchemes(AccountTestInvoicingCommon):
    """Schemes (free goods, discounts), quantity prices, cases and pieces, credit warnings."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        company_ids = [(6, 0, cls.env.company.ids)]
        common = {'company_id': cls.env.company.id, 'company_ids': company_ids}
        cls.rep = new_test_user(cls.env, login='scheme_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(
            cls.env, login='scheme_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        cls.storekeeper = new_test_user(cls.env, login='scheme_store', groups='stock.group_stock_user', **common)
        cls.env.company.vat = '100234567800003'
        cls.vat5 = cls.env['account.tax'].create({
            'name': 'VAT 5%', 'amount': 5.0, 'amount_type': 'percent', 'type_tax_use': 'sale',
            'company_id': cls.env.company.id,
        })
        cls.env.ref('base.group_user').implied_ids += cls.env.ref('product.group_product_pricelist')
        cls.unit = cls.env.ref('uom.product_uom_unit')
        cls.case = cls.env['uom.uom'].create({'name': 'Case of 24', 'relative_factor': 24, 'relative_uom_id': cls.unit.id})
        cls.pricelist = cls.env['product.pricelist'].create({'name': 'Shops', 'currency_id': cls.env.company.currency_id.id})
        cls.shop = cls.env['res.partner'].create({'name': 'Al Madina Supermarket', 'property_product_pricelist': cls.pricelist.id})
        product = {'type': 'consu', 'is_storable': True, 'taxes_id': [Command.set(cls.vat5.ids)],
                   'uom_id': cls.unit.id, 'uom_ids': [Command.set(cls.case.ids)]}
        cls.oreo = cls.env['product.product'].create({'name': 'Oreo 36 g', 'list_price': 2.0, **product})
        cls.water = cls.env['product.product'].create({'name': 'Al Ain Water 500 ml', 'list_price': 1.0, **product})
        cls.main = cls.env['stock.warehouse'].search([('company_id', '=', cls.env.company.id)], limit=1)
        cls.van = cls.env['stock.warehouse'].browse(
            cls.env['stock.warehouse'].with_user(cls.supervisor).beatpro_create_van(cls.rep.id, 'D 12345'))
        Quant = cls.env['stock.quant']
        Quant._update_available_quantity(cls.oreo, cls.main.lot_stock_id, 1000)
        Quant._update_available_quantity(cls.water, cls.main.lot_stock_id, 1000)
        load = cls.env['beatpro.van.transfer'].with_user(cls.rep).create({
            'kind': 'load',
            'line_ids': [Command.create({'product_id': cls.oreo.id, 'qty': 300}),
                         Command.create({'product_id': cls.water.id, 'qty': 600})],
        })
        load.action_send()
        load.with_user(cls.storekeeper).action_load()
        cls.free_oreo = cls.env['beatpro.scheme'].with_user(cls.supervisor).create({
            'name': 'Oreo: buy 10 cases, get 1 free', 'kind': 'free_goods',
            'product_ids': [Command.set(cls.oreo.ids)], 'min_qty': 10, 'uom_id': cls.case.id, 'free_qty': 1,
        })

    def van_qty(self, product):
        return product.with_context(location=self.van.lot_stock_id.id).qty_available

    def submit(self, uuid, lines, **vals):
        return self.env['sale.order'].with_user(self.rep).beatpro_submit_orders([{
            'mobile_uuid': uuid, 'partner_id': self.shop.id, 'beatpro_delivery_mode': 'van',
            'order_line': [Command.create({'product_id': p.id, 'product_uom_qty': q, 'product_uom_id': u.id})
                           for p, q, u in lines],
            **vals,
        }])[uuid]

    def test_cases_and_pieces(self):
        units = self.env['product.product'].with_user(self.rep).beatpro_units(self.oreo.ids)[str(self.oreo.id)]
        self.assertEqual([(u['short'], u['factor']) for u in units], [('pc', 1.0), ('cs', 24.0)])
        self.assertEqual(self.oreo._beatpro_pack_text(29), '1 cs + 5 pc')
        self.assertEqual(self.oreo._beatpro_pack_text(48), '2 cs')
        self.assertEqual(self.oreo._beatpro_pack_text(0), '0 pc')
        stock = self.env['beatpro.van.transfer'].with_user(self.rep).beatpro_van_stock()
        item = next(i for i in stock['van_items'] if i['product_id'] == self.oreo.id)
        self.assertEqual(item['left_text'], '12 cs + 12 pc')

    def test_free_goods_leave_the_van(self):
        result = self.submit('scheme-1', [(self.oreo, 10, self.case), (self.water, 5, self.unit)],
                             beatpro_van_invoice_name='VAN/X/00001')
        order = self.env['sale.order'].browse(result['id'])
        self.assertEqual(order.state, 'sale')
        self.assertFalse(order.beatpro_approval_state, "A scheme's 100% off is not the rep's discount")
        free = order.order_line.filtered('beatpro_free')
        self.assertEqual((free.product_id, free.product_uom_qty, free.product_uom_id, free.discount),
                         (self.oreo, 1, self.case, 100))
        self.assertEqual(free.beatpro_scheme_id, self.free_oreo)
        # 11 cases left the van: 264 pieces of 300.
        self.assertEqual(self.van_qty(self.oreo), 300 - 264)
        # 10 cases at 48 + 5 water at 1, plus 5% VAT; the free case is worth 48.
        self.assertAlmostEqual(order.amount_untaxed, 485.0)
        self.assertAlmostEqual(result['saved'], 48.0)
        self.assertEqual(self.free_oreo.order_count, 1)

        invoice = order.sudo().invoice_ids
        self.assertAlmostEqual(invoice.amount_total, 509.25)
        html = self.env['ir.actions.report']._render_qweb_html(
            'beatpro_field_sales.report_invoice_slip_80', invoice.ids)[0].decode()
        for text in ('Oreo 36 g · FREE', 'FREE · Oreo: buy 10 cases, get 1 free', '10 cs x 48.00', '1 cs x 0.00', 'You saved'):
            self.assertIn(text, html)
        self.assertAlmostEqual(invoice._beatpro_slip_data()['saved'], 48.0)

    def test_schemes_follow_the_order(self):
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id,
            'order_line': [Command.create({'product_id': self.oreo.id, 'product_uom_qty': 230})],
        })
        order.action_beatpro_apply_schemes()
        self.assertFalse(order.order_line.filtered('beatpro_free'), "230 pieces is less than 10 cases")
        order.order_line.product_uom_qty = 480
        order.action_beatpro_apply_schemes()
        order.action_beatpro_apply_schemes()
        self.assertEqual(order.order_line.filtered('beatpro_free').product_uom_qty, 2, "20 cases: 2 free, once")

        # A scheme that has ended does nothing; one that ran on the day of an offline order still counts.
        self.free_oreo.date_to = fields.Date.today() - timedelta(days=1)
        order.action_beatpro_apply_schemes()
        self.assertFalse(order.order_line.filtered('beatpro_free'))
        order.date_order = fields.Datetime.now() - timedelta(days=2)
        order.action_beatpro_apply_schemes()
        self.assertTrue(order.order_line.filtered('beatpro_free'))

    def test_discount_scheme(self):
        self.env['beatpro.scheme'].with_user(self.supervisor).create({
            'name': 'Water 5% from 5 cases', 'kind': 'discount', 'product_ids': [Command.set(self.water.ids)],
            'min_qty': 5, 'uom_id': self.case.id, 'discount': 5,
        })
        result = self.submit('scheme-2', [(self.water, 6, self.case)])
        order = self.env['sale.order'].browse(result['id'])
        self.assertEqual(order.state, 'sale', 'Within the scheme, no approval needed')
        self.assertEqual(order.order_line.discount, 5)
        self.assertAlmostEqual(order.amount_untaxed, 6 * 24 * 0.95)
        schemes = self.env['beatpro.scheme'].with_user(self.rep).beatpro_schemes()
        by_name = {s['name']: s for s in schemes}
        self.assertEqual(by_name['Water 5% from 5 cases']['min_qty'], 120)
        self.assertEqual(by_name['Oreo: buy 10 cases, get 1 free']['free_product_id'], self.oreo.id)
        self.assertEqual(by_name['Oreo: buy 10 cases, get 1 free']['free_uom_id'], self.case.id)

    def test_scheme_rules(self):
        with self.assertRaises(ValidationError):
            self.env['beatpro.scheme'].with_user(self.supervisor).create({
                'name': 'Bundle', 'kind': 'free_goods', 'product_ids': [Command.set((self.oreo | self.water).ids)],
                'min_qty': 5, 'free_qty': 1,
            })
        with self.assertRaises(ValidationError):
            self.env['beatpro.scheme'].with_user(self.supervisor).create({
                'name': 'Too much', 'kind': 'discount', 'product_ids': [Command.set(self.water.ids)], 'discount': 120,
            })

    def test_quantity_prices(self):
        self.env['product.pricelist.item'].create({
            'pricelist_id': self.pricelist.id, 'applied_on': '0_product_variant', 'product_id': self.water.id,
            'min_quantity': 480, 'compute_price': 'fixed', 'fixed_price': 0.8,
        })
        breaks = self.env['product.pricelist'].with_user(self.rep).beatpro_price_breaks(
            self.pricelist.ids, (self.oreo | self.water).ids)[str(self.pricelist.id)]
        self.assertEqual(breaks, {str(self.water.id): [[480.0, 0.8]]})
        result = self.submit('slab-1', [(self.water, 20, self.case)])
        order = self.env['sale.order'].browse(result['id'])
        self.assertAlmostEqual(order.order_line.price_unit, 19.2, msg='20 cases at the 480-piece price')
        self.assertAlmostEqual(result['saved'], 20 * 24 * 0.2)

    def test_credit_warnings(self):
        self.env.company.account_use_credit_limit = True
        self.shop.credit_limit = 100.0
        old = fields.Date.today() - timedelta(days=70)
        invoice = self.env['account.move'].create({
            'move_type': 'out_invoice', 'partner_id': self.shop.id, 'invoice_date': old,
            'invoice_date_due': old + timedelta(days=30),
            'invoice_line_ids': [Command.create({'product_id': self.water.id, 'quantity': 500, 'price_unit': 1.0,
                                                 'tax_ids': False})],
        })
        invoice.action_post()
        credit = self.env['res.partner'].with_user(self.rep).beatpro_credit(self.shop.ids)[str(self.shop.id)]
        self.assertEqual(credit['limit'], 100.0)
        self.assertAlmostEqual(credit['owed'], 500.0)
        self.assertEqual(credit['overdue_name'], invoice.name)
        self.assertEqual(credit['overdue_days'], 40)
        order = self.env['sale.order'].with_user(self.rep).create({'partner_id': self.shop.id})
        self.assertIn('overdue for 40 days', order.beatpro_overdue_warning)
        # Warnings only: the order still goes through.
        result = self.submit('credit-1', [(self.water, 1, self.case)])
        self.assertEqual(result['state'], 'sale')
