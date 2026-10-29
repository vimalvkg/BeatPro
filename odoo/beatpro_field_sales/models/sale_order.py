from odoo import fields, models


class SaleOrder(models.Model):
    _name = 'sale.order'
    _inherit = ['sale.order', 'beatpro.mobile.mixin']

    beatpro_visit_id = fields.Many2one(
        'beatpro.visit', string="Visit", index='btree_not_null', copy=False,
        help="The shop visit during which the rep took this order.")

    def _confirmation_error_message(self):
        error = super()._confirmation_error_message()
        if error or not self.mobile_uuid:
            return error
        user = self.env.user
        if user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            return False
        limit = user.beatpro_discount_limit
        if any(line.discount > limit for line in self.order_line if not line.display_type):
            return self.env._(
                "Order %(order)s has a discount above your limit of %(limit)s%%. Ask a supervisor to confirm it.",
                order=self.name, limit=limit)
        return False
