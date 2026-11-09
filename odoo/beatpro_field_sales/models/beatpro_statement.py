from datetime import date, timedelta

from dateutil.relativedelta import relativedelta

from odoo import api, fields, models

PERIODS = [
    ('this_month', "This month"),
    ('last_month', "Last month"),
    ('3_months', "Last 3 months"),
]


def period_dates(period, today):
    first = today.replace(day=1)
    if period == 'last_month':
        start = first - relativedelta(months=1)
        return start, first - timedelta(days=1)
    if period == '3_months':
        return first - relativedelta(months=2), today
    return first, today


class ResPartner(models.Model):
    _inherit = 'res.partner'

    def _beatpro_statement(self, date_from, date_to):
        """The customer's account between two dates: opening balance, each invoice,
        credit note and payment with the running balance, and what is overdue.
        """
        self.ensure_one()
        company = self.env.company
        commercial = self.commercial_partner_id
        Line = self.env['account.move.line'].sudo()
        domain = [
            ('partner_id', 'child_of', commercial.id),
            ('account_id.account_type', '=', 'asset_receivable'),
            ('parent_state', '=', 'posted'),
            ('company_id', '=', company.id),
        ]
        opening = sum(Line.search(domain + [('date', '<', date_from)]).mapped('balance'))
        lines = Line.search(domain + [('date', '>=', date_from), ('date', '<=', date_to)], order='date, move_id, id')
        rows, balance = [], opening
        for move in lines.move_id.sorted(lambda m: (m.date, m.id)):
            amount = sum(lines.filtered(lambda l: l.move_id == move).mapped('balance'))
            balance += amount
            if move.move_type == 'out_invoice':
                label, kind = self.env._("Invoice %s", move.name), 'invoice'
            elif move.move_type == 'out_refund':
                label, kind = self.env._("Credit note %s", move.name), 'credit_note'
            elif move.origin_payment_id:
                method = move.origin_payment_id.payment_method_line_id
                label = self.env._("Payment · %s", method.beatpro_display_name or method.name or move.journal_id.name)
                kind = 'payment'
            else:
                label, kind = move.ref or move.name, 'other'
            rows.append({
                'date': fields.Date.to_string(move.date),
                'label': label,
                'kind': kind,
                'debit': amount if amount > 0 else 0.0,
                'credit': -amount if amount < 0 else 0.0,
                'balance': balance,
            })
        # Ageing of what is still open on the last day.
        buckets = {'not_due': 0.0, 'd30': 0.0, 'd60': 0.0, 'older': 0.0}
        for line in Line.search(domain + [('date', '<=', date_to), ('reconciled', '=', False)]):
            residual = line.amount_residual
            days = (date_to - (line.date_maturity or line.date)).days
            key = 'not_due' if days <= 0 else 'd30' if days <= 30 else 'd60' if days <= 60 else 'older'
            buckets[key] += residual
        return {
            'partner': {'name': commercial.name, 'city': commercial.city or '', 'trn': commercial.vat or ''},
            'date_from': fields.Date.to_string(date_from),
            'date_to': fields.Date.to_string(date_to),
            'opening': opening,
            'lines': rows,
            'closing': balance,
            'overdue': buckets['d30'] + buckets['d60'] + buckets['older'],
            'ageing': buckets,
            'note': company.beatpro_statement_note or '',
            'currency': company.currency_id.name,
        }

    @api.model
    def beatpro_statement(self, partner_id, period='this_month'):
        """A customer's statement for the app."""
        partner = self.browse(partner_id)
        partner.check_access('read')
        start, end = period_dates(period, fields.Date.context_today(self))
        return partner._beatpro_statement(start, end)

    def action_beatpro_statement(self):
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'name': self.env._("Customer Statement"),
            'res_model': 'beatpro.statement.wizard',
            'view_mode': 'form',
            'target': 'new',
            'context': {'default_partner_id': self.commercial_partner_id.id},
        }


class ResCompany(models.Model):
    _inherit = 'res.company'

    beatpro_statement_note = fields.Text(
        string="Statement Payment Note",
        help="Printed at the end of customer statements, e.g. how to pay and your bank's IBAN.")


class BeatproStatementWizard(models.TransientModel):
    _name = 'beatpro.statement.wizard'
    _description = "Print Customer Statement"

    partner_id = fields.Many2one('res.partner', required=True)
    period = fields.Selection(PERIODS + [('custom', "Other dates")], default='this_month', required=True)
    date_from = fields.Date(compute='_compute_dates', store=True, readonly=False, required=True, precompute=True)
    date_to = fields.Date(compute='_compute_dates', store=True, readonly=False, required=True, precompute=True)

    @api.depends('period')
    def _compute_dates(self):
        today = fields.Date.context_today(self)
        for wizard in self:
            if wizard.period != 'custom' or not wizard.date_from:
                wizard.date_from, wizard.date_to = period_dates(
                    wizard.period if wizard.period != 'custom' else 'this_month', today)

    def action_print(self):
        self.ensure_one()
        return self.env.ref('beatpro_field_sales.action_report_beatpro_statement').report_action(
            self.partner_id, data={'date_from': fields.Date.to_string(self.date_from),
                                   'date_to': fields.Date.to_string(self.date_to)}, config=False)


class ReportBeatproStatement(models.AbstractModel):
    _name = 'report.beatpro_field_sales.report_beatpro_statement'
    _description = "Customer Statement Report"

    @api.model
    def _get_report_values(self, docids, data=None):
        data = data or {}
        today = fields.Date.context_today(self)
        start, end = period_dates('this_month', today)
        date_from = fields.Date.to_date(data.get('date_from')) or start
        date_to = fields.Date.to_date(data.get('date_to')) or end
        partners = self.env['res.partner'].browse(docids)
        return {
            'doc_ids': docids,
            'doc_model': 'res.partner',
            'docs': partners,
            'company': self.env.company,
            'statements': {p.id: p._beatpro_statement(date_from, date_to) for p in partners},
            'fmt_date': lambda s: fields.Date.to_date(s).strftime('%d/%m/%Y'),
        }
