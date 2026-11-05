from datetime import timedelta

from odoo import api, fields, models

from .beatpro_tools import day_bounds_utc, initials, money

WEEKDAYS = [
    ('0', "Monday"),
    ('1', "Tuesday"),
    ('2', "Wednesday"),
    ('3', "Thursday"),
    ('4', "Friday"),
    ('5', "Saturday"),
    ('6', "Sunday"),
]


class BeatproRoute(models.Model):
    """A beat plan: the customers one rep visits, in order, on a given weekday."""
    _name = 'beatpro.route'
    _description = 'Sales Route'
    _inherit = ['mail.thread']
    _order = 'weekday, sequence, name'

    name = fields.Char(required=True, tracking=True)
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)
    user_id = fields.Many2one(
        'res.users', string="Sales Rep", required=True, index=True, tracking=True,
        default=lambda self: self.env.user,
        domain="[('share', '=', False)]")
    weekday = fields.Selection(
        WEEKDAYS, tracking=True,
        help="Day of the week this route is visited. Leave empty for a route visited on any day.")
    company_id = fields.Many2one(
        'res.company', required=True, index=True, default=lambda self: self.env.company)
    line_ids = fields.One2many('beatpro.route.line', 'route_id', string="Customers", copy=True)
    partner_count = fields.Integer(string="Customer Count", compute='_compute_partner_count')
    visit_ids = fields.One2many('beatpro.visit', 'route_id', string="Visits")
    visit_count = fields.Integer(compute='_compute_visit_count')
    order_rate = fields.Integer(
        string="Ordered (%)", compute='_compute_order_rate',
        help="Share of this route's visits in the last 30 days that ended with an order.")
    order_rate_label = fields.Char(string="Ordered", compute='_compute_order_rate')
    note = fields.Text()

    @api.depends('line_ids')
    def _compute_partner_count(self):
        for route in self:
            route.partner_count = len(route.line_ids)

    def _compute_visit_count(self):
        counts = dict(self.env['beatpro.visit']._read_group(
            [('route_id', 'in', self.ids)], ['route_id'], ['__count']))
        for route in self:
            route.visit_count = counts.get(route, 0)

    def _compute_order_rate(self):
        since = fields.Datetime.now() - timedelta(days=30)
        groups = self.env['beatpro.visit']._read_group(
            [('route_id', 'in', self.ids), ('state', '=', 'done'), ('check_in', '>=', since)],
            ['route_id', 'result'], ['__count'])
        done, ordered = {}, {}
        for route, result, count in groups:
            done[route] = done.get(route, 0) + count
            if result == 'order':
                ordered[route] = ordered.get(route, 0) + count
        for route in self:
            route.order_rate = round(100 * ordered.get(route, 0) / done[route]) if done.get(route) else 0
            route.order_rate_label = (
                self.env._("%s%% ordered", route.order_rate) if done.get(route) else self.env._("No visits yet"))

    def action_view_visits(self):
        self.ensure_one()
        action = self.env['ir.actions.act_window']._for_xml_id('beatpro_field_sales.action_beatpro_visit')
        action['domain'] = [('route_id', '=', self.id)]
        action['context'] = {'default_route_id': self.id, 'default_user_id': self.user_id.id}
        return action

    @api.model
    def beatpro_today_plan(self):
        """Today's visit plan for the current user, as the mobile app shows it.

        :return: one dict per customer, in visit order across today's routes
        """
        weekday = str(fields.Date.context_today(self).weekday())
        routes = self.search([
            ('user_id', '=', self.env.uid),
            '|', ('weekday', '=', weekday), ('weekday', '=', False),
        ])
        return [{
            'route_id': line.route_id.id,
            'route_name': line.route_id.name,
            'sequence': line.sequence,
            'partner_id': line.partner_id.id,
            'partner_name': line.partner_id.display_name,
        } for line in routes.line_ids]


