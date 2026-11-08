from odoo import fields
from odoo.exceptions import AccessError, UserError
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon


@tagged('post_install', '-at_install')
class TestBeatproCash(AccountTestInvoicingCommon):
    """Rep expenses and the day-end cash hand over."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        common = {'company_id': cls.env.company.id, 'company_ids': [(6, 0, cls.env.company.ids)]}
        cls.rep = new_test_user(cls.env, login='cash_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(cls.env, login='cash_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        cls.accountant = new_test_user(cls.env, login='cash_acc', groups='account.group_account_user', **common)
        cls.shop = cls.env['res.partner'].create({'name': 'Al Madina Supermarket'})
        cls.cash_line = cls.company_data['default_journal_cash'].inbound_payment_method_line_ids[:1]
        cheques = cls.env['account.journal'].create({'name': 'Cheques', 'code': 'CHQ', 'type': 'bank'})
        cls.cheque_line = cheques.inbound_payment_method_line_ids[:1]
        cls.cheque_line.write({'beatpro_label': 'Cheque', 'beatpro_reference': 'cheque'})
        cls.env.company.beatpro_field_cash_journal_id = cls.company_data['default_journal_cash']
        company = cls.env.company
        if not company.default_cash_difference_expense_account_id:
            company.default_cash_difference_expense_account_id = cls.env['account.account'].create(
                {'name': 'Cash Difference Loss', 'code': '999001', 'account_type': 'expense'})
        cls.today = fields.Date.context_today(cls.env.user)
        cls.fuel = cls.env.ref('beatpro_field_sales.expense_category_fuel')
        cls.parking = cls.env.ref('beatpro_field_sales.expense_category_parking')
        cls.salik = cls.env.ref('beatpro_field_sales.expense_category_salik')

    def _collect(self, uuid, amount, line, **extra):
        return self.env['account.payment'].with_user(self.rep).beatpro_register_payment([{
            'mobile_uuid': uuid, 'partner_id': self.shop.id, 'amount': amount,
            'payment_method_line_id': line.id, **extra}])[uuid]

    def _expenses(self):
        return self.env['beatpro.expense'].with_user(self.rep).beatpro_submit_expenses([
            {'mobile_uuid': 'exp-fuel', 'category_id': self.fuel.id, 'amount': 120, 'paid_from': 'cash', 'note': 'ENOC Al Quoz',
             'date': fields.Date.to_string(self.today)},
            {'mobile_uuid': 'exp-park', 'category_id': self.parking.id, 'amount': 8, 'paid_from': 'own',
             'date': fields.Date.to_string(self.today)},
            {'mobile_uuid': 'exp-salik', 'category_id': self.salik.id, 'amount': 16, 'paid_from': 'card',
             'date': fields.Date.to_string(self.today)},
        ])

    def _close_day(self):
        close = self.env['beatpro.day.close'].with_user(self.rep).create({'user_id': self.rep.id, 'date': self.today})
        close.action_close()
        return close

    def test_expenses_are_approved_and_posted(self):
        result = self._expenses()
        self.assertEqual(result['exp-fuel']['state'], 'waiting')
        self.assertEqual(self._expenses()['exp-fuel']['id'], result['exp-fuel']['id'], 'a retry adds nothing')
        Expense = self.env['beatpro.expense']
        fuel, park, salik = (Expense.browse(result[k]['id']) for k in ('exp-fuel', 'exp-park', 'exp-salik'))
        self.assertEqual(len(Expense.with_user(self.rep).beatpro_my_expenses()), 3)
        with self.assertRaises(AccessError):
            fuel.with_user(self.rep).action_approve()

        (fuel | park).with_user(self.supervisor).action_approve()
        cash_account = self.company_data['default_journal_cash'].default_account_id
        self.assertEqual(fuel.move_id.state, 'posted')
        self.assertEqual(fuel.move_id.line_ids.filtered(lambda l: l.credit).account_id, cash_account)
        owed = park.move_id.line_ids.filtered(lambda l: l.credit)
        self.assertEqual(owed.account_id, self.env.company.beatpro_reimburse_account_id, 'owed to the rep')
        self.assertEqual(owed.partner_id, self.rep.partner_id)
        with self.assertRaises(UserError):
            salik.with_user(self.supervisor).action_approve()
        self.env.company.beatpro_card_journal_id = self.company_data['default_journal_bank']
        salik.with_user(self.supervisor).action_approve()
        self.assertEqual(salik.state, 'approved')

    def test_hand_over_matches(self):
        self._collect('pay-cash', 500, self.cash_line)
        cheque = self._collect('pay-chq', 200, self.cheque_line, beatpro_cheque_number='004512')
        self._expenses()
        close = self._close_day()
        self.assertAlmostEqual(close.cash_to_hand_in, 380, msg='500 collected less 120 fuel paid from it')
        desk = self.env['beatpro.day.close'].with_user(self.accountant).beatpro_handover_desk()
        card = next(c for c in desk['open'] if c['id'] == close.id)
        self.assertEqual([c['id'] for c in card['cheques']], [cheque])
        with self.assertRaises(AccessError):
            self.env['beatpro.day.close'].with_user(self.rep).beatpro_handover_desk()
        close.with_user(self.accountant).action_count(380, [cheque])
        self.assertEqual(close.handover_state, 'done')
        self.assertEqual(close.counted_by_id, self.accountant)

    def test_shortage_is_written_off(self):
        self._collect('pay-cash', 500, self.cash_line)
        self._collect('pay-chq', 200, self.cheque_line, beatpro_cheque_number='004512')
        close = self._close_day()
        close.with_user(self.accountant).action_count(480, [])
        self.assertEqual(close.handover_state, 'to_approve')
        self.assertAlmostEqual(close.cash_difference, -20)
        self.assertEqual(len(close.missing_cheque_ids), 1, 'the cheque was not handed in')
        with self.assertRaises(AccessError):
            close.with_user(self.accountant).action_approve_difference()
        close.with_user(self.supervisor).action_approve_difference()
        self.assertEqual(close.handover_state, 'written_off')
        loss = close.writeoff_move_id.line_ids.filtered(lambda l: l.debit)
        self.assertEqual(loss.account_id, self.env.company.default_cash_difference_expense_account_id)
        self.assertAlmostEqual(loss.debit, 20)

    def test_rejected_cash_expense_shows_to_supervisor(self):
        self._collect('pay-cash', 500, self.cash_line)
        expense = self.env['beatpro.expense'].browse(self._expenses()['exp-fuel']['id'])
        close = self._close_day()
        close.with_user(self.accountant).action_count(380, [])
        self.assertEqual(close.handover_state, 'done')

        # Rejected after the hand over: back to the supervisor for the 120 missing.
        expense.with_user(self.supervisor).action_reject()
        self.assertEqual(close.handover_state, 'to_approve')
        self.assertAlmostEqual(close.cash_difference, -120)
        self.assertIn('Fuel', close._difference_text())
        desk = self.env['beatpro.day.close'].with_user(self.supervisor).beatpro_handover_desk()
        card = next(c for c in desk['open'] if c['id'] == close.id)
        self.assertIn('rejected', card['difference_text'])
        close.with_user(self.supervisor).action_approve_difference()
        self.assertEqual(close.handover_state, 'written_off')
        self.assertAlmostEqual(close.writeoff_move_id.amount_total, 120)

    def test_rejected_before_count_raises_expected_cash(self):
        self._collect('pay-cash', 500, self.cash_line)
        expense = self.env['beatpro.expense'].browse(self._expenses()['exp-fuel']['id'])
        close = self._close_day()
        expense.with_user(self.supervisor).action_reject()
        close.invalidate_recordset()
        self.assertAlmostEqual(close.cash_to_hand_in, 500, msg='the rejected expense no longer comes off')
        close.with_user(self.accountant).action_count(380, [])
        self.assertEqual(close.handover_state, 'to_approve')
        self.assertIn('rejected', close._difference_text())
