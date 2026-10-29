from datetime import datetime, time

import pytz

from odoo import api, fields, models
from odoo.exceptions import UserError


class BeatproDayClose(models.Model):
    """A rep's end-of-day summary: visits, orders and money collected."""
    _name = 'beatpro.day.close'
    _description = 'Day-End Close'
    _inherit = ['mail.thread', 'beatpro.mobile.mixin']
    _order = 'date desc, id desc'

    name = fields.Char(compute='_compute_name', store=True)
    user_id = fields.Many2one(
        'res.users', string="Sales Rep", required=True, index=True,
        default=lambda self: self.env.user)
    date = fields.Date(required=True, index=True, default=fields.Date.context_today)
    company_id = fields.Many2one(
        'res.company', required=True, index=True, default=lambda self: self.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')
    state = fields.Selection([
        ('draft', "Open"),
        ('closed', "Closed"),
    ], default='draft', required=True, tracking=True, copy=False)

    visit_count = fields.Integer(string="Visits Done", readonly=True)
    visit_order_count = fields.Integer(string="Visits With Order", readonly=True)
    visit_no_order_count = fields.Integer(string="Visits Without Order", readonly=True)
    order_count = fields.Integer(string="Orders", readonly=True)
    order_amount = fields.Monetary(string="Order Value", readonly=True)
    cash_amount = fields.Monetary(string="Cash", readonly=True)
    cheque_amount = fields.Monetary(string="Cheque", readonly=True)
    upi_amount = fields.Monetary(string="UPI", readonly=True)
    total_collected = fields.Monetary(compute='_compute_total_collected', store=True)
    distance_km = fields.Float(string="Distance (km)", help="Distance travelled, as measured by the app.")
    note = fields.Text()

    _user_date_unique = models.Constraint(
        'UNIQUE(user_id, date, company_id)',
        "Each rep has only one day-end close per day.")

    @api.depends('user_id', 'date')
    def _compute_name(self):
        for close in self:
            close.name = f"{close.user_id.name or ''} {close.date or ''}".strip()

    @api.depends('cash_amount', 'cheque_amount', 'upi_amount')
    def _compute_total_collected(self):
        for close in self:
            close.total_collected = close.cash_amount + close.cheque_amount + close.upi_amount

    def write(self, vals):
        if (
            not self.env.su
            and any(close.state == 'closed' for close in self)
            and not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor')
        ):
            raise UserError(self.env._("A closed day can only be changed by a supervisor."))
        return super().write(vals)

    def _day_bounds_utc(self):
        """Start and end of the close's date in the rep's time zone, as naive UTC."""
        self.ensure_one()
        tz = pytz.timezone(self.user_id.tz or self.env.user.tz or 'UTC')
        start = tz.localize(datetime.combine(self.date, time.min)).astimezone(pytz.utc)
        end = tz.localize(datetime.combine(self.date, time.max)).astimezone(pytz.utc)
        return start.replace(tzinfo=None), end.replace(tzinfo=None)

    def action_refresh(self):
        """Recount the day's visits, orders and collections from Odoo's records."""
        for close in self:
            if close.state == 'closed':
                raise UserError(self.env._("Reopen %s before refreshing it.", close.name))
            start, end = close._day_bounds_utc()
            visits = self.env['beatpro.visit'].search([
                ('user_id', '=', close.user_id.id),
                ('company_id', '=', close.company_id.id),
                ('state', '=', 'done'),
                ('check_in', '>=', start),
                ('check_in', '<=', end),
            ])
            orders = self.env['sale.order'].search([
                ('user_id', '=', close.user_id.id),
                ('company_id', '=', close.company_id.id),
                ('state', '!=', 'cancel'),
                ('date_order', '>=', start),
                ('date_order', '<=', end),
            ])
            payments = self.env['account.payment'].sudo().search([
                ('beatpro_user_id', '=', close.user_id.id),
                ('company_id', '=', close.company_id.id),
                ('beatpro_method', '!=', False),
                ('state', 'not in', ('canceled', 'rejected')),
                ('date', '=', close.date),
            ])
            amounts = {'cash': 0.0, 'cheque': 0.0, 'upi': 0.0}
            for payment in payments:
                amounts[payment.beatpro_method] += payment.amount
            close.write({
                'visit_count': len(visits),
                'visit_order_count': len(visits.filtered(lambda v: v.result == 'order')),
                'visit_no_order_count': len(visits.filtered(lambda v: v.result in ('no_order', 'closed'))),
                'order_count': len(orders),
                'order_amount': sum(orders.mapped('amount_total')),
                'cash_amount': amounts['cash'],
                'cheque_amount': amounts['cheque'],
                'upi_amount': amounts['upi'],
            })
        return True

    def action_close(self):
        # Days already closed are skipped: the app may retry after a dropped connection.
        to_close = self.filtered(lambda close: close.state == 'draft')
        to_close.action_refresh()
        to_close.write({'state': 'closed'})
        return True

    def action_reopen(self):
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise UserError(self.env._("Only a supervisor can reopen a closed day."))
        self.write({'state': 'draft'})
        return True
