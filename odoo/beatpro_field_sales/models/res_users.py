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
    beatpro_pay_type = fields.Selection(
        [('salary', "Monthly salary only"), ('incentive', "Salary + targets and incentive")],
        string="Paid On", default='salary', required=True,
        help="Reps on monthly salary only see no target or incentive in the app and get no incentive payout.")
    beatpro_incentive_plan_id = fields.Many2one(
        'beatpro.incentive.plan', string="Incentive Plan",
        help="How this rep's incentive is worked out from what they invoice in the month.")
    beatpro_target_ids = fields.One2many('beatpro.target', 'user_id', string="Monthly Targets")
    beatpro_track_location = fields.Boolean(
        string="Share Location While Working", default=True,
        help="The app sends the rep's position every 5 minutes, from the first check-in of the day "
             "until the day is closed, for the supervisor's Live Map.")
    beatpro_survey_ids = fields.Many2many(
        'beatpro.survey', 'beatpro_survey_user_rel', 'user_id', 'survey_id', string="Shop Surveys",
        help="Surveys this rep fills in at the shops they visit.")
    beatpro_self_load = fields.Boolean(
        string="Loads Own Van",
        help="The rep loads the van without a storekeeper, for example at a small depot. "
             "Their load requests move stock into the van as soon as they send them.")

    @property
    def SELF_READABLE_FIELDS(self):
        return super().SELF_READABLE_FIELDS + [
            'beatpro_discount_limit', 'beatpro_route_ids', 'beatpro_van_warehouse_id',
            'beatpro_self_load', 'beatpro_pay_type', 'beatpro_incentive_plan_id', 'beatpro_track_location',
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
            'pay_type': user.beatpro_pay_type,
            'track_location': user.beatpro_track_location,
            'location_minutes': 5,
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

