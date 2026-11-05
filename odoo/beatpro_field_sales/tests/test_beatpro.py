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
        # Payment methods for reps: Cash, UPI (with a reference) and Cheques.
        cls.cash_line = cls.company_data['default_journal_cash'].inbound_payment_method_line_ids[:1]
        cls.upi_line = cls.company_data['default_journal_bank'].inbound_payment_method_line_ids[:1]
        cls.upi_line.write({'beatpro_label': 'UPI', 'beatpro_reference': 'reference'})
        cheques = cls.env['account.journal'].create({'name': 'Cheques', 'code': 'CHQ', 'type': 'bank'})
        cls.cheque_line = cheques.inbound_payment_method_line_ids[:1]
        cls.cheque_line.write({'beatpro_label': 'Cheque', 'beatpro_reference': 'cheque'})
        (cls.env['account.payment.method.line'].search([
            ('journal_id.company_id', '=', cls.env.company.id), ('payment_type', '=', 'inbound'),
        ]) - cls.cash_line - cls.upi_line - cls.cheque_line).beatpro_show = False

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
            'payment_method_line_id': self.cash_line.id, 'beatpro_visit_id': visit.id, 'invoice_ids': invoice.ids,
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
                'mobile_uuid': 'pay-2', 'partner_id': self.shop.id, 'amount': 10.0, 'payment_method_line_id': 999999,
            }])
        with self.assertRaises(ValidationError):
            Payment.beatpro_register_payment([{
                'mobile_uuid': 'pay-3', 'partner_id': self.shop.id, 'amount': 10.0, 'payment_method_line_id': self.cheque_line.id,
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
        self.assertEqual([label for _value, label in wizard._selection_method()], ['Cash', 'UPI', 'Cheque'])
        wizard.write({'amount': 400.0, 'method': str(self.upi_line.id), 'reference': 'UPI-98765'})
        self.assertEqual(wizard.method_reference, 'reference')
        wizard.action_confirm()
        self.assertEqual(invoice.payment_state, 'paid')

        visit.with_user(self.rep).action_check_out()
        self.assertEqual(visit.result, 'order')
        stops.invalidate_recordset()
        self.assertEqual(stops.today_status, 'visited')

        close = self.env['beatpro.day.close'].with_user(self.rep).create({})
        close.action_close()
        self.assertEqual((close.visit_count, close.order_count, close.order_amount), (1, 1, 400.0))
        self.assertEqual((close.bank_amount, close.handover_amount, close.total_collected), (400.0, 0.0, 400.0))

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
        close.action_close()  # a retry from the app is harmless
        with self.assertRaises(UserError):
            close.write({'distance_km': 42.0})
        with self.assertRaises(UserError):
            close.action_reopen()
        close.with_user(self.supervisor).action_reopen()
        self.assertEqual(close.state, 'draft')

    # ------------------------------------------------------------------
    # New screens: My Day, visit panel, overview, day close
    # ------------------------------------------------------------------

    def test_my_day_data(self):
        RouteLine = self.env['beatpro.route.line'].with_user(self.rep)
        data = RouteLine.beatpro_my_day_data()
        self.assertEqual((data['done'], data['planned'], data['left']), (0, 1, 1))
        self.assertEqual(data['next']['name'], 'Sharma General Store')
        self.assertFalse(data['next_is_current'])
        self.assertEqual(data['stops'][0]['status'], 'to_visit')

        visit = self.env['beatpro.visit'].browse(
            RouteLine.browse(data['next']['line_id']).action_start_visit()['res_id']).with_user(self.rep)
        visit.action_check_in()
        data = RouteLine.beatpro_my_day_data()
        self.assertTrue(data['next_is_current'])
        visit.action_check_out(result='closed')
        data = RouteLine.beatpro_my_day_data()
        self.assertEqual((data['done'], data['left']), (1, 0))
        self.assertEqual(data['stops'][0]['status'], 'visited')
        self.assertFalse(data['next'])

    def test_visit_panel_data(self):
        self.shop.write({'partner_latitude': 19.1136, 'partner_longitude': 72.8697})
        self._invoice(300.0)
        visit = self._visit(self.rep)
        self.assertEqual(visit.beatpro_panel_data()['state'], 'planned')
        visit.action_check_in(latitude=19.1137, longitude=72.8697)
        self.env['account.payment'].with_user(self.rep).beatpro_register_payment([{
            'mobile_uuid': 'panel-pay', 'partner_id': self.shop.id, 'amount': 120.0,
            'payment_method_line_id': self.cash_line.id, 'beatpro_visit_id': visit.id,
        }])
        data = visit.beatpro_panel_data()
        self.assertEqual(data['state'], 'in_progress')
        self.assertIn('m from the shop pin', data['location'])
        self.assertTrue(data['has_due'])
        self.assertEqual([item['kind'] for item in data['items']], ['payment'])
        visit.action_check_out(result='no_order', no_order_reason='credit', note='Owner asked to come back')
        self.assertEqual(visit.note, 'Owner asked to come back')

    def test_overview_dashboard(self):
        with self.assertRaises(AccessError):
            self.env['beatpro.dashboard'].with_user(self.rep).get_data()
        visit = self._visit(self.rep)
        visit.action_check_in()
        visit.action_check_out(result='no_order', no_order_reason='enough_stock')
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id,
            'order_line': [fields.Command.create({'product_id': self.product.id, 'product_uom_qty': 1, 'discount': 10.0})],
        })
        order.action_beatpro_request_approval()

        data = self.env['beatpro.dashboard'].with_user(self.supervisor).get_data('today')
        self.assertEqual(data['visits_done'], 1)
        self.assertEqual(data['visits_planned'], 1)
        self.assertEqual(data['approval_count'], 1)
        self.assertEqual(data['reasons'][0]['count'], 1)
        ravi = next(r for r in data['reps'] if r['id'] == self.rep.id)
        self.assertEqual(ravi['visits'], '1 / 1')
        # The supervisor took an order in the office: it counts, but they aren't a field rep.
        office = self.env['sale.order'].with_user(self.supervisor).create({
            'partner_id': self.shop.id,
            'order_line': [fields.Command.create({'product_id': self.product.id, 'product_uom_qty': 1})],
        })
        office.action_confirm()
        data = self.env['beatpro.dashboard'].with_user(self.supervisor).get_data('today')
        self.assertNotIn(self.supervisor.id, [r['id'] for r in data['reps']])
        self.assertEqual(data['order_count'], 2)
        for period in ('week', 'month'):
            self.assertEqual(self.env['beatpro.dashboard'].with_user(self.supervisor).get_data(period)['period'], period)

    def test_day_close_handover(self):
        self.env['account.payment'].with_user(self.rep).beatpro_register_payment([
            {'mobile_uuid': 'h-cash', 'partner_id': self.shop.id, 'amount': 500.0, 'beatpro_method': 'cash'},
            {'mobile_uuid': 'h-chq', 'partner_id': self.shop.id, 'amount': 200.0, 'beatpro_method': 'cheque',
             'beatpro_cheque_number': '000123'},
            {'mobile_uuid': 'h-upi', 'partner_id': self.shop.id, 'amount': 50.0, 'beatpro_method': 'upi'},
        ])
        close = self.env['beatpro.day.close'].with_user(self.rep).create({})
        # Figures are there as soon as the day close is created.
        self.assertEqual((close.handover_amount, close.total_collected, close.cheque_count), (700.0, 750.0, 1))
        self.assertEqual(self.route.with_user(self.supervisor).order_rate, 0)
        # Close the day from My Day opens today's close, not a second one.
        action = self.env['beatpro.day.close'].with_user(self.rep).action_open_today()
        self.assertEqual(action['res_id'], close.id)

    # ------------------------------------------------------------------
    # Payment methods from Odoo and online payment
    # ------------------------------------------------------------------

    def test_app_gets_payment_methods_from_odoo(self):
        context = self.env['res.users'].with_user(self.rep).beatpro_app_context()
        methods = context['payment_methods']
        self.assertEqual([m['name'] for m in methods], ['Cash', 'UPI', 'Cheque'])
        self.assertEqual([m['kind'] for m in methods], ['cash', 'bank', 'cheque'])
        self.assertEqual([m['reference'] for m in methods], ['none', 'reference', 'cheque'])
        self.assertEqual([m['hand_in'] for m in methods], [True, False, True])

        self.upi_line.beatpro_show = False
        names = [m['name'] for m in self.env['res.users'].with_user(self.rep).beatpro_app_context()['payment_methods']]
        self.assertNotIn('UPI', names)
        # A method hidden from reps can't be used, even by an app that still shows it.
        with self.assertRaises(UserError):
            self.env['account.payment'].with_user(self.rep).beatpro_register_payment([{
                'mobile_uuid': 'hidden', 'partner_id': self.shop.id, 'amount': 5.0,
                'payment_method_line_id': self.upi_line.id,
            }])

    def test_payment_recorded_on_chosen_method(self):
        result = self.env['account.payment'].with_user(self.rep).beatpro_register_payment([{
            'mobile_uuid': 'upi-1', 'partner_id': self.shop.id, 'amount': 75.0,
            'payment_method_line_id': self.upi_line.id, 'beatpro_reference': '430912345678',
        }])
        payment = self.env['account.payment'].browse(result['upi-1'])
        self.assertEqual(payment.payment_method_line_id, self.upi_line)
        self.assertEqual(payment.journal_id, self.upi_line.journal_id)
        self.assertEqual((payment.beatpro_method, payment.beatpro_reference), ('bank', '430912345678'))
        panel = self._visit(self.rep)
        self.assertEqual(self.upi_line.beatpro_display_name, 'UPI')
        self.assertTrue(panel)

    def test_online_payment_link(self):
        invoice = self._invoice(640.0)
        Payment = self.env['account.payment'].with_user(self.rep)
        self.env['payment.provider'].search([('company_id', '=', self.env.company.id)]).state = 'disabled'
        with self.assertRaises(UserError):
            Payment.beatpro_payment_link(invoice.id)
        self.assertFalse(self.env['res.users'].with_user(self.rep).beatpro_app_context()['online_providers'])

        provider = self.env['payment.provider'].create({'name': 'Test Gateway', 'state': 'test', 'company_id': self.env.company.id})
        self.assertEqual(self.env['res.users'].with_user(self.rep).beatpro_app_context()['online_providers'], ['Test Gateway'])
        info = Payment.beatpro_payment_link(invoice.id)
        self.assertIn('/my/invoices/', info['link'])
        self.assertIn('access_token=', info['link'])
        self.assertEqual((info['amount'], info['invoice'], info['providers']), (640.0, invoice.name, [provider.name]))
        self.assertEqual(Payment.beatpro_payment_link(invoice.id, amount=200.0)['amount'], 200.0)
        status = Payment.beatpro_invoice_status([invoice.id])[str(invoice.id)]
        self.assertFalse(status['paid'])
        self.assertEqual(status['amount_due'], 640.0)

        # The same from the Odoo web form.
        visit = self._visit(self.rep)
        visit.action_check_in()
        wizard = self.env['beatpro.payment.wizard'].browse(
            visit.with_user(self.rep).action_collect_payment()['res_id']).with_user(self.rep)
        self.assertTrue(wizard.online_enabled)
        with self.assertRaises(UserError):
            wizard.action_payment_link()  # no invoice selected
        wizard.line_ids.filtered(lambda l: l.invoice_id == invoice.id).selected = True
        wizard.action_payment_link()
        self.assertIn('access_token=', wizard.online_link)
        self.assertTrue(wizard.online_qr)