class BeatproRouteLine(models.Model):
    _name = 'beatpro.route.line'
    _description = 'Sales Route Customer'
    _order = 'route_id, sequence, id'

    route_id = fields.Many2one('beatpro.route', required=True, index=True, ondelete='cascade')
    sequence = fields.Integer(default=10)
    partner_id = fields.Many2one('res.partner', string="Customer", required=True, index=True)
    phone = fields.Char(related='partner_id.phone')
    city = fields.Char(related='partner_id.city')
    company_id = fields.Many2one(related='route_id.company_id', store=True)

    today_visit_id = fields.Many2one('beatpro.visit', compute='_compute_today_visit')
    today_status = fields.Selection([
        ('to_visit', "To Visit"),
        ('in_progress', "In Progress"),
        ('visited', "Visited"),
    ], compute='_compute_today_visit')

    @api.model
    def _today_visits(self, partner_ids=None):
        """The current user's visits started or planned today, newest first."""
        start, _ = day_bounds_utc(fields.Date.context_today(self), self.env.user.tz)
        domain = [
            ('user_id', '=', self.env.uid),
            ('state', 'in', ('planned', 'in_progress', 'done')),
            '|', ('check_in', '>=', start), '&', ('check_in', '=', False), ('create_date', '>=', start),
        ]
        if partner_ids is not None:
            domain.append(('partner_id', 'in', partner_ids))
        return self.env['beatpro.visit'].search(domain, order='id desc')

    def _compute_today_visit(self):
        visits = self._today_visits(self.partner_id.ids)
        for line in self:
            visit = visits.filtered(lambda v: v.partner_id == line.partner_id)[:1]
            line.today_visit_id = visit
            line.today_status = {
                'in_progress': 'in_progress', 'done': 'visited',
            }.get(visit.state, 'to_visit')

    @api.model
    def action_my_day(self):
        """Today's stops for the current user, for reps working in the web client."""
        weekday = str(fields.Date.context_today(self).weekday())
        routes = self.env['beatpro.route'].search([
            ('user_id', '=', self.env.uid),
            '|', ('weekday', '=', weekday), ('weekday', '=', False),
        ])
        action = self.env['ir.actions.act_window']._for_xml_id('beatpro_field_sales.action_beatpro_my_day')
        action['domain'] = [('id', 'in', routes.line_ids.ids)]
        return action

    @api.model
    def beatpro_my_day_data(self):
        """Everything the My Day screen shows for the current user."""
        user = self.env.user
        today = fields.Date.context_today(self)
        weekday = str(today.weekday())
        routes = self.env['beatpro.route'].search([
            ('user_id', '=', user.id),
            '|', ('weekday', '=', weekday), ('weekday', '=', False),
        ])
        lines = routes.line_ids
        visits = self._today_visits()
        start, end = day_bounds_utc(today, user.tz)

        orders = self.env['sale.order'].search([
            ('user_id', '=', user.id), ('state', '!=', 'cancel'),
            ('date_order', '>=', start), ('date_order', '<=', end),
        ])
        payments = self.env['account.payment'].sudo().search([
            ('beatpro_user_id', '=', user.id), ('date', '=', today),
            ('state', 'not in', ('canceled', 'rejected')),
        ])
        ordered = {}
        for order in orders:
            key = order.partner_id.commercial_partner_id.id
            ordered[key] = ordered.get(key, 0.0) + order.amount_total
        collected = {}
        for payment in payments:
            key = payment.partner_id.commercial_partner_id.id
            collected[key] = collected.get(key, 0.0) + payment.amount
        due = {}
        for invoice in self.env['res.partner'].beatpro_open_invoices(lines.partner_id.ids):
            due[invoice['partner_id']] = due.get(invoice['partner_id'], 0.0) + invoice['amount_due']

        stops = []
        for number, line in enumerate(lines, start=1):
            partner = line.partner_id
            key = partner.commercial_partner_id.id
            visit = visits.filtered(lambda v: v.partner_id == partner)[:1]
            status = {'in_progress': 'in_progress', 'done': 'visited'}.get(visit.state, 'to_visit')
            if status == 'visited':
                bits = []
                if ordered.get(key):
                    bits.append(self.env._("Order %s", money(self.env, ordered[key])))
                elif visit.result:
                    bits.append(dict(visit._fields['result'].selection).get(visit.result))
                if collected.get(key):
                    bits.append(self.env._("%s collected", money(self.env, collected[key])))
                sub = ' · '.join(b for b in bits if b)
            else:
                sub = ' · '.join(p for p in (partner.city, line.route_id.name if len(routes) > 1 else None) if p)
            stops.append({
                'line_id': line.id,
                'number': number,
                'name': partner.display_name,
                'sub': sub,
                'status': status,
                'phone': partner.phone or False,
                'latitude': partner.partner_latitude or False,
                'longitude': partner.partner_longitude or False,
                'due': money(self.env, due[key]) if due.get(key) else False,
                'visit_id': visit.id or False,
            })
        current = next((s for s in stops if s['status'] == 'in_progress'), None)
        upcoming = next((s for s in stops if s['status'] == 'to_visit'), None)
        done = sum(1 for s in stops if s['status'] == 'visited')
        return {
            'user_name': user.name,
            'user_initials': initials(user.name),
            'subtitle': ' · '.join([today.strftime('%A')] + routes.mapped('name')),
            'done': done,
            'planned': len(stops),
            'left': len(stops) - done,
            'orders_total': money(self.env, sum(orders.mapped('amount_total'))),
            'collected_total': money(self.env, sum(payments.mapped('amount'))),
            'next': current or upcoming or False,
            'next_is_current': bool(current),
            'stops': stops,
        }

    def action_start_visit(self):
        """Open today's visit to this customer, creating it if needed."""
        self.ensure_one()
        self.invalidate_recordset(['today_visit_id', 'today_status'])
        visit = self.today_visit_id or self.env['beatpro.visit'].create({
            'partner_id': self.partner_id.id,
            'route_id': self.route_id.id,
            'user_id': self.env.uid,
        })
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'beatpro.visit',
            'res_id': visit.id,
            'view_mode': 'form',
            'views': [(False, 'form')],
            'target': 'current',
        }

    _partner_route_unique = models.Constraint(
        'UNIQUE(route_id, partner_id)',
        "A customer can only appear once on a route.")
