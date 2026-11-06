from odoo import api, fields, models
from odoo.tools import formatLang


class ResPartner(models.Model):
    _name = 'res.partner'
    _inherit = ['res.partner', 'beatpro.mobile.mixin']

    beatpro_route_line_ids = fields.One2many('beatpro.route.line', 'partner_id', string="Route Stops")
    beatpro_visit_ids = fields.One2many('beatpro.visit', 'partner_id', string="Visits")
    beatpro_visit_count = fields.Integer(string="Visit Count", compute='_compute_beatpro_visit_count')
    beatpro_last_visit = fields.Datetime(string="Last Visit", compute='_compute_beatpro_visit_count')

    def _compute_beatpro_visit_count(self):
        groups = self.env['beatpro.visit']._read_group(
            [('partner_id', 'in', self.ids), ('state', '=', 'done')],
            ['partner_id'], ['__count', 'check_in:max'])
        stats = {partner: (count, last) for partner, count, last in groups}
        for partner in self:
            partner.beatpro_visit_count, partner.beatpro_last_visit = stats.get(partner, (0, False))

    def action_beatpro_view_visits(self):
        self.ensure_one()
        action = self.env['ir.actions.act_window']._for_xml_id('beatpro_field_sales.action_beatpro_visit')
        action['domain'] = [('partner_id', '=', self.id)]
        action['context'] = {'default_partner_id': self.id}
        return action

    @api.model
    def beatpro_open_invoices(self, partner_ids):
        """Unpaid customer invoices and unused credit notes, for collecting payments.

        Reps usually can't read every invoice, so this reads as superuser after
        checking the rep can see the customers. A credit note (for goods taken back)
        has a negative ``amount_due``: the shop can use it against any invoice.

        :return: list of dicts, oldest due date first
        """
        partners = self.browse(partner_ids)
        partners.check_access('read')
        moves = self.env['account.move'].sudo().search([
            ('commercial_partner_id', 'in', partners.commercial_partner_id.ids),
            ('move_type', 'in', ('out_invoice', 'out_refund')),
            ('state', '=', 'posted'),
            ('payment_state', 'in', ('not_paid', 'partial')),
            ('company_id', 'in', self.env.companies.ids),
        ], order='invoice_date_due, id')
        today = fields.Date.context_today(self)
        return [{
            'id': move.id,
            'partner_id': move.commercial_partner_id.id,
            'name': move.name,
            'kind': 'credit_note' if move.move_type == 'out_refund' else 'invoice',
            'invoice_date': fields.Date.to_string(move.invoice_date),
            'due_date': fields.Date.to_string(move.invoice_date_due),
            'amount_total': move.amount_total,
            'amount_due': move.amount_residual if move.move_type == 'out_invoice' else -move.amount_residual,
            'overdue': bool(move.move_type == 'out_invoice' and move.invoice_date_due and move.invoice_date_due < today),
            'origin': move.invoice_origin or False,
        } for move in moves]

    def _beatpro_oldest_overdue(self, company=None):
        """The customer's oldest overdue invoice, or False.

        :return: ``{'name', 'days', 'amount', 'amount_text', 'total'}``, where total is
            everything overdue
        """
        self.ensure_one()
        company = company or self.env.company
        today = fields.Date.context_today(self)
        invoices = self.env['account.move'].sudo().search([
            ('commercial_partner_id', '=', self.commercial_partner_id.id),
            ('move_type', '=', 'out_invoice'),
            ('state', '=', 'posted'),
            ('payment_state', 'in', ('not_paid', 'partial')),
            ('company_id', '=', company.id),
            ('invoice_date_due', '<', today),
        ], order='invoice_date_due, id')
        if not invoices:
            return False
        oldest = invoices[0]
        return {
            'name': oldest.name,
            'days': (today - oldest.invoice_date_due).days,
            'amount': oldest.amount_residual,
            'amount_text': formatLang(self.env, oldest.amount_residual, currency_obj=oldest.currency_id),
            'total': sum(invoices.mapped('amount_residual')),
        }

    @api.model
    def beatpro_credit(self, partner_ids):
        """How much each customer owes, their credit limit and overdue invoices, so the
        app can warn the rep before taking an order. Nothing is blocked.

        :return: ``{partner_id: {'limit', 'owed', 'overdue_name', 'overdue_days', 'overdue_amount'}}``
            (ids as strings); a limit of 0 means no limit
        """
        partners = self.browse(partner_ids)
        partners.check_access('read')
        company = self.env.company
        use_limit = company.account_use_credit_limit
        result = {}
        for partner in partners:
            commercial = partner.commercial_partner_id.sudo().with_company(company)
            overdue = partner._beatpro_oldest_overdue(company)
            result[str(partner.id)] = {
                'limit': commercial.credit_limit if use_limit else 0.0,
                'owed': commercial.credit + (commercial.credit_to_invoice if use_limit else 0.0),
                'overdue_name': overdue and overdue['name'],
                'overdue_days': overdue and overdue['days'] or 0,
                'overdue_amount': overdue and overdue['total'] or 0.0,
            }
        return result
