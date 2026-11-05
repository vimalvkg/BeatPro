from odoo import api, fields, models


class AccountPaymentMethodLine(models.Model):
    _inherit = 'account.payment.method.line'

    beatpro_show = fields.Boolean(
        string="Show to BeatPro Reps", default=True,
        help="Reps can record money received with this payment method, in the app and in Odoo.")
    beatpro_label = fields.Char(
        string="Name for Reps",
        help="What reps see, e.g. \"UPI\" or \"Bank transfer\". Defaults to the payment method's name.")
    beatpro_reference = fields.Selection([
        ('none', "Nothing"),
        ('reference', "Transaction reference (optional)"),
        ('cheque', "Cheque number and date"),
    ], string="Reps Enter", default='none', required=True,
        help="Extra details reps enter when they record a payment with this method.")
    beatpro_hand_in = fields.Boolean(
        string="Handed In by Rep", compute='_compute_beatpro_hand_in',
        help="Cash and cheques the rep brings back to the office at the end of the day.")
    beatpro_display_name = fields.Char(compute='_compute_beatpro_display_name')

    @api.depends('journal_id.type', 'beatpro_reference')
    def _compute_beatpro_hand_in(self):
        for line in self:
            line.beatpro_hand_in = line.journal_id.type == 'cash' or line.beatpro_reference == 'cheque'

    @api.depends('beatpro_label', 'name', 'journal_id.name', 'journal_id.type')
    def _compute_beatpro_display_name(self):
        for line in self:
            if line.beatpro_label:
                line.beatpro_display_name = line.beatpro_label
            elif line.journal_id.type == 'cash':
                line.beatpro_display_name = self.env._("Cash")
            else:
                line.beatpro_display_name = f"{line.journal_id.name} · {line.name}" if line.name else line.journal_id.name

    def _beatpro_kind(self):
        """``cash``, ``cheque`` or ``bank``: how the day-end close groups the money."""
        self.ensure_one()
        if self.journal_id.type == 'cash':
            return 'cash'
        return 'cheque' if self.beatpro_reference == 'cheque' else 'bank'

    def _beatpro_as_dict(self):
        return [{
            'id': line.id,
            'name': line.beatpro_display_name,
            'journal': line.journal_id.name,
            'kind': line._beatpro_kind(),
            'reference': line.beatpro_reference,
            'hand_in': line.beatpro_hand_in,
        } for line in self]
