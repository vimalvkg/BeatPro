from odoo import api, fields, models

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

    _partner_route_unique = models.Constraint(
        'UNIQUE(route_id, partner_id)',
        "A customer can only appear once on a route.")
