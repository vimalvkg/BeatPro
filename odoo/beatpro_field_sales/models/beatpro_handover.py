from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError
from odoo.fields import Command
from odoo.tools import formatLang

from .beatpro_expense import is_cashier

HANDOVER_STATES = [
    ('waiting', "To Count"),
    ('to_approve', "Difference to Approve"),
    ('done', "Handed Over"),
    ('written_off', "Difference Written Off"),
]


class BeatproDayClose(models.Model):
    _inherit = 'beatpro.day.close'

    cash_expense_amount = fields.Monetary(
        string="Cash Spent on Expenses", compute='_compute_cash_to_hand_in',
        help="Expenses the rep paid from the cash collected that day (not rejected).")
    cash_to_hand_in = fields.Monetary(string="Cash Expected", compute='_compute_cash_to_hand_in')
    handover_state = fields.Selection(HANDOVER_STATES, string="Hand Over", default='waiting', tracking=True, copy=False)
    counted_cash = fields.Monetary(string="Cash Counted", copy=False, tracking=True)
    cash_difference = fields.Monetary(string="Difference", copy=False, readonly=True,
                                      help="Counted less expected: below zero is short.")
    cheque_payment_ids = fields.Many2many('account.payment', compute='_compute_cheque_payment_ids', string="Cheques")
    missing_cheque_ids = fields.Many2many('account.payment', 'beatpro_day_close_missing_cheque_rel', 'close_id',
                                          'payment_id', string="Cheques Not Handed In", copy=False, readonly=True)
    counted_by_id = fields.Many2one('res.users', string="Counted By", readonly=True, copy=False)
    counted_at = fields.Datetime(readonly=True, copy=False)
    writeoff_move_id = fields.Many2one('account.move', string="Write-off Entry", readonly=True, copy=False)

    def _cash_expenses(self):
        self.ensure_one()
        return self.env['beatpro.expense'].sudo().search([
            ('user_id', '=', self.user_id.id), ('date', '=', self.date), ('company_id', '=', self.company_id.id),
            ('paid_from', '=', 'cash'), ('state', '!=', 'rejected'),
        ])

    @api.depends('cash_amount', 'user_id', 'date')
    def _compute_cash_to_hand_in(self):
        for close in self:
            spent = sum(close._cash_expenses().mapped('amount')) if close.user_id and close.date else 0.0
            close.cash_expense_amount = spent
            close.cash_to_hand_in = close.cash_amount - spent

    @api.depends('user_id', 'date')
    def _compute_cheque_payment_ids(self):
        for close in self:
            close.cheque_payment_ids = self.env['account.payment'].sudo().search([
                ('beatpro_user_id', '=', close.user_id.id), ('company_id', '=', close.company_id.id),
                ('beatpro_method', '=', 'cheque'), ('state', 'not in', ('canceled', 'rejected')),
                ('date', '=', close.date),
            ]) if close.user_id and close.date else False

    def _check_cashier(self):
        if not (is_cashier(self.env) or self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor')):
            raise AccessError(self.env._("Only accountants count the cash reps hand in."))

    def action_count(self, counted, received_cheque_ids=None):
        """The accountant counted what the rep handed in.

        :param counted: cash counted
        :param received_cheque_ids: the cheques handed in; the day's other cheques are missing
        """
        self._check_cashier()
        self.ensure_one()
        close = self.sudo()
        if close.state != 'closed':
            raise UserError(self.env._("%s hasn't closed the day yet.", close.user_id.name))
        if close.handover_state not in ('waiting', 'to_approve'):
            raise UserError(self.env._("This hand over is already settled."))
        missing = close.cheque_payment_ids.filtered(lambda p: p.id not in (received_cheque_ids or []))
        difference = close.currency_id.round(counted - close.cash_to_hand_in)
        close.write({
            'counted_cash': counted,
            'cash_difference': difference,
            'missing_cheque_ids': [Command.set(missing.ids)],
            'counted_by_id': self.env.uid,
            'counted_at': fields.Datetime.now(),
            'handover_state': 'done' if close.currency_id.is_zero(difference) and not missing else 'to_approve',
        })
        if close.handover_state == 'to_approve':
            close.message_post(body=close._difference_text())
        return True

    def _difference_text(self):
        self.ensure_one()
        parts = []
        if not self.currency_id.is_zero(self.cash_difference):
            amount = formatLang(self.env, abs(self.cash_difference), currency_obj=self.currency_id)
            parts.append(self.env._("Cash short by %s", amount) if self.cash_difference < 0
                         else self.env._("Cash over by %s", amount))
        for cheque in self.missing_cheque_ids:
            parts.append(self.env._("Cheque %(number)s from %(shop)s not handed in",
                                    number=cheque.beatpro_cheque_number or cheque.name, shop=cheque.partner_id.name))
        return ' · '.join(parts)

    def action_approve_difference(self):
        """The supervisor accepts the difference: a cash shortage (or excess) is written off."""
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Only a BeatPro supervisor can approve a difference."))
        for close in self.sudo().filtered(lambda c: c.handover_state == 'to_approve'):
            if close.currency_id.is_zero(close.cash_difference):
                close.handover_state = 'done'
                continue
            company = close.company_id
            journal = company._beatpro_field_cash_journal()
            short = close.cash_difference < 0
            loss = company.default_cash_difference_expense_account_id if short else company.default_cash_difference_income_account_id
            if not loss:
                raise UserError(self.env._("Set the cash difference accounts in Accounting settings first."))
            amount = abs(close.cash_difference)
            label = self.env._("Cash hand over difference · %s", close.name)
            cash_account = journal.default_account_id
            move = self.env['account.move'].sudo().with_company(company).create({
                'move_type': 'entry',
                'journal_id': journal.id,
                'date': close.date,
                'ref': label,
                'line_ids': [
                    Command.create({'name': label, 'account_id': (loss if short else cash_account).id, 'debit': amount,
                                    'partner_id': close.user_id.partner_id.id}),
                    Command.create({'name': label, 'account_id': (cash_account if short else loss).id, 'credit': amount,
                                    'partner_id': close.user_id.partner_id.id}),
                ],
            })
            move.action_post()
            close.write({'handover_state': 'written_off', 'writeoff_move_id': move.id})
            close.message_post(body=self.env._("Difference written off by %s.", self.env.user.name))
        return True

    # -- The accountant's Cash Handover page ----------------------------------------------

    def _handover_card(self):
        self.ensure_one()
        fmt = lambda amount: formatLang(self.env, amount, currency_obj=self.currency_id)
        return {
            'id': self.id,
            'rep': self.user_id.name,
            'initials': ''.join(w[0] for w in self.user_id.name.split()[:2]).upper(),
            'van': self.user_id.beatpro_van_warehouse_id.name or False,
            'closed_at': fields.Datetime.context_timestamp(self, self.write_date).strftime('%H:%M'),
            'date': fields.Date.to_string(self.date),
            'cash': self.cash_to_hand_in,
            'cash_text': fmt(self.cash_to_hand_in),
            'expenses_text': fmt(self.cash_expense_amount) if self.cash_expense_amount else False,
            'cheques': [{'id': p.id, 'text': '%s · %s · %s' % (p.beatpro_cheque_number or p.name, p.partner_id.name, fmt(p.amount)),
                         'missing': p in self.missing_cheque_ids} for p in self.cheque_payment_ids],
            'state': self.handover_state,
            'counted': self.counted_cash,
            'difference': self.cash_difference,
            'difference_text': self._difference_text() if self.handover_state == 'to_approve' else False,
            'counted_by': self.counted_by_id.name or False,
            'counted_at': self.counted_at and fields.Datetime.context_timestamp(self, self.counted_at).strftime('%H:%M') or False,
        }

    @api.model
    def beatpro_handover_desk(self):
        """Closed days to count, differences to approve, and what was settled today."""
        self._check_cashier()
        Close = self.sudo()
        company = self.env.company
        open_closes = Close.search([('company_id', '=', company.id), ('state', '=', 'closed'),
                                    ('handover_state', 'in', ('waiting', 'to_approve'))], order='date, id')
        today = fields.Date.context_today(self)
        settled = Close.search([('company_id', '=', company.id), ('handover_state', 'in', ('done', 'written_off')),
                                ('counted_at', '>=', fields.Datetime.to_string(fields.Datetime.now().replace(hour=0, minute=0, second=0)))],
                               order='counted_at desc')
        fmt = lambda amount: formatLang(self.env, amount, currency_obj=company.currency_id)
        cheques = open_closes.cheque_payment_ids
        short = sum(-c.cash_difference for c in (open_closes | settled) if c.cash_difference < 0)
        return {
            'to_count': len(open_closes.filtered(lambda c: c.handover_state == 'waiting')),
            'cash_expected': fmt(sum(open_closes.mapped('cash_to_hand_in'))),
            'cheques': '%s · %s' % (len(cheques), fmt(sum(cheques.mapped('amount')))),
            'short': fmt(short),
            'open': [c._handover_card() for c in open_closes],
            'settled': [c._handover_card() for c in settled],
            'can_approve': self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'),
            'can_count': is_cashier(self.env),
            'today': fields.Date.to_string(today),
        }
