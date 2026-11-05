from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError
from odoo.fields import Command
from odoo.tools import float_compare

from .beatpro_van_transfer import location_quantities, validate

DELIVERY_MODES = [
    ('van', "Deliver now from the van"),
    ('split', "Van now, the rest from the warehouse"),
    ('warehouse', "Main warehouse delivers"),
]


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
    beatpro_delivery_mode = fields.Selection(
        DELIVERY_MODES, string="Delivery", copy=False,
        default=lambda self: self._beatpro_default_delivery_mode(),
        help="How a rep with a van delivers this order. The order counts as the rep's sale "
             "whichever way it is delivered.")
    beatpro_has_van = fields.Boolean(compute='_compute_beatpro_has_van')

    @api.model
    def _beatpro_default_delivery_mode(self):
        return 'van' if self.env.user.beatpro_van_warehouse_id else False

    @api.depends('user_id')
    def _compute_beatpro_has_van(self):
        for order in self:
            order.beatpro_has_van = bool((order.user_id or self.env.user).beatpro_van_warehouse_id)

    def _beatpro_storable_lines(self):
        return self.order_line.filtered(lambda l: not l.display_type and l.product_id.is_storable)

    def _beatpro_prepare_delivery(self):
        """Point each line at the van or the main warehouse, following the delivery choice."""
        for order in self.filtered('beatpro_delivery_mode'):
            van = order.user_id.beatpro_van_warehouse_id
            main = self.env['stock.warehouse']._beatpro_main(order.company_id)
            if order.beatpro_delivery_mode == 'warehouse' or not van:
                order.warehouse_id = main
                continue
            order.warehouse_id = van
            available = location_quantities(self.env, van.lot_stock_id)
            for line in order._beatpro_storable_lines():
                product = line.product_id
                need = line.product_uom_id._compute_quantity(line.product_uom_qty, product.uom_id)
                enough = float_compare(available.get(product, 0.0), need, precision_rounding=product.uom_id.rounding) >= 0
                if enough:
                    available[product] = available.get(product, 0.0) - need
                elif order.beatpro_delivery_mode == 'split':
                    line.route_ids = [Command.set(main.delivery_route_id.ids)]
                elif not (self.env.context.get('beatpro_from_app') or order.mobile_uuid):
                    raise UserError(self.env._(
                        "The van has only %(left)s of %(product)s, and this order needs %(need)s. "
                        "Choose \"Van now, the rest from the warehouse\" or \"Main warehouse delivers\".",
                        left=available.get(product, 0.0), product=product.display_name, need=need))
                # From the app the rep has already handed the goods over: deliver from the van anyway.

    def _beatpro_deliver_from_van(self):
        """The rep hands the goods over at the shop: validate the van's deliveries."""
        for order in self.filtered(lambda o: o.beatpro_delivery_mode in ('van', 'split')):
            van = order.user_id.beatpro_van_warehouse_id
            pickings = order.sudo().picking_ids.filtered(
                lambda p: p.picking_type_id.warehouse_id == van and p.state not in ('done', 'cancel'))
            if pickings:
                validate(pickings)

    def action_confirm(self):
        self._beatpro_prepare_delivery()
        result = super().action_confirm()
        self._beatpro_deliver_from_van()
        return result

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
        self = self.with_context(beatpro_from_app=True)
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
                'delivery_mode': order.beatpro_delivery_mode or False,
                'delivered_now': order.beatpro_delivery_mode in ('van', 'split') and order.state == 'sale',
            } for order in orders.sudo()
        }
