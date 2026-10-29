from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError, ValidationError


class AccountPayment(models.Model):
    _name = 'account.payment'
    _inherit = ['account.payment', 'beatpro.mobile.mixin']

    beatpro_visit_id = fields.Many2one(
        'beatpro.visit', string="Visit", index='btree_not_null', copy=False,
        help="The shop visit during which the rep collected this payment.")
    beatpro_user_id = fields.Many2one(
        'res.users', string="Collected By", index='btree_not_null', copy=False,
        help="The rep who collected this payment in the field.")
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

    @api.model
    def beatpro_register_payment(self, vals_list):
        """Record money a rep collected from a customer, post it and settle the invoices.

        Used by the mobile app and by the web Collect Payment wizard. Reps don't need
        accounting rights: the payment is created as superuser, limited to incoming
        customer payments, and stamped with the rep as collector.

        Each dict in ``vals_list`` holds ``mobile_uuid``, ``partner_id``, ``amount``,
        ``beatpro_method`` and optionally ``invoice_ids``, ``date``, ``beatpro_visit_id``,
        ``memo``, cheque and UPI details.

        :return: ``{mobile_uuid: payment id}``
        """
        user = self.env.user
        if not user.has_group('beatpro_field_sales.group_beatpro_rep'):
            raise AccessError(self.env._("Only BeatPro reps and supervisors can record field collections."))
        uuids = [vals.get('mobile_uuid') for vals in vals_list]
        if not all(uuids):
            raise UserError(self.env._("Every payment sent by the app needs a mobile ID."))

        Payment = self.sudo().with_context(active_test=False)
        result = {p.mobile_uuid: p.id for p in Payment.search([('mobile_uuid', 'in', uuids)])}
        company = self.env.company
        for vals in vals_list:
            if vals['mobile_uuid'] in result:
                continue
            if vals.get('amount', 0.0) <= 0:
                raise UserError(self.env._("The amount collected must be more than zero."))
            method = vals.get('beatpro_method')
            if method not in ('cash', 'cheque', 'upi'):
                raise UserError(self.env._("Choose how the payment was collected: cash, cheque or UPI."))
            partner = self.env['res.partner'].browse(vals['partner_id'])
            partner.check_access('read')
            if vals.get('beatpro_visit_id'):
                self.env['beatpro.visit'].browse(vals['beatpro_visit_id']).check_access('read')
            invoices = self.env['account.move'].sudo().browse(vals.get('invoice_ids') or [])
            commercial = partner.commercial_partner_id
            if any(inv.commercial_partner_id != commercial or inv.move_type != 'out_invoice' for inv in invoices):
                raise UserError(self.env._("Payments can only settle this customer's invoices."))

            journal = company._beatpro_journal_for(method)
            payment = Payment.create({
                'mobile_uuid': vals['mobile_uuid'],
                'payment_type': 'inbound',
                'partner_type': 'customer',
                'partner_id': partner.id,
                'amount': vals['amount'],
                'date': vals.get('date') or fields.Date.context_today(self),
                'journal_id': journal.id,
                'company_id': company.id,
                'memo': vals.get('memo') or ', '.join(invoices.mapped('name')) or False,
                'beatpro_method': method,
                'beatpro_user_id': user.id,
                'beatpro_visit_id': vals.get('beatpro_visit_id') or False,
                'beatpro_cheque_number': vals.get('beatpro_cheque_number') or False,
                'beatpro_cheque_date': vals.get('beatpro_cheque_date') or False,
                'beatpro_upi_reference': vals.get('beatpro_upi_reference') or False,
            })
            payment.action_post()
            if invoices:
                payment._beatpro_reconcile(invoices)
            result[payment.mobile_uuid] = payment.id
        return result

    def _beatpro_reconcile(self, invoices):
        """Match the payment's receivable line with the invoices' open receivable lines."""
        self.ensure_one()
        domain = [('account_type', '=', 'asset_receivable'), ('reconciled', '=', False)]
        lines = self.move_id.line_ids.filtered_domain(domain)
        lines |= invoices.filtered(lambda m: m.state == 'posted').line_ids.filtered_domain(domain)
        for account in lines.account_id:
            lines.filtered(lambda l: l.account_id == account).reconcile()
