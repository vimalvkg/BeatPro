from odoo import fields
from odoo.exceptions import AccessError, UserError, ValidationError
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon


@tagged('post_install', '-at_install')
class TestBeatpro(AccountTestInvoicingCommon):

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        company_ids = [(6, 0, cls.env.company.ids)]
        cls.rep = new_test_user(
            cls.env, login='beatpro_rep', groups='beatpro_field_sales.group_beatpro_rep,account.group_account_invoice',
            company_id=cls.env.company.id, company_ids=company_ids, beatpro_discount_limit=5.0)
        cls.other_rep = new_test_user(
            cls.env, login='beatpro_rep2', groups='beatpro_field_sales.group_beatpro_rep',
            company_id=cls.env.company.id, company_ids=company_ids)
        cls.supervisor = new_test_user(
            cls.env, login='beatpro_sup', groups='beatpro_field_sales.group_beatpro_supervisor',
            company_id=cls.env.company.id, company_ids=company_ids)
        cls.shop = cls.env['res.partner'].create({'name': 'Sharma General Store'})
        cls.product = cls.env['product.product'].create({
            'name': 'Biscuits Box', 'type': 'consu', 'list_price': 100.0, 'taxes_id': False,
        })
        cls.route = cls.env['beatpro.route'].with_user(cls.supervisor).create({
            'name': 'Andheri East',
            'user_id': cls.rep.id,
            'line_ids': [fields.Command.create({'partner_id': cls.shop.id})],
        })

    def _visit(self, user, **vals):
        return self.env['beatpro.visit'].with_user(user).create({
            'partner_id': self.shop.id, 'user_id': user.id, **vals,
        })

    def test_upsert_skips_records_already_received(self):
        Visit = self.env['beatpro.visit'].with_user(self.rep)
        vals = {'mobile_uuid': 'visit-uuid-1', 'partner_id': self.shop.id, 'user_id': self.rep.id}
        first = Visit.beatpro_upsert([vals])
        second = Visit.beatpro_upsert([vals, dict(vals)])
        self.assertEqual(first, second)
        self.assertEqual(self.env['beatpro.visit'].sudo().search_count([('mobile_uuid', '=', 'visit-uuid-1')]), 1)

        orders = self.env['sale.order'].with_user(self.rep).beatpro_upsert([
            {'mobile_uuid': 'order-uuid-1', 'partner_id': self.shop.id},
        ])
        again = self.env['sale.order'].with_user(self.rep).beatpro_upsert([
            {'mobile_uuid': 'order-uuid-1', 'partner_id': self.shop.id},
        ])
        self.assertEqual(orders, again)

    def test_upsert_needs_mobile_id(self):
        with self.assertRaises(UserError):
            self.env['beatpro.visit'].with_user(self.rep).beatpro_upsert([{'partner_id': self.shop.id}])

    def test_check_in_and_out(self):
        visit = self._visit(self.rep, route_id=self.route.id)
        self.assertTrue(visit.name.startswith('VIS/'))
        visit.action_check_in(latitude=19.1136, longitude=72.8697)
        self.assertEqual(visit.state, 'in_progress')
        self.assertAlmostEqual(visit.check_in_latitude, 19.1136)
        with self.assertRaises(UserError):
            visit.action_check_in()
        with self.assertRaises(UserError):
            visit.action_check_out()  # no result and no order
        with self.assertRaises(ValidationError):
            visit.action_check_out(result='no_order')  # reason missing
        visit.action_check_out(result='no_order', no_order_reason='enough_stock')
        self.assertEqual(visit.state, 'done')
        self.assertEqual(visit.result, 'no_order')

    def test_reps_see_only_their_own_records(self):
        mine = self._visit(self.rep)
        theirs = self._visit(self.other_rep)
        visible = self.env['beatpro.visit'].with_user(self.rep).search([])
        self.assertIn(mine, visible)
        self.assertNotIn(theirs, visible)
        with self.assertRaises(AccessError):
            theirs.with_user(self.rep).read(['name'])
        self.assertFalse(self.env['beatpro.route'].with_user(self.other_rep).search([]))
        with self.assertRaises(AccessError):
            self.route.with_user(self.rep).write({'name': 'Renamed'})
        all_visits = self.env['beatpro.visit'].with_user(self.supervisor).search([])
        self.assertIn(theirs, all_visits)

    def test_today_plan(self):
        self.route.weekday = str(fields.Date.context_today(self.route).weekday())
        plan = self.env['beatpro.route'].with_user(self.rep).beatpro_today_plan()
        self.assertEqual([stop['partner_id'] for stop in plan], [self.shop.id])
        self.assertFalse(self.env['beatpro.route'].with_user(self.other_rep).beatpro_today_plan())

    def test_discount_limit_on_app_orders(self):
        def make_order(user, uuid):
            return self.env['sale.order'].with_user(user).create({
                'partner_id': self.shop.id,
                'mobile_uuid': uuid,
                'order_line': [fields.Command.create({
                    'product_id': self.product.id, 'product_uom_qty': 1, 'discount': 10.0,
                })],
            })

        with self.assertRaises(UserError):
            make_order(self.rep, 'order-disc-1').action_confirm()
        order = make_order(self.supervisor, 'order-disc-2')
        order.action_confirm()
        self.assertEqual(order.state, 'sale')

    def test_day_close_totals(self):
        visit = self._visit(self.rep)
        visit.action_check_in()
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id,
            'beatpro_visit_id': visit.id,
            'order_line': [fields.Command.create({'product_id': self.product.id, 'product_uom_qty': 3})],
        })
        order.action_confirm()
        visit.action_check_out()
        self.assertEqual(visit.result, 'order')
        self.assertEqual(visit.amount_ordered, 300.0)

        Payment = self.env['account.payment'].with_user(self.rep)
        Payment.create({
            'payment_type': 'inbound', 'partner_type': 'customer', 'partner_id': self.shop.id,
            'amount': 200.0, 'beatpro_method': 'cash', 'beatpro_visit_id': visit.id,
        })
        Payment.create({
            'payment_type': 'inbound', 'partner_type': 'customer', 'partner_id': self.shop.id,
            'amount': 50.0, 'beatpro_method': 'upi', 'beatpro_upi_reference': 'UPI123',
        })
        with self.assertRaises(ValidationError):
            Payment.create({
                'payment_type': 'inbound', 'partner_type': 'customer', 'partner_id': self.shop.id,
                'amount': 10.0, 'beatpro_method': 'cheque',
            })
        self.assertEqual(visit.amount_collected, 200.0)

        close = self.env['beatpro.day.close'].with_user(self.rep).create({})
        close.action_close()
        self.assertEqual(close.state, 'closed')
        self.assertEqual((close.visit_count, close.visit_order_count, close.order_count), (1, 1, 1))
        self.assertEqual(close.order_amount, 300.0)
        self.assertEqual((close.cash_amount, close.upi_amount, close.total_collected), (200.0, 50.0, 250.0))

        with self.assertRaises(UserError):
            close.write({'distance_km': 42.0})
        with self.assertRaises(UserError):
            close.action_reopen()
        close.with_user(self.supervisor).action_reopen()
        self.assertEqual(close.state, 'draft')
