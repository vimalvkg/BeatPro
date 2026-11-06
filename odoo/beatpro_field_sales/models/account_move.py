import re

from odoo import api, fields, models
from odoo.tools import format_date


class AccountMove(models.Model):
    _inherit = 'account.move'

    beatpro_van_id = fields.Many2one(
        'stock.warehouse', string="Invoiced From Van", readonly=True, copy=False, index='btree_not_null',
        help="The van whose rep made this invoice at the shop.")

    def _beatpro_is_simplified(self):
        """UAE: a customer without a TRN gets a simplified tax invoice."""
        self.ensure_one()
        return not self.commercial_partner_id.vat

    def _beatpro_slip_data(self):
        """What the thermal slip shows, worked out once for the template."""
        self.ensure_one()
        lines = self.invoice_line_ids.filtered(lambda l: l.display_type == 'product')
        sign = -1 if self.move_type == 'out_refund' else 1
        due = sum(self.env['account.move'].sudo().search([
            ('commercial_partner_id', '=', self.commercial_partner_id.id),
            ('move_type', 'in', ('out_invoice', 'out_refund')),
            ('state', '=', 'posted'),
            ('payment_state', 'in', ('not_paid', 'partial')),
            ('company_id', '=', self.company_id.id),
        ]).mapped('amount_residual_signed'))
        this = self.amount_residual_signed if self.state == 'posted' else self.amount_total * sign
        van = self.beatpro_van_id
        return {
            'title': "SIMPLIFIED TAX INVOICE" if self._beatpro_is_simplified() else "TAX INVOICE",
            'title_ar': "فاتورة ضريبية مبسطة" if self._beatpro_is_simplified() else "فاتورة ضريبية",
            'date': format_date(self.env, self.invoice_date or fields.Date.context_today(self), date_format='dd/MM/yyyy'),
            'van': " / ".join(filter(None, [van.beatpro_vehicle, self.invoice_user_id.name])) if van else '',
            'lines': [{
                'name': line.product_id.name or line.name,
                'qty': ('%g' % line.quantity),
                'price': line.price_unit,
                'vat': ", ".join('%g%%' % t.amount for t in line.tax_ids if t.amount_type == 'percent') or "0%",
                'amount': line.price_subtotal,
            } for line in lines],
            'previous': due - this,
            'balance': due,
            'words': self.currency_id.amount_to_text(self.amount_total),
        }

    @api.model
    def _beatpro_slip_height_mm(self, invoices, width):
        """Receipts are as long as their content, so the printer doesn't feed blank paper."""
        base, per_line = (105, 9) if width == '80' else (120, 11)
        longest = max([len(m.invoice_line_ids.filtered(lambda l: l.display_type == 'product')) for m in invoices] or [1])
        return base + per_line * longest

    @api.model
    def _beatpro_next_number(self, journal, day):
        """Next number in the journal's series for ``day``'s year, e.g. ``VAN1/2026/00012``."""
        prefix = '%s/%s/' % (journal.code, day.year)
        last = self.sudo().search([('journal_id', '=', journal.id), ('name', '=like', prefix + '%')],
                                  order='name desc', limit=1)
        match = re.search(r'(\d+)$', last.name or '')
        return prefix, (int(match.group(1)) + 1) if match else 1

    def action_beatpro_print_slip(self):
        """Print on a thermal printer, in the company's paper width."""
        width = self[:1].company_id.beatpro_slip_width or '80'
        # The slip has its own layout: don't ask to set up the company's document layout first.
        return self.env.ref('beatpro_field_sales.action_report_invoice_slip_%s' % width).report_action(self, config=False)
