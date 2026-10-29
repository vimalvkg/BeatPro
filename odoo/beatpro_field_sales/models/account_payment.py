from odoo import api, fields, models
from odoo.exceptions import ValidationError


class AccountPayment(models.Model):
    _name = 'account.payment'
    _inherit = ['account.payment', 'beatpro.mobile.mixin']

    beatpro_visit_id = fields.Many2one(
        'beatpro.visit', string="Visit", index='btree_not_null', copy=False,
        help="The shop visit during which the rep collected this payment.")
    beatpro_method = fields.Selection([
        ('cash', "Cash"),
        ('cheque', "Cheque"),
        ('upi', "UPI"),
    ], string="Collected As", copy=False,
        help="How the rep collected this payment in the field.")
    beatpro_cheque_number = fields.Char(string="Cheque Number", copy=False)
    beatpro_cheque_date = fields.Date(string="Cheque Date", copy=False)
    beatpro_upi_reference = fields.Char(string="UPI Reference", copy=False)

    @api.constrains('beatpro_method', 'beatpro_cheque_number')
    def _check_beatpro_cheque_number(self):
        for payment in self:
            if payment.beatpro_method == 'cheque' and not payment.beatpro_cheque_number:
                raise ValidationError(self.env._("Enter the cheque number for a cheque payment."))
