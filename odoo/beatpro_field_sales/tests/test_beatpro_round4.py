from datetime import timedelta

from odoo import fields
from odoo.exceptions import AccessError
from odoo.fields import Command
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon

from ..models.beatpro_route_plan import path_km, shortest_order


@tagged('post_install', '-at_install')
class TestBeatproRound4(AccountTestInvoicingCommon):
    """Route planning, customer statements and sales reports."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        common = {'company_id': cls.env.company.id, 'company_ids': [(6, 0, cls.env.company.ids)]}
        cls.rep = new_test_user(cls.env, login='r4_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(cls.env, login='r4_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        Partner = cls.env['res.partner']
        # Along a line going east: A (far), B (near), C (middle).
        cls.a = Partner.create({'name': 'Shop A', 'partner_latitude': 25.20, 'partner_longitude': 55.40})
        cls.b = Partner.create({'name': 'Shop B', 'partner_latitude': 25.20, 'partner_longitude': 55.21})
        cls.c = Partner.create({'name': 'Shop C', 'partner_latitude': 25.20, 'partner_longitude': 55.30})
        cls.nopin = Partner.create({'name': 'Shop without pin'})
        cls.env.company.partner_id.write({'partner_latitude': 25.20, 'partner_longitude': 55.20})
        cls.today = fields.Date.context_today(cls.env.user)
        cls.route = cls.env['beatpro.route'].with_user(cls.supervisor).create({
            'name': 'East', 'user_id': cls.rep.id, 'weekday': False,
            'line_ids': [Command.create({'partner_id': p.id, 'sequence': i}) for i, p in enumerate([cls.nopin, cls.a, cls.b, cls.c])],
        })

    # -- Route planning -----------------------------------------------------------------

    def test_shortest_order(self):
        start = (0.0, 0.0)
        points = [(0.0, 3.0), (0.0, 1.0), (0.0, 2.0)]
        order = shortest_order(start, points)
        self.assertEqual(order, [1, 2, 0])
        self.assertLess(path_km(start, [points[i] for i in order]), path_km(start, points))

    def test_route_uses_shortest_order(self):
        route = self.route
        self.assertEqual(route.unpinned_count, 1)
        self.assertLess(route.shortest_km, route.distance_km)
        route.with_user(self.supervisor).action_beatpro_shortest_order()
        self.assertEqual(route.line_ids.sorted('sequence').partner_id, self.b | self.c | self.a | self.nopin)
        self.assertAlmostEqual(route.distance_km, route.shortest_km, places=3)

    def test_moves_change_the_plan(self):
        Move = self.env['beatpro.route.move'].with_user(self.rep)
        Move.beatpro_submit_moves([
            {'mobile_uuid': 'mv-1', 'partner_id': self.a.id, 'route_id': self.route.id, 'kind': 'tomorrow',
             'date': fields.Date.to_string(self.today)},
            {'mobile_uuid': 'mv-2', 'partner_id': self.b.id, 'route_id': self.route.id, 'kind': 'skip',
             'date': fields.Date.to_string(self.today)},
        ])
        plan = {p['partner_id']: p for p in self.env['beatpro.route'].with_user(self.rep).beatpro_today_plan()}
        self.assertNotIn(self.a.id, plan, 'moved to tomorrow')
        self.assertTrue(plan[self.b.id]['skipped'])
        move = self.env['beatpro.route.move'].sudo().search([('mobile_uuid', '=', 'mv-1')])
        self.assertEqual(move.to_date, self.today + timedelta(days=1))
        # The day before: a shop moved from yesterday comes today, at the end.
        other = self.env['res.partner'].create({'name': 'Moved shop'})
        self.env['beatpro.route.move'].sudo().create({'user_id': self.rep.id, 'partner_id': other.id, 'kind': 'tomorrow',
                                               'date': self.today - timedelta(days=1)})
        plan = self.env['beatpro.route'].with_user(self.rep).beatpro_today_plan()
        self.assertEqual(plan[-1]['partner_id'], other.id)
        self.assertTrue(plan[-1]['moved_in'])

    # -- Statements -----------------------------------------------------------------------

    def test_statement(self):
        shop = self.a
        old = self.init_invoice('out_invoice', partner=shop, amounts=[500], taxes=[], post=False,
                                invoice_date=self.today.replace(day=1) - timedelta(days=40))
        old.write({'invoice_payment_term_id': False, 'invoice_date_due': old.invoice_date})
        old.action_post()
        inv = self.init_invoice('out_invoice', partner=shop, amounts=[300], taxes=[], post=True, invoice_date=self.today)
        refund = self.init_invoice('out_refund', partner=shop, amounts=[50], taxes=[], post=True, invoice_date=self.today)
        statement = self.env['res.partner'].with_user(self.rep).beatpro_statement(shop.id, 'this_month')
        self.assertAlmostEqual(statement['opening'], 500)
        self.assertEqual([l['kind'] for l in statement['lines']], ['invoice', 'credit_note'])
        self.assertAlmostEqual(statement['closing'], 750)
        self.assertAlmostEqual(statement['ageing']['older'] + statement['ageing']['d60'] + statement['ageing']['d30'], 500)
        self.env.company.beatpro_statement_note = 'Pay to IBAN AE07 0331'
        wizard = self.env['beatpro.statement.wizard'].create({'partner_id': shop.id})
        action = wizard.action_print()
        self.assertEqual(action['report_name'], 'beatpro_field_sales.report_beatpro_statement')
        html = self.env['ir.actions.report']._render_qweb_html(
            'beatpro_field_sales.report_beatpro_statement', shop.ids, data=action['data'])[0].decode()
        for text in ('STATEMENT OF ACCOUNT', 'كشف حساب', inv.name, refund.name, 'Opening balance', 'IBAN AE07 0331'):
            self.assertIn(text, html)
        self.assertTrue(old)

    # -- Sales reports -------------------------------------------------------------------

    def test_sales_reports(self):
        move = self.init_invoice('out_invoice', partner=self.c, amounts=[1000], taxes=[], post=False, invoice_date=self.today)
        move.invoice_user_id = self.rep
        move.action_post()
        lost = self.init_invoice('out_invoice', partner=self.b, amounts=[200], taxes=[], post=True,
                                 invoice_date=self.today - timedelta(days=45))
        self.env['beatpro.visit'].with_user(self.rep).create({
            'partner_id': self.c.id, 'user_id': self.rep.id, 'state': 'done',
            'check_in': fields.Datetime.now() - timedelta(minutes=30)})
        with self.assertRaises(AccessError):
            self.env['beatpro.reports'].with_user(self.rep).beatpro_sales_reports()
        data = self.env['beatpro.reports'].with_user(self.supervisor).beatpro_sales_reports('this_month')
        self.assertEqual(data['kpis']['active'], 1, 'Shop C bought this month')
        self.assertEqual(data['kpis']['shops'], 4)
        self.assertIn('Shop B', [s['name'] for s in data['lost']])
        rep = next(r for r in data['reps'] if r['name'] == self.rep.name)
        self.assertGreaterEqual(rep['planned'], 4)
        self.assertGreaterEqual(rep['visited'], 1)
        self.assertTrue(lost)
