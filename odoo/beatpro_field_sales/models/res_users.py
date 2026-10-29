from odoo import api, fields, models


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

    @api.model
    def beatpro_app_context(self):
        """Everything the mobile app needs to know about the signed-in rep at start-up."""
        user = self.env.user
        company = self.env.company
        return {
            'user_id': user.id,
            'name': user.name,
            'partner_id': user.partner_id.id,
            'lang': user.lang,
            'tz': user.tz or 'UTC',
            'company_id': company.id,
            'company_name': company.name,
            'currency': {
                'id': company.currency_id.id,
                'name': company.currency_id.name,
                'symbol': company.currency_id.symbol,
                'position': company.currency_id.position,
                'decimals': company.currency_id.decimal_places,
            },
            'is_rep': user.has_group('beatpro_field_sales.group_beatpro_rep'),
            'is_supervisor': user.has_group('beatpro_field_sales.group_beatpro_supervisor'),
            'discount_limit': user.beatpro_discount_limit,
            'warehouse_id': (user.beatpro_van_warehouse_id or self.env['stock.warehouse'].search(
                [('company_id', '=', company.id)], limit=1)).id,
            'server_time': fields.Datetime.to_string(fields.Datetime.now()),
        }
