from odoo import api, fields, models
from odoo.exceptions import UserError, ValidationError


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
            payments = visit.payment_ids.filtered(lambda p: p.state not in ('canceled', 'rejected'))
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

    def action_check_out(self, result=None, no_order_reason=None, latitude=0.0, longitude=0.0):
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
            })
        return True

    def action_cancel(self):
        self.write({'state': 'cancel'})
        return True

    def action_reset_to_planned(self):
        self.write({'state': 'planned', 'check_in': False, 'check_out': False})
        return True

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
