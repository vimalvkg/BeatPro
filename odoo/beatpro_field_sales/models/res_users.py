from odoo import fields, models


class ResUsers(models.Model):
    _inherit = 'res.users'

    beatpro_discount_limit = fields.Float(
        string="Max Discount (%)", default=0.0,
        help="Highest line discount this rep can give in the BeatPro app. "
             "Larger discounts need a supervisor.")
    beatpro_route_ids = fields.One2many('beatpro.route', 'user_id', string="Routes")
    beatpro_van_warehouse_id = fields.Many2one(
        'stock.warehouse', string="Van Warehouse",
        help="The rep's vehicle, set up as its own warehouse, for van sales.")

    @property
    def SELF_READABLE_FIELDS(self):
        return super().SELF_READABLE_FIELDS + [
            'beatpro_discount_limit', 'beatpro_route_ids', 'beatpro_van_warehouse_id',
        ]
