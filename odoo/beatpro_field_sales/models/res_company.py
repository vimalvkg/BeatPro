from odoo import fields, models
from odoo.exceptions import UserError


class ResCompany(models.Model):
    _inherit = 'res.company'

    beatpro_van_invoice = fields.Boolean(
        string="Invoice van deliveries at the shop", default=True,
        help="Reps create and post the tax invoice for what they hand over from the van, "
             "and print it on a thermal printer or share it. Warehouse deliveries are "
             "invoiced by the office as usual.")
    beatpro_slip_width = fields.Selection([
        ('80', "80 mm (3 inch)"),
        ('58', "58 mm (2 inch)"),
    ], string="Thermal paper width", default='80', required=True)

    def _beatpro_payment_methods(self):
        """Payment methods reps can record money with: the incoming payment methods of
        the company's cash and bank journals marked "Show to BeatPro Reps", cash first."""
        self.ensure_one()
        Journal = self.env['account.journal'].sudo()
        company_domain = Journal._check_company_domain(self)
        if self.chart_template and not Journal.search_count([*company_domain, ('type', '=', 'cash')], limit=1):
            # Odoo 19 charts don't always include a cash journal; reps need one.
            Journal.create({'name': self.env._("Field Cash"), 'code': 'FCSH', 'type': 'cash', 'company_id': self.id})
        lines = self.env['account.payment.method.line'].sudo().search([
            ('journal_id.company_id', '=', self.id),
            ('journal_id.type', 'in', ('cash', 'bank')),
            ('journal_id.active', '=', True),
            ('payment_type', '=', 'inbound'),
            ('beatpro_show', '=', True),
        ])
        return lines.sorted(lambda l: (l.journal_id.type != 'cash', l.journal_id.sequence, l.journal_id.id, l.sequence, l.id))

    def _beatpro_method_line_for(self, legacy_method):
        """The payment method for the older app's fixed choices: cash, cheque or upi."""
        self.ensure_one()
        lines = self._beatpro_payment_methods()
        if legacy_method == 'cash':
            match = lines.filtered(lambda l: l.journal_id.type == 'cash')
        elif legacy_method == 'cheque':
            match = lines.filtered(lambda l: l.beatpro_reference == 'cheque') or \
                lines.filtered(lambda l: l.journal_id.type == 'bank')
        else:
            match = lines.filtered(lambda l: l.journal_id.type == 'bank' and l.beatpro_reference != 'cheque') or \
                lines.filtered(lambda l: l.journal_id.type == 'bank')
        if not match:
            raise UserError(self.env._(
                "No payment method for reps matches \"%s\". Set one up under BeatPro > Supervisor > Payment Methods.",
                legacy_method))
        return match[0]

    def _beatpro_online_providers(self):
        """Online payment providers customers can pay invoices with, by link or QR code."""
        self.ensure_one()
        return self.env['payment.provider'].sudo().search([
            ('state', 'in', ('enabled', 'test')),
            ('company_id', '=', self.id),
        ])
