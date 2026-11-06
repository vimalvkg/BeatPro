import base64
import logging
import uuid

from odoo import api, fields, models
from odoo.exceptions import UserError

_logger = logging.getLogger(__name__)


class BeatproPaymentWizard(models.TransientModel):
    """Collect Payment, for reps working in the Odoo web client instead of the app."""
    _name = 'beatpro.payment.wizard'
    _description = 'Collect Payment'

    partner_id = fields.Many2one('res.partner', string="Customer", required=True)
    visit_id = fields.Many2one('beatpro.visit', string="Visit")
    company_id = fields.Many2one('res.company', default=lambda self: self.env.company, required=True)
    currency_id = fields.Many2one(related='company_id.currency_id')
    method = fields.Selection(
        selection='_selection_method', string="Paid By", required=True, default=lambda self: self._default_method())
    method_reference = fields.Char(compute='_compute_method_reference')
    amount = fields.Monetary()
    date = fields.Date(required=True, default=fields.Date.context_today)
    cheque_number = fields.Char()
    cheque_date = fields.Date()
    reference = fields.Char(string="Transaction Reference")
    online_enabled = fields.Boolean(compute='_compute_online_enabled')
    online_link = fields.Char(string="Payment Link", readonly=True)
    online_qr = fields.Binary(string="QR Code", readonly=True)
    online_invoice = fields.Char(readonly=True)
    line_ids = fields.One2many('beatpro.payment.wizard.line', 'wizard_id', string="Open Invoices")
    amount_due = fields.Monetary(string="Total Due", compute='_compute_amount_due')
    amount_hint = fields.Char(compute='_compute_amount_hint')

    @api.model
    def _selection_method(self):
        """The company's payment methods for reps, by id. A selection rather than a
        many2one, so reps without accounting rights can still pick one."""
        return [(str(line.id), line.beatpro_display_name) for line in self.env.company._beatpro_payment_methods()]

    @api.model
    def _default_method(self):
        options = self._selection_method()
        return options[0][0] if options else False

    @api.depends('method')
    def _compute_method_reference(self):
        for wizard in self:
            line = self.env['account.payment.method.line'].sudo().browse(int(wizard.method)) if wizard.method else None
            wizard.method_reference = line.beatpro_reference if line else 'none'

    @api.depends('company_id')
    def _compute_online_enabled(self):
        for wizard in self:
            wizard.online_enabled = bool(wizard.company_id._beatpro_online_providers())

    @api.model_create_multi
    def create(self, vals_list):
        wizards = super().create(vals_list)
        for wizard in wizards:
            invoices = self.env['res.partner'].beatpro_open_invoices(wizard.partner_id.ids)
            wizard.line_ids = [fields.Command.create({
                'invoice_id': inv['id'],
                'name': inv['name'],
                'kind': inv['kind'],
                'due_date': inv['due_date'],
                'amount_due': inv['amount_due'],
                'overdue': inv['overdue'],
            }) for inv in invoices]
        return wizards

    @api.depends('line_ids.amount_due')
    def _compute_amount_due(self):  # Credit notes count as negative amounts.
        for wizard in self:
            wizard.amount_due = sum(wizard.line_ids.mapped('amount_due'))

    @api.depends('amount', 'amount_due', 'line_ids.selected', 'line_ids.amount_due')
    def _compute_amount_hint(self):
        for wizard in self:
            fmt = wizard.currency_id.format
            if not wizard.amount_due:
                wizard.amount_hint = self.env._("No unpaid invoices · kept as an advance")
                continue
            left = max(wizard.amount_due - (wizard.amount or 0.0), 0.0)
            wizard.amount_hint = self.env._(
                "of %(due)s due · %(left)s left after this", due=fmt(wizard.amount_due), left=fmt(left))

    @api.onchange('line_ids')
    def _onchange_selected_invoices(self):
        selected = self.line_ids.filtered('selected')
        if selected:
            # Credit notes picked are used first; the shop pays the rest.
            self.amount = max(sum(selected.mapped('amount_due')), 0.0)

    def action_confirm(self):
        self.ensure_one()
        if self.amount and self.method_reference == 'cheque' and not self.cheque_number:
            raise UserError(self.env._("Enter the cheque number."))
        result = self.env['account.payment'].beatpro_register_payment([{
            'mobile_uuid': f'web-{uuid.uuid4()}',
            'partner_id': self.partner_id.id,
            'amount': self.amount,
            'date': self.date,
            'payment_method_line_id': int(self.method),
            'beatpro_visit_id': self.visit_id.id,
            'beatpro_cheque_number': self.cheque_number,
            'beatpro_cheque_date': self.cheque_date,
            'beatpro_reference': self.reference,
            'invoice_ids': self.line_ids.filtered('selected').mapped('invoice_id'),
        }])
        payment = self.env['account.payment'].sudo().browse(next(iter(result.values())))
        if not payment:
            message = self.env._("Credit notes of %s used against the selected invoices.", self.partner_id.display_name)
        else:
            message = self.env._(
                "%(amount)s collected from %(customer)s (%(payment)s).",
                amount=payment.currency_id.format(payment.amount),
                customer=self.partner_id.display_name,
                payment=payment.name)
        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'type': 'success',
                'message': message,
                'next': {'type': 'ir.actions.act_window_close'},
            },
        }


    def action_payment_link(self):
        """Show a link and QR code the customer uses to pay the selected invoice online."""
        self.ensure_one()
        selected = self.line_ids.filtered(lambda l: l.selected and l.kind == 'invoice')
        if len(selected) != 1:
            raise UserError(self.env._("Select the one invoice the customer will pay online."))
        info = self.env['account.payment'].beatpro_payment_link(
            selected.invoice_id, self.amount if self.amount and self.amount < selected.amount_due else None)
        try:
            qr = base64.b64encode(self.env['ir.actions.report'].barcode(
                barcode_type='QR', value=info['link'], width=240, height=240, quiet=False))
        except Exception:  # noqa: BLE001
            # Some servers lack the drawing library for barcodes; the link still works.
            _logger.warning("Could not draw the payment QR code", exc_info=True)
            qr = False
        self.write({
            'online_link': info['link'],
            'online_qr': qr,
            'online_invoice': self.env._("%(invoice)s · %(amount)s", invoice=info['invoice'],
                                         amount=self.currency_id.format(info['amount'])),
        })
        return {
            'type': 'ir.actions.act_window',
            'name': self.env._("Collect Payment"),
            'res_model': self._name,
            'res_id': self.id,
            'view_mode': 'form',
            'views': [(False, 'form')],
            'target': 'new',
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
    kind = fields.Selection([('invoice', "Invoice"), ('credit_note', "Credit Note")], readonly=True, default='invoice')
    due_date = fields.Date(readonly=True)
    amount_due = fields.Monetary(readonly=True)
    overdue = fields.Boolean(readonly=True)
