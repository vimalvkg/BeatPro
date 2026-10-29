from odoo import api, fields, models


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
        """Unpaid customer invoices for the given customers, for collecting payments.

        Reps usually can't read every invoice, so this reads as superuser after
        checking the rep can see the customers.

        :return: list of dicts, oldest due date first
        """
        partners = self.browse(partner_ids)
        partners.check_access('read')
        invoices = self.env['account.move'].sudo().search([
            ('commercial_partner_id', 'in', partners.commercial_partner_id.ids),
            ('move_type', '=', 'out_invoice'),
            ('state', '=', 'posted'),
            ('payment_state', 'in', ('not_paid', 'partial')),
            ('company_id', 'in', self.env.companies.ids),
        ], order='invoice_date_due, id')
        today = fields.Date.context_today(self)
        return [{
            'id': inv.id,
            'partner_id': inv.commercial_partner_id.id,
            'name': inv.name,
            'invoice_date': fields.Date.to_string(inv.invoice_date),
            'due_date': fields.Date.to_string(inv.invoice_date_due),
            'amount_total': inv.amount_total,
            'amount_due': inv.amount_residual,
            'overdue': bool(inv.invoice_date_due and inv.invoice_date_due < today),
        } for inv in invoices]
