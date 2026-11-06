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
    beatpro_van_invoice_name = fields.Char(
        string="Van Invoice Number", copy=False,
        help="The number the rep's phone gave the invoice made at the shop.")
    beatpro_van_invoice_ids = fields.Many2many(
        'account.move', compute='_compute_beatpro_van_invoice_ids', string="Invoices Made at the Shop")

    def _compute_beatpro_van_invoice_ids(self):
        for order in self:
            order.beatpro_van_invoice_ids = order.sudo().invoice_ids.filtered('beatpro_van_id')

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
        if not self.env.context.get('beatpro_from_app'):
            # From the app the invoice comes with the number the phone gave it.
            for order in self.filtered(lambda o: o.company_id.beatpro_van_invoice):
                order._beatpro_invoice_van_delivery()
        return result

    def _beatpro_van_lines(self):
        """Lines handed over from the van and not invoiced yet, with the quantity to invoice."""
        self.ensure_one()
        van = self.user_id.beatpro_van_warehouse_id
        if not van or self.beatpro_delivery_mode not in ('van', 'split'):
            return []
        result = []
        for line in self.order_line.filtered(lambda l: not l.display_type and l.warehouse_id == van):
            qty = line.qty_delivered - line.qty_invoiced if line.product_id.is_storable else line.product_uom_qty - line.qty_invoiced
            if qty > 0:
                result.append((line, qty))
        return result

    def _beatpro_invoice_van_delivery(self, name=None, invoice_date=None):
        """Post the tax invoice for what the rep handed over from the van, in the van's
        own series. ``name`` is the number the phone gave it; when another invoice already
        has it, Odoo gives the next free number instead.

        :return: the posted invoice, or an empty recordset when there is nothing to invoice
        """
        self.ensure_one()
        Move = self.env['account.move'].sudo()
        order = self.sudo()
        van = order.user_id.beatpro_van_warehouse_id
        existing = order.invoice_ids.filtered(lambda m: m.beatpro_van_id and m.state != 'cancel')
        if name and existing.filtered(lambda m: m.name == name):
            return existing.filtered(lambda m: m.name == name)
        lines = order._beatpro_van_lines()
        if not lines:
            return existing[:1]
        journal = van._beatpro_invoice_journal()
        vals = order._prepare_invoice()
        vals.update({
            'journal_id': journal.id,
            'beatpro_van_id': van.id,
            'invoice_user_id': order.user_id.id,
            'invoice_date': invoice_date or fields.Date.context_today(order),
            'invoice_line_ids': [Command.create(line._prepare_invoice_line(quantity=qty)) for line, qty in lines],
        })
        if name and not Move.search_count([('journal_id', '=', journal.id), ('name', '=', name)]):
            vals['name'] = name
        invoice = Move.with_company(order.company_id).create(vals)
        invoice.action_post()
        order.beatpro_van_invoice_name = invoice.name
        return invoice

    def _beatpro_invoice_info(self):
        self.ensure_one()
        invoice = self.sudo().invoice_ids.filtered(lambda m: m.beatpro_van_id and m.state == 'posted')[:1]
        return invoice and {
            'id': invoice.id,
            'name': invoice.name,
            'amount_untaxed': invoice.amount_untaxed,
            'amount_tax': invoice.amount_tax,
            'amount_total': invoice.amount_total,
            'simplified': invoice._beatpro_is_simplified(),
        } or False

    def action_beatpro_print_slip(self):
        """Print the invoice made at the shop on a thermal printer."""
        self.ensure_one()
        invoice = self.sudo().invoice_ids.filtered(lambda m: m.beatpro_van_id and m.state == 'posted')[:1]
        if not invoice:
            raise UserError(self.env._("There is no invoice made at the shop for this order."))
        return invoice.action_beatpro_print_slip()

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
        # The invoice date the phone printed is not an order field.
        dates = {v['mobile_uuid']: v.pop('beatpro_van_invoice_date', None) for v in vals_list}
        ids_by_uuid = self.beatpro_upsert(vals_list)
        orders = self.browse([order_id for order_id in ids_by_uuid.values()])
        for order in orders:
            if order.state not in ('draft', 'sent') or order.beatpro_approval_state:
                continue
            if order._beatpro_over_discount_limit():
                order.action_beatpro_request_approval()
            else:
                order.action_confirm()
                if order.beatpro_van_invoice_name and order.company_id.beatpro_van_invoice:
                    order._beatpro_invoice_van_delivery(order.beatpro_van_invoice_name, dates.get(order.mobile_uuid))
        return {
            order.mobile_uuid: {
                'id': order.id,
                'name': order.name,
                'state': order.state,
                'approval': order.beatpro_approval_state or False,
                'amount_total': order.amount_total,
                'delivery_mode': order.beatpro_delivery_mode or False,
                'delivered_now': order.beatpro_delivery_mode in ('van', 'split') and order.state == 'sale',
                'invoice': order._beatpro_invoice_info(),
            } for order in orders.sudo()
        }
