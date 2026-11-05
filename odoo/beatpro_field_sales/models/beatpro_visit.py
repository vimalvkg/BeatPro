import math

from odoo import api, fields, models
from odoo.exceptions import UserError, ValidationError

from .beatpro_tools import money


class BeatproVisit(models.Model):
    """One rep's visit to one customer, from check-in to check-out."""
    _name = 'beatpro.visit'
    _description = 'Customer Visit'
    _inherit = ['mail.thread', 'beatpro.mobile.mixin']
    _order = 'check_in desc, id desc'

    name = fields.Char(
        string="Reference", required=True, readonly=True, copy=False,
        default=lambda self: self.env._("New"))
    partner_id = fields.Many2one('res.partner', string="Customer", required=True, index=True, tracking=True)
    user_id = fields.Many2one(
        'res.users', string="Sales Rep", required=True, index=True, tracking=True,
        default=lambda self: self.env.user)
    route_id = fields.Many2one('beatpro.route', index=True)
    company_id = fields.Many2one(
        'res.company', required=True, index=True, default=lambda self: self.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')
    state = fields.Selection([
        ('planned', "Planned"),
        ('in_progress', "In Progress"),
        ('done', "Done"),
        ('cancel', "Cancelled"),
    ], default='planned', required=True, tracking=True, copy=False)

    check_in = fields.Datetime(copy=False, tracking=True)
    check_out = fields.Datetime(copy=False, tracking=True)
    duration = fields.Float(
        string="Duration (hours)", compute='_compute_duration', store=True)
    check_in_latitude = fields.Float(digits=(10, 7), copy=False)
    check_in_longitude = fields.Float(digits=(10, 7), copy=False)
    check_out_latitude = fields.Float(digits=(10, 7), copy=False)
    check_out_longitude = fields.Float(digits=(10, 7), copy=False)

    result = fields.Selection([
        ('order', "Order Taken"),
        ('no_order', "No Order"),
        ('closed', "Shop Closed"),
    ], tracking=True, copy=False)
    no_order_reason = fields.Selection([
        ('enough_stock', "Has enough stock"),
        ('credit', "Payment or credit problem"),
        ('owner_absent', "Owner not available"),
        ('competitor', "Bought from a competitor"),
        ('other', "Other"),
    ], copy=False)
    note = fields.Text()

    sale_order_ids = fields.One2many('sale.order', 'beatpro_visit_id', string="Orders")
    sale_order_count = fields.Integer(compute='_compute_sale_totals')
    amount_ordered = fields.Monetary(compute='_compute_sale_totals')
    payment_ids = fields.One2many('account.payment', 'beatpro_visit_id', string="Payments")
    shop_return_ids = fields.One2many('beatpro.shop.return', 'visit_id', string="Goods Taken Back")
    amount_collected = fields.Monetary(compute='_compute_amount_collected')

    @api.depends('check_in', 'check_out')
    def _compute_duration(self):
        for visit in self:
            if visit.check_in and visit.check_out:
                visit.duration = (visit.check_out - visit.check_in).total_seconds() / 3600
            else:
                visit.duration = 0.0

    @api.depends('sale_order_ids.state', 'sale_order_ids.amount_total')
    def _compute_sale_totals(self):
        for visit in self:
            orders = visit.sale_order_ids.filtered(lambda o: o.state != 'cancel')
            visit.sale_order_count = len(orders)
            visit.amount_ordered = sum(orders.mapped('amount_total'))

    @api.depends('payment_ids.state', 'payment_ids.amount')
    def _compute_amount_collected(self):
        for visit in self:
            payments = visit.sudo().payment_ids.filtered(lambda p: p.state not in ('canceled', 'rejected'))
            visit.amount_collected = sum(payments.mapped('amount'))

    @api.constrains('check_in', 'check_out')
    def _check_dates(self):
        for visit in self:
            if visit.check_in and visit.check_out and visit.check_out < visit.check_in:
                raise ValidationError(self.env._("Check-out can't be before check-in."))

    @api.constrains('result', 'no_order_reason')
    def _check_no_order_reason(self):
        for visit in self:
            if visit.result == 'no_order' and not visit.no_order_reason:
                raise ValidationError(self.env._("Give a reason when no order was taken."))

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if vals.get('name', self.env._("New")) == self.env._("New"):
                vals['name'] = self.env['ir.sequence'].next_by_code('beatpro.visit') or self.env._("New")
        return super().create(vals_list)

    def action_check_in(self, latitude=0.0, longitude=0.0):
        for visit in self:
            if visit.state != 'planned':
                raise UserError(self.env._("Visit %s has already started.", visit.name))
        self.write({
            'state': 'in_progress',
            'check_in': fields.Datetime.now(),
            'check_in_latitude': latitude,
            'check_in_longitude': longitude,
        })
        return True

    def action_check_out(self, result=None, no_order_reason=None, latitude=0.0, longitude=0.0, note=None):
        for visit in self:
            if visit.state != 'in_progress':
                raise UserError(self.env._("Check in to visit %s before checking out.", visit.name))
            visit_result = result or visit.result or ('order' if visit.sale_order_count else False)
            if not visit_result:
                raise UserError(self.env._("Choose a result for visit %s before checking out.", visit.name))
            visit.write({
                'state': 'done',
                'check_out': fields.Datetime.now(),
                'check_out_latitude': latitude,
                'check_out_longitude': longitude,
                'result': visit_result,
                'no_order_reason': no_order_reason or visit.no_order_reason,
                'note': note or visit.note,
            })
        return True

    def _distance_from_shop(self):
        """Metres between the check-in position and the shop's pin, or None."""
        self.ensure_one()
        shop = self.partner_id
        if not (self.check_in_latitude or self.check_in_longitude) or not (shop.partner_latitude or shop.partner_longitude):
            return None
        lat1, lon1 = math.radians(self.check_in_latitude), math.radians(self.check_in_longitude)
        lat2, lon2 = math.radians(shop.partner_latitude), math.radians(shop.partner_longitude)
        a = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
        return 6371000 * 2 * math.asin(math.sqrt(a))

    def beatpro_panel_data(self):
        """What the visit screen's top panel shows: timing, location, customer, and
        the orders and payments taken during the visit."""
        self.ensure_one()
        partner = self.partner_id.commercial_partner_id
        has_location = bool(self.check_in_latitude or self.check_in_longitude)
        distance = self._distance_from_shop()
        if not has_location:
            location = self.env._("No location recorded")
        elif distance is None:
            location = self.env._("Location recorded")
        elif distance < 1000:
            location = self.env._("Location recorded · %s m from the shop pin", round(distance))
        else:
            location = self.env._("Location recorded · %s km from the shop pin", round(distance / 1000, 1))

        past_orders = self.env['sale.order'].search([
            ('partner_id', 'child_of', partner.id), ('state', '=', 'sale'),
            ('id', 'not in', self.sale_order_ids.ids),
        ], order='date_order desc', limit=5)
        last_order_days = (fields.Datetime.now() - past_orders[0].date_order).days if past_orders else None
        due = sum(i['amount_due'] for i in self.env['res.partner'].beatpro_open_invoices(partner.ids))

        items = []
        for order in self.sale_order_ids.filtered(lambda o: o.state != 'cancel'):
            products = len(order.order_line.filtered(lambda l: not l.display_type))
            state = self.env._("Waiting for approval") if order.beatpro_approval_state == 'waiting' else \
                dict(order._fields['state'].selection).get(order.state)
            items.append({
                'kind': 'order', 'res_model': 'sale.order', 'res_id': order.id,
                'title': self.env._("Order %s", order.name),
                'sub': self.env._("%(count)s products · %(state)s", count=products, state=state),
                'amount': money(self.env, order.amount_total),
            })
        for payment in self.sudo().payment_ids.filtered(lambda p: p.state not in ('canceled', 'rejected')):
            settles = payment.reconciled_invoice_ids.mapped('name')
            items.append({
                'kind': 'payment', 'res_model': False, 'res_id': payment.id,
                'title': self.env._("%s payment", payment.payment_method_line_id.beatpro_display_name or payment.journal_id.name),
                'sub': self.env._("Settles %s", ', '.join(settles)) if settles else self.env._("Advance on account"),
                'amount': money(self.env, payment.amount),
            })
        for ret in self.shop_return_ids.filtered(lambda r: r.state == 'done'):
            items.append(ret._beatpro_panel_item())
        return {
            'state': self.state,
            'check_in': fields.Datetime.to_string(self.check_in) if self.check_in else False,
            'check_out': fields.Datetime.to_string(self.check_out) if self.check_out else False,
            'location': location,
            'has_location': has_location,
            'result': dict(self._fields['result'].selection).get(self.result) if self.result else False,
            'amount_due': money(self.env, due),
            'has_due': due > 0,
            'last_order': self.env._("%s days", last_order_days) if last_order_days is not None else self.env._("None yet"),
            'usual_order': money(self.env, sum(past_orders.mapped('amount_total')) / len(past_orders)) if past_orders else '—',
            'items': items,
            'has_order': bool(self.sale_order_ids.filtered(lambda o: o.state != 'cancel')),
            'reasons': [{'value': k, 'label': v} for k, v in self._fields['no_order_reason'].selection],
        }

    def action_cancel(self):
        self.write({'state': 'cancel'})
        return True

    def action_reset_to_planned(self):
        self.write({'state': 'planned', 'check_in': False, 'check_out': False})
        return True

    def action_new_order(self):
        """Open a new quotation for this visit's customer, linked to the visit."""
        self.ensure_one()
        if self.state != 'in_progress':
            raise UserError(self.env._("Check in to the visit before taking an order."))
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'sale.order',
            'view_mode': 'form',
            'views': [(False, 'form')],
            'target': 'current',
            'context': {
                'default_partner_id': self.partner_id.id,
                'default_user_id': self.user_id.id,
                'default_beatpro_visit_id': self.id,
            },
        }

    def action_take_back(self):
        """Open a new shop return for this visit's customer."""
        self.ensure_one()
        if self.state != 'in_progress':
            raise UserError(self.env._("Check in to the visit before taking goods back."))
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'beatpro.shop.return',
            'views': [(False, 'form')],
            'target': 'current',
            'context': {
                'default_partner_id': self.partner_id.id,
                'default_user_id': self.user_id.id,
                'default_visit_id': self.id,
            },
        }

    def action_collect_payment(self):
        """Open the Collect Payment wizard for this visit's customer."""
        self.ensure_one()
        wizard = self.env['beatpro.payment.wizard'].create({
            'partner_id': self.partner_id.id,
            'visit_id': self.id,
        })
        return {
            'type': 'ir.actions.act_window',
            'name': self.env._("Collect Payment"),
            'res_model': 'beatpro.payment.wizard',
            'res_id': wizard.id,
            'view_mode': 'form',
            'views': [(False, 'form')],
            'target': 'new',
        }

    def action_open_map(self):
        """Show the check-in location in Google Maps."""
        self.ensure_one()
        if not (self.check_in_latitude or self.check_in_longitude):
            raise UserError(self.env._("This visit has no check-in location."))
        return {
            'type': 'ir.actions.act_url',
            'url': f'https://www.google.com/maps?q={self.check_in_latitude},{self.check_in_longitude}',
            'target': 'new',
        }

    def action_view_orders(self):
        self.ensure_one()
        action = self.env['ir.actions.act_window']._for_xml_id('sale.action_orders')
        action['domain'] = [('beatpro_visit_id', '=', self.id)]
        action['context'] = {
            'default_beatpro_visit_id': self.id,
            'default_partner_id': self.partner_id.id,
            'default_user_id': self.user_id.id,
        }
        return action
