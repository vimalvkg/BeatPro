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
        ('bank', "Bank"),
    ], string="Collected As", copy=False,
        help="How the day-end close counts this field collection: cash and cheques are handed in, "
             "bank payments (UPI, transfers) are already in the bank.")
    beatpro_cheque_number = fields.Char(string="Cheque Number", copy=False)
    beatpro_cheque_date = fields.Date(string="Cheque Date", copy=False)
    beatpro_reference = fields.Char(string="Transaction Reference", copy=False,
                                    help="UPI transaction ID or other reference the rep entered.")

    @api.constrains('payment_method_line_id', 'beatpro_user_id', 'beatpro_cheque_number')
    def _check_beatpro_cheque_number(self):
        for payment in self:
            if (
                payment.beatpro_user_id
                and payment.payment_method_line_id.beatpro_reference == 'cheque'
                and not payment.beatpro_cheque_number
            ):
                raise ValidationError(self.env._("Enter the cheque number for a cheque payment."))

    def _beatpro_check_rep(self):
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_rep'):
            raise AccessError(self.env._("Only BeatPro reps and supervisors can record field collections."))

    @api.model
    def beatpro_register_payment(self, vals_list):
        """Record money a rep collected from a customer, post it and settle the invoices.

        Used by the mobile app and by the web Collect Payment wizard. Reps don't need
        accounting rights: the payment is created as superuser, limited to incoming
        customer payments, and stamped with the rep as collector.

        Each dict in ``vals_list`` holds ``mobile_uuid``, ``partner_id``, ``amount`` and
        ``payment_method_line_id`` (one of the company's payment methods for reps), and
        optionally ``invoice_ids``, ``date``, ``beatpro_visit_id``, ``memo``,
        ``beatpro_reference`` and cheque details. Apps from before payment methods came
        from Odoo send ``beatpro_method`` (cash, cheque or upi) instead.

        :return: ``{mobile_uuid: payment id}``
        """
        self._beatpro_check_rep()
        uuids = [vals.get('mobile_uuid') for vals in vals_list]
        if not all(uuids):
            raise UserError(self.env._("Every payment sent by the app needs a mobile ID."))

        Payment = self.sudo().with_context(active_test=False)
        result = {p.mobile_uuid: p.id for p in Payment.search([('mobile_uuid', 'in', uuids)])}
        company = self.env.company
        allowed = company._beatpro_payment_methods()
        for vals in vals_list:
            if vals['mobile_uuid'] in result:
                continue
            if vals.get('amount', 0.0) <= 0:
                raise UserError(self.env._("The amount collected must be more than zero."))
            if vals.get('payment_method_line_id'):
                line = allowed.filtered(lambda l: l.id == vals['payment_method_line_id'])
                if not line:
                    raise UserError(self.env._("This payment method isn't available to reps any more. Sync and choose another."))
            elif vals.get('beatpro_method'):
                line = company._beatpro_method_line_for(vals['beatpro_method'])
            else:
                raise UserError(self.env._("Choose how the payment was collected."))
            partner = self.env['res.partner'].browse(vals['partner_id'])
            partner.check_access('read')
            if vals.get('beatpro_visit_id'):
                self.env['beatpro.visit'].browse(vals['beatpro_visit_id']).check_access('read')
            invoices = self.env['account.move'].sudo().browse(vals.get('invoice_ids') or [])
            commercial = partner.commercial_partner_id
            if any(inv.commercial_partner_id != commercial or inv.move_type != 'out_invoice' for inv in invoices):
                raise UserError(self.env._("Payments can only settle this customer's invoices."))

            payment = Payment.create({
                'mobile_uuid': vals['mobile_uuid'],
                'payment_type': 'inbound',
                'partner_type': 'customer',
                'partner_id': partner.id,
                'amount': vals['amount'],
                'date': vals.get('date') or fields.Date.context_today(self),
                'journal_id': line.journal_id.id,
                'payment_method_line_id': line.id,
                'company_id': company.id,
                'memo': vals.get('memo') or ', '.join(invoices.mapped('name')) or False,
                'beatpro_method': line._beatpro_kind(),
                'beatpro_user_id': self.env.uid,
                'beatpro_visit_id': vals.get('beatpro_visit_id') or False,
                'beatpro_cheque_number': vals.get('beatpro_cheque_number') or False,
                'beatpro_cheque_date': vals.get('beatpro_cheque_date') or False,
                'beatpro_reference': vals.get('beatpro_reference') or vals.get('beatpro_upi_reference') or False,
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

    # -- Online payment ----------------------------------------------------------

    def _beatpro_rep_invoice(self, invoice_id):
        self._beatpro_check_rep()
        invoice = self.env['account.move'].sudo().browse(invoice_id).exists()
        if not invoice or invoice.move_type != 'out_invoice' or invoice.state != 'posted':
            raise UserError(self.env._("This invoice can't be paid online."))
        invoice.commercial_partner_id.with_user(self.env.user).check_access('read')
        return invoice

    @api.model
    def beatpro_payment_link(self, invoice_id, amount=None):
        """A link the customer opens to pay an invoice online with the company's payment
        providers (Razorpay, Stripe and so on). The app shows it as a QR code.

        :return: ``{'link', 'amount', 'invoice', 'providers', 'warning'}``
        """
        invoice = self._beatpro_rep_invoice(invoice_id)
        if invoice.payment_state in ('paid', 'in_payment'):
            raise UserError(self.env._("Invoice %s is already paid.", invoice.name))
        providers = invoice.company_id._beatpro_online_providers()
        if not providers:
            raise UserError(self.env._("No online payment provider is enabled. An admin can enable one in Accounting settings."))
        values = {'amount': amount} if amount else {}
        wizard = self.env['payment.link.wizard'].sudo().with_context(
            active_id=invoice.id, active_model='account.move').create(values)
        return {
            'link': wizard.link,
            'amount': wizard.amount,
            'invoice': invoice.name,
            'providers': providers.mapped('name'),
            'warning': wizard.warning_message or False,
        }

    @api.model
    def beatpro_invoice_status(self, invoice_ids):
        """Whether invoices have been paid, to check on an online payment.

        :return: ``{invoice id (str): {'name', 'payment_state', 'amount_due', 'paid'}}``
        """
        result = {}
        for invoice_id in invoice_ids:
            invoice = self._beatpro_rep_invoice(invoice_id)
            result[str(invoice.id)] = {
                'name': invoice.name,
                'payment_state': invoice.payment_state,
                'amount_due': invoice.amount_residual,
                'paid': invoice.payment_state in ('paid', 'in_payment'),
            }
        return result
