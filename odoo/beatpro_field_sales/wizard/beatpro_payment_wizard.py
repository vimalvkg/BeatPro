import uuid

from odoo import api, fields, models
from odoo.exceptions import UserError


class BeatproPaymentWizard(models.TransientModel):
    """Collect Payment, for reps working in the Odoo web client instead of the app."""
    _name = 'beatpro.payment.wizard'
    _description = 'Collect Payment'

    partner_id = fields.Many2one('res.partner', string="Customer", required=True)
    visit_id = fields.Many2one('beatpro.visit', string="Visit")
    company_id = fields.Many2one('res.company', default=lambda self: self.env.company, required=True)
    currency_id = fields.Many2one(related='company_id.currency_id')
    method = fields.Selection([
        ('cash', "Cash"),
        ('cheque', "Cheque"),
        ('upi', "UPI"),
    ], string="Collected As", required=True, default='cash')
    amount = fields.Monetary()
    date = fields.Date(required=True, default=fields.Date.context_today)
    cheque_number = fields.Char()
    cheque_date = fields.Date()
    upi_reference = fields.Char(string="UPI Reference")
    line_ids = fields.One2many('beatpro.payment.wizard.line', 'wizard_id', string="Open Invoices")
    amount_due = fields.Monetary(string="Total Due", compute='_compute_amount_due')

    @api.model_create_multi
    def create(self, vals_list):
        wizards = super().create(vals_list)
        for wizard in wizards:
            invoices = self.env['res.partner'].beatpro_open_invoices(wizard.partner_id.ids)
            wizard.line_ids = [fields.Command.create({
                'invoice_id': inv['id'],
                'name': inv['name'],
                'due_date': inv['due_date'],
                'amount_due': inv['amount_due'],
                'overdue': inv['overdue'],
            }) for inv in invoices]
        return wizards

    @api.depends('line_ids.amount_due')
    def _compute_amount_due(self):
        for wizard in self:
            wizard.amount_due = sum(wizard.line_ids.mapped('amount_due'))

    @api.onchange('line_ids')
    def _onchange_selected_invoices(self):
        selected = self.line_ids.filtered('selected')
        if selected:
            self.amount = sum(selected.mapped('amount_due'))

    def action_confirm(self):
        self.ensure_one()
        if self.method == 'cheque' and not self.cheque_number:
            raise UserError(self.env._("Enter the cheque number."))
        result = self.env['account.payment'].beatpro_register_payment([{
            'mobile_uuid': f'web-{uuid.uuid4()}',
            'partner_id': self.partner_id.id,
            'amount': self.amount,
            'date': self.date,
            'beatpro_method': self.method,
            'beatpro_visit_id': self.visit_id.id,
            'beatpro_cheque_number': self.cheque_number,
            'beatpro_cheque_date': self.cheque_date,
            'beatpro_upi_reference': self.upi_reference,
            'invoice_ids': self.line_ids.filtered('selected').mapped('invoice_id'),
        }])
        payment = self.env['account.payment'].sudo().browse(next(iter(result.values())))
        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'type': 'success',
                'message': self.env._(
                    "%(amount)s collected from %(customer)s (%(payment)s).",
                    amount=payment.currency_id.format(payment.amount),
                    customer=self.partner_id.display_name,
                    payment=payment.name),
                'next': {'type': 'ir.actions.act_window_close'},
            },
        }


class BeatproPaymentWizardLine(models.TransientModel):
    _name = 'beatpro.payment.wizard.line'
    _description = 'Collect Payment: Open Invoice'

    wizard_id = fields.Many2one('beatpro.payment.wizard', required=True, ondelete='cascade')
    currency_id = fields.Many2one(related='wizard_id.currency_id')
    selected = fields.Boolean(string="Pay")
    # Plain id, not a Many2one: reps often can't read invoices directly.
    invoice_id = fields.Integer(string="Invoice ID", required=True)
    name = fields.Char(string="Invoice", readonly=True)
    due_date = fields.Date(readonly=True)
    amount_due = fields.Monetary(readonly=True)
    overdue = fields.Boolean(readonly=True)
