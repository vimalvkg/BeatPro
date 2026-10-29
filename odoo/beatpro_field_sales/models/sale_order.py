from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError


class SaleOrder(models.Model):
    _name = 'sale.order'
    _inherit = ['sale.order', 'beatpro.mobile.mixin']

    beatpro_visit_id = fields.Many2one(
        'beatpro.visit', string="Visit", index='btree_not_null', copy=False,
        help="The shop visit during which the rep took this order.")
    beatpro_approval_state = fields.Selection([
        ('waiting', "Waiting for Approval"),
        ('approved', "Approved"),
    ], string="Discount Approval", copy=False, tracking=True,
        help="Set when a rep's discount is above their limit and a supervisor must confirm the order.")

    def _beatpro_over_discount_limit(self):
        """True when the current user is a BeatPro rep (not a supervisor) and a line
        of this order has a discount above the rep's limit."""
        self.ensure_one()
        user = self.env.user
        if (
            not user.has_group('beatpro_field_sales.group_beatpro_rep')
            or user.has_group('beatpro_field_sales.group_beatpro_supervisor')
        ):
            return False
        limit = user.beatpro_discount_limit
        return any(line.discount > limit for line in self.order_line if not line.display_type)

    def _confirmation_error_message(self):
        error = super()._confirmation_error_message()
        if error or not self._beatpro_over_discount_limit():
            return error
        return self.env._(
            "Order %(order)s has a discount above your limit of %(limit)s%%. "
            "Click Request Approval so a supervisor can confirm it.",
            order=self.name, limit=self.env.user.beatpro_discount_limit)

    def action_beatpro_request_approval(self):
        for order in self:
            if order.state not in ('draft', 'sent'):
                raise UserError(self.env._("Only quotations can be sent for approval."))
            order.beatpro_approval_state = 'waiting'
            order.message_post(body=self.env._("Discount approval requested by %s.", self.env.user.name))
        return True

    def action_beatpro_approve(self):
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Only a BeatPro supervisor can approve discounts."))
        self.write({'beatpro_approval_state': 'approved'})
        return self.action_confirm()

    @api.model
    def beatpro_submit_orders(self, vals_list):
        """Create orders sent by the app and confirm them.

        Orders already received (same ``mobile_uuid``) are left as they are. An order
        whose discount is above the rep's limit stays a quotation waiting for a
        supervisor's approval.

        :return: ``{mobile_uuid: {'id', 'name', 'state', 'approval', 'amount_total'}}``
        """
        ids_by_uuid = self.beatpro_upsert(vals_list)
        orders = self.browse([order_id for order_id in ids_by_uuid.values()])
        for order in orders:
            if order.state not in ('draft', 'sent') or order.beatpro_approval_state:
                continue
            if order._beatpro_over_discount_limit():
                order.action_beatpro_request_approval()
            else:
                order.action_confirm()
        return {
            order.mobile_uuid: {
                'id': order.id,
                'name': order.name,
                'state': order.state,
                'approval': order.beatpro_approval_state or False,
                'amount_total': order.amount_total,
            } for order in orders.sudo()
        }
