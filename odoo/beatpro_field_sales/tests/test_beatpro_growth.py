import base64
from datetime import timedelta

from odoo import fields
from odoo.exceptions import AccessError
from odoo.fields import Command
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon

# A 1x1 PNG.
PIXEL = base64.b64encode(bytes.fromhex(
    '89504e470d0a1a0a0000000d4948445200000001000000010806000000'
    '1f15c4890000000d4944415478da63f8ffff3f0005fe02fea7d6a5bc0000000049454e44ae426082')).decode()


@tagged('post_install', '-at_install')
class TestBeatproGrowth(AccountTestInvoicingCommon):
    """Targets and incentives, shop photos and surveys, and the live map."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        company_ids = [(6, 0, cls.env.company.ids)]
        common = {'company_id': cls.env.company.id, 'company_ids': company_ids}
        cls.rep = new_test_user(cls.env, login='growth_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.salaried = new_test_user(cls.env, login='growth_salary', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(
            cls.env, login='growth_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        cls.shop = cls.env['res.partner'].create({'name': 'Al Madina Supermarket', 'partner_latitude': 25.2399, 'partner_longitude': 55.3046})
        cls.shop2 = cls.env['res.partner'].create({'name': 'City Stores', 'partner_latitude': 25.2711, 'partner_longitude': 55.3075})
        cls.shop3 = cls.env['res.partner'].create({'name': 'Quick Stop', 'partner_latitude': 25.2048, 'partner_longitude': 55.2422})
        cls.plan = cls.env['beatpro.incentive.plan'].with_user(cls.supervisor).create({
            'name': 'Van sales',
            'line_ids': [Command.create({'threshold': 10000, 'rate': 5}), Command.create({'threshold': 40000, 'rate': 2})],
        })
        cls.rep.write({'beatpro_pay_type': 'incentive', 'beatpro_incentive_plan_id': cls.plan.id})
        cls.today = fields.Date.context_today(cls.env.user)
        cls.route = cls.env['beatpro.route'].with_user(cls.supervisor).create({
            'name': 'Karama', 'user_id': cls.rep.id, 'weekday': str(cls.today.weekday()),
            'line_ids': [Command.create({'partner_id': p.id, 'sequence': i}) for i, p in enumerate([cls.shop, cls.shop2, cls.shop3])],
        })

    def _invoice(self, amount, move_type='out_invoice', user=None):
        move = self.init_invoice(move_type, partner=self.shop, amounts=[amount], taxes=[], post=False,
                                 invoice_date=self.today)
        move.invoice_user_id = (user or self.rep).id
        move.action_post()
        return move

    # -- Incentives ------------------------------------------------------------------

    def test_commission_lines(self):
        plan = self.plan
        self.assertEqual(plan._commission(9000, 0), 0)
        # Each part at its own rate: 5% on 10,000 to 40,000, 2% above.
        self.assertAlmostEqual(plan._commission(50000, 0), 30000 * 0.05 + 10000 * 0.02)
        plan.method = 'whole'
        self.assertAlmostEqual(plan._commission(50000, 0), 50000 * 0.02)
        self.assertAlmostEqual(plan._commission(20000, 0), 20000 * 0.05)
        self.assertIn('AED', plan.example_text) if self.env.company.currency_id.name == 'AED' else None

        by_target = self.env['beatpro.incentive.plan'].with_user(self.supervisor).create({
            'name': 'By target', 'slab_basis': 'target', 'method': 'whole',
            'line_ids': [Command.create({'threshold': 80, 'rate': 1}), Command.create({'threshold': 100, 'rate': 2, 'bonus': 500})],
        })
        self.assertEqual(by_target._commission(47000, 60000), 0)
        self.assertAlmostEqual(by_target._commission(50000, 60000), 500)
        self.assertAlmostEqual(by_target._commission(60000, 60000), 1200 + 500)
        self.assertEqual(by_target._next_step(50000, 60000), (60000, 2, 500))

    def test_target_from_invoices(self):
        target = self.env['beatpro.target'].with_user(self.supervisor).create({
            'user_id': self.rep.id, 'month': self.today, 'amount': 60000,
        })
        self.assertEqual(target.month, self.today.replace(day=1))
        self.assertEqual(target.plan_id, self.plan)
        self._invoice(30000)
        self._invoice(25000)
        self._invoice(5000, 'out_refund')
        self._invoice(99999, user=self.salaried)
        target.invalidate_recordset()
        self.assertAlmostEqual(target.achieved, 50000, msg='invoiced, less the credit note, for this rep only')
        self.assertAlmostEqual(target.earned, 1700)

        card = self.env['beatpro.target'].with_user(self.rep).beatpro_my_target()
        self.assertAlmostEqual(card['achieved'], 50000)
        self.assertEqual(len(card['lines']), 2)
        self.assertFalse(card['next_step'], 'every line is reached')
        self.assertFalse(self.env['beatpro.target'].with_user(self.salaried).beatpro_my_target(),
                         'reps on salary only see no target')

        board = self.env['beatpro.target'].with_user(self.supervisor).beatpro_targets_board()
        rows = {r['user_id']: r for r in board['rows']}
        self.assertEqual(rows[self.rep.id]['target'], 60000)
        self.assertEqual(rows[self.salaried.id]['pay_type'], 'salary')
        self.assertNotIn('target', rows[self.salaried.id])
        self.assertAlmostEqual(rows[self.salaried.id]['sold'], 99999)
        with self.assertRaises(AccessError):
            self.env['beatpro.target'].with_user(self.rep).beatpro_targets_board()

        with self.assertRaises(AccessError):
            target.with_user(self.rep).action_approve()
        target.with_user(self.supervisor).action_approve()
        self.assertEqual(target.state, 'approved')
        self.assertAlmostEqual(target.approved_amount, 1700)

    def test_product_targets_in_cases(self):
        unit = self.env.ref('uom.product_uom_unit')
        case = self.env['uom.uom'].create({'name': 'Case of 24', 'relative_factor': 24, 'relative_uom_id': unit.id})
        oreo = self.env['product.product'].create({'name': 'Oreo', 'uom_id': unit.id, 'uom_ids': [Command.set(case.ids)]})
        self.plan.product_target_bonus = 100
        target = self.env['beatpro.target'].with_user(self.supervisor).create({
            'user_id': self.rep.id, 'month': self.today, 'amount': 1000000,
            'line_ids': [Command.create({'product_id': oreo.id, 'qty': 2})],
        })
        self.assertEqual(target.line_ids.uom_id, case, 'counted in cases')
        move = self.init_invoice('out_invoice', partner=self.shop, products=[oreo], taxes=[], post=False, invoice_date=self.today)
        move.invoice_user_id = self.rep.id
        move.invoice_line_ids.write({'quantity': 48, 'price_unit': 1})
        move.action_post()
        target.invalidate_recordset()
        self.assertEqual(target.line_ids.achieved_qty, 2)
        self.assertAlmostEqual(target.earned, 100, msg='no commission yet, but the product target is met')

    # -- Photos and surveys ---------------------------------------------------------------

    def test_shop_survey_with_photos(self):
        survey = self.env['beatpro.survey'].with_user(self.supervisor).create({
            'name': 'Monthly shelf check', 'user_ids': [Command.set(self.rep.ids)],
            'question_ids': [Command.create({'name': 'Display stand in place?', 'kind': 'yes_no'}),
                             Command.create({'name': 'Tiger price', 'kind': 'price', 'suffix': 'per piece'})],
            'photo_ids': [Command.create({'tag': 'Main shelf', 'count': 2})],
        })
        due = self.env['beatpro.survey'].with_user(self.rep).beatpro_surveys()
        self.assertEqual(due['due'][str(self.shop.id)], survey.ids)
        self.assertEqual(due['surveys'][0]['photos'], [{'tag': 'Main shelf', 'count': 2}])

        visit = self.env['beatpro.visit'].with_user(self.rep).create({'partner_id': self.shop.id, 'user_id': self.rep.id})
        q1, q2 = survey.question_ids
        vals = [{'visit_id': visit.id,
                 'photos': [{'mobile_uuid': 'ph-1', 'image': PIXEL, 'tag': 'Main shelf', 'latitude': 25.2, 'longitude': 55.3}],
                 'answers': [{'survey_id': survey.id, 'question_id': q1.id, 'value': True},
                             {'survey_id': survey.id, 'question_id': q2.id, 'value': '1.50'}]}]
        Visit = self.env['beatpro.visit'].with_user(self.rep)
        self.assertEqual(Visit.beatpro_submit_extras(vals), ['ph-1'])
        Visit.beatpro_submit_extras(vals)
        self.assertEqual(len(visit.photo_ids), 1, 'a retry adds no second photo')
        self.assertEqual(visit.answer_ids.mapped('value'), ['Yes', '1.50'])
        self.assertAlmostEqual(visit.answer_ids[1].value_number, 1.5)
        self.assertNotIn(str(self.shop.id), Visit.env['beatpro.survey'].beatpro_surveys()['due'],
                         'monthly: done at this shop for the month')

        other = self.env['beatpro.visit'].with_user(self.supervisor).create({'partner_id': self.shop2.id, 'user_id': self.salaried.id})
        with self.assertRaises(AccessError):
            Visit.beatpro_submit_extras([{'visit_id': other.id, 'photos': [], 'answers': []}])

    # -- Live map -----------------------------------------------------------------------

    def test_live_map(self):
        Location = self.env['beatpro.location'].with_user(self.rep)
        now = fields.Datetime.now()
        points = [{'mobile_uuid': 'loc-%s' % i, 'at': fields.Datetime.to_string(now - timedelta(minutes=10 - i * 5)),
                   'latitude': 25.24 + i / 1000, 'longitude': 55.30} for i in range(3)]
        self.assertEqual(Location.beatpro_submit_locations(points), 3)
        Location.beatpro_submit_locations(points)
        self.assertEqual(self.env['beatpro.location'].sudo().search_count([('user_id', '=', self.rep.id)]), 3)

        # Visited the second shop, not the first: the first is missed, the third is next.
        self.env['beatpro.visit'].with_user(self.rep).create({
            'partner_id': self.shop2.id, 'user_id': self.rep.id, 'state': 'done',
            'check_in': now - timedelta(minutes=30), 'check_out': now - timedelta(minutes=20)})
        data = self.env['beatpro.location'].with_user(self.supervisor).beatpro_live_map()
        rep = next(r for r in data['reps'] if r['user_id'] == self.rep.id)
        self.assertEqual(len(rep['trail']), 3)
        self.assertEqual([s['status'] for s in rep['stops']], ['missed', 'visited', 'next'])
        self.assertIn('Seen', rep['where'])
        with self.assertRaises(AccessError):
            self.env['beatpro.location'].with_user(self.rep).beatpro_live_map()

        self.rep.beatpro_track_location = False
        self.assertEqual(Location.beatpro_submit_locations([dict(points[0], mobile_uuid='loc-off')]), 0)
