from odoo import api, fields, models

from .beatpro_shop_return import NOT_RESELLABLE, RETURN_REASONS


class ResUsers(models.Model):
    _inherit = 'res.users'

    beatpro_discount_limit = fields.Float(
        string="Max Discount (%)", default=0.0,
        help="Highest line discount this rep can give in the BeatPro app. "
             "Larger discounts need a supervisor.")
    beatpro_route_ids = fields.One2many('beatpro.route', 'user_id', string="Routes")
    beatpro_van_warehouse_id = fields.Many2one(
        'stock.warehouse', string="Van Warehouse",
        domain="[('beatpro_is_van', '=', True)]",
        help="The rep's vehicle, set up as its own warehouse, for van sales.")
    beatpro_self_load = fields.Boolean(
        string="Loads Own Van",
        help="The rep loads the van without a storekeeper, for example at a small depot. "
             "Their load requests move stock into the van as soon as they send them.")

    @property
    def SELF_READABLE_FIELDS(self):
        return super().SELF_READABLE_FIELDS + [
            'beatpro_discount_limit', 'beatpro_route_ids', 'beatpro_van_warehouse_id',
            'beatpro_self_load',
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
            'payment_methods': company._beatpro_payment_methods()._beatpro_as_dict(),
            'online_providers': company._beatpro_online_providers().mapped('name'),
            'van': user.beatpro_van_warehouse_id and {
                'id': user.beatpro_van_warehouse_id.id,
                'name': user.beatpro_van_warehouse_id.name,
                'vehicle': user.beatpro_van_warehouse_id.beatpro_vehicle or False,
                'main_warehouse': self.env['stock.warehouse']._beatpro_main(company).name,
                'self_load': user.beatpro_self_load,
            } or False,
            'van_invoice': self._beatpro_van_invoice_context(),
            'return_reasons': [{'value': key, 'label': label, 'resellable': key not in NOT_RESELLABLE}
                               for key, label in RETURN_REASONS],
            'warehouse_id': (user.beatpro_van_warehouse_id or self.env['stock.warehouse'].search(
                [('company_id', '=', company.id)], limit=1)).id,
            'server_time': fields.Datetime.to_string(fields.Datetime.now()),
        }

    @api.model
    def _beatpro_van_invoice_context(self):
        """The van's invoice series, so the phone numbers invoices without signal."""
        user = self.env.user
        van = user.beatpro_van_warehouse_id
        company = self.env.company
        if not van or not company.beatpro_van_invoice:
            return False
        journal = van._beatpro_invoice_journal()
        today = fields.Date.context_today(self)
        prefix, number = self.env['account.move']._beatpro_next_number(journal, today)
        partner = company.partner_id
        return {
            'journal': journal.code,
            'year': today.year,
            'next': number,
            'padding': 5,
            'paper': company.beatpro_slip_width,
            'company': {
                'name': company.name,
                'trn': company.vat or '',
                'address': ', '.join(filter(None, [partner.street, partner.city, partner.country_id.name])),
                'phone': partner.phone or '',
            },
        }

