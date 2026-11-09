import math
from datetime import timedelta

from odoo import api, fields, models
from odoo.exceptions import UserError


def distance_km(a, b):
    """Straight-line distance between two (lat, lng) points, in km."""
    lat1, lng1, lat2, lng2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lng2 - lng1) / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(h))


def path_km(start, points):
    total, here = 0.0, start
    for point in points:
        if here is not None:
            total += distance_km(here, point)
        here = point
    return total


def shortest_order(start, points):
    """Visiting order for ``points`` from ``start``: nearest shop first, then improved by
    reversing stretches of the path while that makes it shorter (2-opt).

    :return: indexes into ``points``
    """
    if len(points) < 2:
        return list(range(len(points)))
    left = list(range(len(points)))
    here = start if start is not None else points[0]
    order = []
    while left:
        nearest = min(left, key=lambda i: distance_km(here, points[i]))
        order.append(nearest)
        left.remove(nearest)
        here = points[nearest]
    improved = True
    while improved:
        improved = False
        for i in range(len(order) - 1):
            for j in range(i + 1, len(order)):
                candidate = order[:i] + order[i:j + 1][::-1] + order[j + 1:]
                if path_km(start, [points[k] for k in candidate]) + 1e-9 < path_km(start, [points[k] for k in order]):
                    order, improved = candidate, True
    return order


class BeatproRoute(models.Model):
    _inherit = 'beatpro.route'

    distance_km = fields.Float(string="Distance Now (km)", compute='_compute_distances', digits=(10, 1),
                               help="From the main warehouse, through the shops in their order, as the crow flies.")
    shortest_km = fields.Float(string="Shortest (km)", compute='_compute_distances', digits=(10, 1))
    unpinned_count = fields.Integer(compute='_compute_distances',
                                    help="Shops without a location pin: they keep their place at the end.")
    move_ids = fields.One2many('beatpro.route.move', 'route_id', string="Moved by Reps")

    def _start_point(self):
        self.ensure_one()
        partner = self.company_id.partner_id
        warehouse = self.env['stock.warehouse'].sudo().search(
            [('company_id', '=', self.company_id.id), ('beatpro_is_van', '=', False)], limit=1)
        for p in (warehouse.partner_id, partner):
            if p and p.partner_latitude and p.partner_longitude:
                return (p.partner_latitude, p.partner_longitude)
        return None

    def _pinned_lines(self):
        self.ensure_one()
        lines = self.line_ids.sorted('sequence')
        pinned = lines.filtered(lambda l: l.partner_id.partner_latitude and l.partner_id.partner_longitude)
        return pinned, lines - pinned

    @api.depends('line_ids.sequence', 'line_ids.partner_id')
    def _compute_distances(self):
        for route in self:
            pinned, unpinned = route._pinned_lines()
            points = [(l.partner_id.partner_latitude, l.partner_id.partner_longitude) for l in pinned]
            start = route._start_point()
            route.distance_km = path_km(start, points)
            order = shortest_order(start, points)
            route.shortest_km = path_km(start, [points[i] for i in order])
            route.unpinned_count = len(unpinned)

    def action_beatpro_shortest_order(self):
        """Put the route's shops in the shortest order; shops without a pin go last."""
        for route in self:
            pinned, unpinned = route._pinned_lines()
            points = [(l.partner_id.partner_latitude, l.partner_id.partner_longitude) for l in pinned]
            order = shortest_order(route._start_point(), points)
            for sequence, line in enumerate([pinned[i] for i in order] + list(unpinned), start=1):
                line.sequence = sequence
            route.message_post(body=self.env._("Shops put in the shortest order (%.1f km).", route.shortest_km))
        return True

    @api.model
    def _beatpro_moves_for(self, user, day):
        Move = self.env['beatpro.route.move'].sudo()
        moved_out = Move.search([('user_id', '=', user.id), ('date', '=', day), ('kind', '=', 'tomorrow')])
        moved_in = Move.search([('user_id', '=', user.id), ('to_date', '=', day), ('kind', '=', 'tomorrow')])
        skipped = Move.search([('user_id', '=', user.id), ('date', '=', day), ('kind', '=', 'skip')])
        return moved_out, moved_in, skipped


class BeatproRouteMove(models.Model):
    _name = 'beatpro.route.move'
    _description = "Route Stop Moved by a Rep"
    _inherit = ['beatpro.mobile.mixin']
    _order = 'date desc, id desc'

    user_id = fields.Many2one('res.users', string="Rep", required=True, default=lambda self: self.env.user, index=True)
    partner_id = fields.Many2one('res.partner', string="Shop", required=True, index=True)
    route_id = fields.Many2one('beatpro.route', index=True, ondelete='set null')
    date = fields.Date(string="Planned On", required=True, default=fields.Date.context_today, index=True)
    kind = fields.Selection([('tomorrow', "Moved to tomorrow"), ('skip', "Skipped · shop closed")], required=True)
    to_date = fields.Date(string="Moved To", index=True)
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if vals.get('kind') == 'tomorrow' and not vals.get('to_date'):
                day = fields.Date.to_date(vals.get('date')) or fields.Date.context_today(self)
                vals['to_date'] = day + timedelta(days=1)
        return super().create(vals_list)

    @api.model
    def beatpro_submit_moves(self, vals_list):
        """Stops the rep moved to tomorrow or skipped on the phone.

        :return: ``{mobile_uuid: id}``
        """
        for vals in vals_list:
            vals['user_id'] = self.env.uid
            if vals.get('kind') not in ('tomorrow', 'skip'):
                raise UserError(self.env._("Unknown change to the route."))
        return self.beatpro_upsert(vals_list)
