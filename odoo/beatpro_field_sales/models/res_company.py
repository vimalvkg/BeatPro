from odoo import fields, models
from odoo.exceptions import UserError


class ResCompany(models.Model):
    _inherit = 'res.company'

    beatpro_cash_journal_id = fields.Many2one(
        'account.journal', string="BeatPro Cash Journal", domain="[('type', '=', 'cash'), ('company_id', '=', id)]",
        help="Journal for cash collected by reps. Defaults to the first cash journal.")
    beatpro_bank_journal_id = fields.Many2one(
        'account.journal', string="BeatPro Bank Journal", domain="[('type', '=', 'bank'), ('company_id', '=', id)]",
        help="Journal for cheque and UPI payments collected by reps. Defaults to the first bank journal.")

    def _beatpro_journal_for(self, method):
        """The journal a field collection made with ``method`` is recorded in."""
        self.ensure_one()
        journal_type = 'cash' if method == 'cash' else 'bank'
        journal = self.beatpro_cash_journal_id if journal_type == 'cash' else self.beatpro_bank_journal_id
        if not journal:
            journal = self.env['account.journal'].sudo().search([
                *self.env['account.journal']._check_company_domain(self),
                ('type', '=', journal_type),
            ], limit=1)
        if not journal and journal_type == 'cash' and self.chart_template:
            # Odoo 19 charts don't always include a cash journal; reps need one.
            journal = self.env['account.journal'].sudo().create({
                'name': self.env._("Field Cash"),
                'code': 'FCSH',
                'type': 'cash',
                'company_id': self.id,
            })
            self.sudo().beatpro_cash_journal_id = journal
        if not journal:
            raise UserError(self.env._(
                "Set up a %(type)s journal in Accounting before recording field collections.",
                type=journal_type))
        return journal
