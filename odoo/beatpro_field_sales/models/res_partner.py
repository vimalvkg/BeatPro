from odoo import fields, models


class ResPartner(models.Model):
    _name = 'res.partner'
    _inherit = ['res.partner', 'beatpro.mobile.mixin']

    beatpro_route_line_ids = fields.One2many('beatpro.route.line', 'partner_id', string="Route Stops")
