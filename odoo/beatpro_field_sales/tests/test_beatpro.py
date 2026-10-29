from odoo import fields
from odoo.exceptions import AccessError, UserError, ValidationError
from odoo.tests import Form, new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon


@tagged('post_install', '-at_install')
class TestBeatpro(AccountTestInvoicingCommon):

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        company_ids = [(6, 0, cls.env.company.ids)]
        # Reps get no accounting rights: collections must still work for them.
        cls.rep = new_test_user(
            cls.env, login='beatpro_rep', groups='beatpro_field_sales.group_beatpro_rep',
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
            'weekday': str(fields.Date.context_today(cls.env.user).weekday()),
            'line_ids': [fields.Command.create({'partner_id': cls.shop.id})],
        })

    def _visit(self, user, **vals):
        return self.env['beatpro.visit'].with_user(user).create({
            'partner_id': self.shop.id, 'user_id': user.id, **vals,
        })

    def _invoice(self, amount):
        return self.init_invoice(
            'out_invoice', partner=self.shop, amounts=[amount], taxes=[], post=True,
            invoice_date=fields.Date.context_today(self.env.user))

    # ------------------------------------------------------------------
    # Sync API used by the mobile app
    # ------------------------------------------------------------------

    def test_upsert_skips_records_already_received(self):
        Visit = self.env['beatpro.visit'].with_user(self.rep)
        vals = {'mobile_uuid': 'visit-uuid-1', 'partner_id': self.shop.id, 'user_id': self.rep.id}
        first = Visit.beatpro_upsert([vals])
        second = Visit.beatpro_upsert([vals, dict(vals)])
        self.assertEqual(first, second)
        self.assertEqual(self.env['beatpro.visit'].sudo().search_count([('mobile_uuid', '=', 'visit-uuid-1')]), 1)

        customers = self.env['res.partner'].with_user(self.rep).beatpro_upsert([
            {'mobile_uuid': 'cust-1', 'name': 'New Shop', 'partner_latitude': 19.1, 'partner_longitude': 72.8},
        ])
        self.assertEqual(customers, self.env['res.partner'].with_user(self.rep).beatpro_upsert([
            {'mobile_uuid': 'cust-1', 'name': 'New Shop'},
        ]))

    def test_upsert_needs_mobile_id(self):
        with self.assertRaises(UserError):
            self.env['beatpro.visit'].with_user(self.rep).beatpro_upsert([{'partner_id': self.shop.id}])

    def test_app_context_and_today_plan(self):
        context = self.env['res.users'].with_user(self.rep).beatpro_app_context()
        self.assertEqual(context['user_id'], self.rep.id)
        self.assertTrue(context['is_rep'])
        self.assertFalse(context['is_supervisor'])
        self.assertEqual(context['discount_limit'], 5.0)
        self.assertTrue(context['currency']['name'])

        plan = self.env['beatpro.route'].with_user(self.rep).beatpro_today_plan()
        self.assertEqual([stop['partner_id'] for stop in plan], [self.shop.id])
        self.assertFalse(self.env['beatpro.route'].with_user(self.other_rep).beatpro_today_plan())

    def test_prices_follow_pricelist(self):
        pricelist = self.env['product.pricelist'].create({
            'name': 'Wholesale',
            'item_ids': [fields.Command.create({
                'applied_on': '0_product_variant', 'product_id': self.product.id,
                'compute_price': 'fixed', 'fixed_price': 90.0,
            })],
        })
        prices = self.env['product.pricelist'].with_user(self.rep).beatpro_prices(pricelist.ids, self.product.ids)
        self.assertEqual(prices, {str(pricelist.id): {str(self.product.id): 90.0}})

    def test_submit_orders_confirms_or_waits_for_approval(self):
        def order_vals(uuid, discount):
            return {
                'mobile_uuid': uuid,
                'partner_id': self.shop.id,
                'order_line': [fields.Command.create({
                    'product_id': self.product.id, 'product_uom_qty': 2, 'discount': discount,
                })],
            }

        SaleOrder = self.env['sale.order'].with_user(self.rep)
        result = SaleOrder.beatpro_submit_orders([order_vals('ok-1', 5.0), order_vals('big-1', 20.0)])
        self.assertEqual(result['ok-1']['state'], 'sale')
        self.assertEqual(result['ok-1']['amount_total'], 190.0)
        self.assertEqual(result['big-1']['state'], 'draft')
        self.assertEqual(result['big-1']['approval'], 'waiting')
        # A retry returns the same orders without creating new ones.
        self.assertEqual(SaleOrder.beatpro_submit_orders([order_vals('ok-1', 5.0)])['ok-1']['id'], result['ok-1']['id'])

        waiting = self.env['sale.order'].browse(result['big-1']['id'])
        with self.assertRaises(AccessError):
            waiting.with_user(self.rep).action_beatpro_approve()
        waiting.with_user(self.supervisor).action_beatpro_approve()
        self.assertEqual(waiting.state, 'sale')
        self.assertEqual(waiting.beatpro_approval_state, 'approved')

    def test_discount_limit_applies_in_web_client(self):
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id,
            'order_line': [fields.Command.create({
                'product_id': self.product.id, 'product_uom_qty': 1, 'discount': 10.0,
            })],
        })
        with self.assertRaises(UserError):
            order.action_confirm()
        order.action_beatpro_request_approval()
        self.assertEqual(order.beatpro_approval_state, 'waiting')

    def test_register_payment_settles_invoices(self):
        invoice = self._invoice(500.0)
        visit = self._visit(self.rep)
        Payment = self.env['account.payment'].with_user(self.rep)
        vals = {
            'mobile_uuid': 'pay-1', 'partner_id': self.shop.id, 'amount': 500.0,
            'beatpro_method': 'cash', 'beatpro_visit_id': visit.id, 'invoice_ids': invoice.ids,
        }
        result = Payment.beatpro_register_payment([vals])
        self.assertEqual(Payment.beatpro_register_payment([vals]), result)
        payment = self.env['account.payment'].browse(result['pay-1'])
        self.assertEqual(payment.state, 'paid')
        self.assertEqual(payment.beatpro_user_id, self.rep)
        self.assertEqual(payment.journal_id.type, 'cash')
        self.assertEqual(invoice.payment_state, 'paid')
        self.assertEqual(visit.amount_collected, 500.0)
        # The rep sees their own collection but not other payments.
        self.assertEqual(Payment.search([]), payment)

        with self.assertRaises(UserError):
            Payment.beatpro_register_payment([{
                'mobile_uuid': 'pay-2', 'partner_id': self.shop.id, 'amount': 10.0, 'beatpro_method': 'card',
            }])
        with self.assertRaises(ValidationError):
            Payment.beatpro_register_payment([{
                'mobile_uuid': 'pay-3', 'partner_id': self.shop.id, 'amount': 10.0, 'beatpro_method': 'cheque',
            }])

    def test_open_invoices(self):
        invoice = self._invoice(250.0)
        invoices = self.env['res.partner'].with_user(self.rep).beatpro_open_invoices(self.shop.ids)
        self.assertEqual([(i['id'], i['amount_due']) for i in invoices], [(invoice.id, 250.0)])

    # ------------------------------------------------------------------
    # Working in the Odoo web client, without the app
    # ------------------------------------------------------------------

    def test_check_in_and_out(self):
        visit = self._visit(self.rep, route_id=self.route.id)
        self.assertTrue(visit.name.startswith('VIS/'))
        visit.action_check_in(latitude=19.1136, longitude=72.8697)
        self.assertEqual(visit.state, 'in_progress')
        self.assertAlmostEqual(visit.check_in_latitude, 19.1136)
        self.assertEqual(visit.action_open_map()['type'], 'ir.actions.act_url')
        with self.assertRaises(UserError):
            visit.action_check_in()
        with self.assertRaises(UserError):
            visit.action_check_out()  # no result and no order
        with self.assertRaises(ValidationError):
            visit.action_check_out(result='no_order')  # reason missing
        visit.action_check_out(result='no_order', no_order_reason='enough_stock')
        self.assertEqual(visit.state, 'done')
        self.assertEqual(visit.result, 'no_order')

    def test_my_day_web_flow(self):
        RouteLine = self.env['beatpro.route.line'].with_user(self.rep)
        # The My Day menu runs a server action: reps must be allowed to run it.
        action = self.env.ref('beatpro_field_sales.action_server_beatpro_my_day').with_user(self.rep).run()
        stops = RouteLine.search(action['domain'])
        self.assertEqual(stops.partner_id, self.shop)
        self.assertEqual(stops.today_status, 'to_visit')

        visit = self.env['beatpro.visit'].browse(stops.action_start_visit()['res_id'])
        self.assertEqual(stops.action_start_visit()['res_id'], visit.id, "Starting again opens the same visit")
        with self.assertRaises(UserError):
            visit.with_user(self.rep).action_new_order()  # not checked in yet
        visit.with_user(self.rep).action_check_in()
        stops.invalidate_recordset()
        self.assertEqual(stops.today_status, 'in_progress')

        order_action = visit.with_user(self.rep).action_new_order()
        with Form(self.env['sale.order'].with_user(self.rep).with_context(order_action['context'])) as order_form:
            with order_form.order_line.new() as line:
                line.product_id = self.product
                line.product_uom_qty = 4
        order = order_form.save()
        order.action_confirm()
        self.assertEqual(order.beatpro_visit_id, visit)

        invoice = self._invoice(400.0)
        wizard = self.env['beatpro.payment.wizard'].browse(
            visit.with_user(self.rep).action_collect_payment()['res_id']).with_user(self.rep)
        self.assertEqual(wizard.amount_due, 400.0)
        wizard.line_ids.selected = True
        wizard.write({'amount': 400.0, 'method': 'upi', 'upi_reference': 'UPI-98765'})
        wizard.action_confirm()
        self.assertEqual(invoice.payment_state, 'paid')

        visit.with_user(self.rep).action_check_out()
        self.assertEqual(visit.result, 'order')
        stops.invalidate_recordset()
        self.assertEqual(stops.today_status, 'visited')

        close = self.env['beatpro.day.close'].with_user(self.rep).create({})
        close.action_close()
        self.assertEqual((close.visit_count, close.order_count, close.order_amount), (1, 1, 400.0))
        self.assertEqual((close.upi_amount, close.total_collected), (400.0, 400.0))

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
        self.assertIn(theirs, self.env['beatpro.visit'].with_user(self.supervisor).search([]))

    def test_closed_day_is_locked(self):
        close = self.env['beatpro.day.close'].with_user(self.rep).create({})
        close.action_close()
        self.assertEqual(close.state, 'closed')
        with self.assertRaises(UserError):
            close.write({'distance_km': 42.0})
        with self.assertRaises(UserError):
            close.action_reopen()
        close.with_user(self.supervisor).action_reopen()
        self.assertEqual(close.state, 'draft')
