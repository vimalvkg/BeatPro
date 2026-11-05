from collections import defaultdict
from datetime import timedelta

from odoo import api, fields, models
from odoo.exceptions import UserError
from odoo.fields import Command

from .beatpro_tools import money
from .beatpro_van_transfer import move_stock

RETURN_REASONS = [
    ('damaged', "Damaged"),
    ('expired', "Expired"),
    ('not_selling', "Not selling"),
    ('wrong_item', "Wrong item"),
    ('other', "Other"),
]
NOT_RESELLABLE = ('damaged', 'expired')


class BeatproShopReturn(models.Model):
    """Goods a rep takes back from a shop.

    Goods that can be sold again go back into the rep's van (or the main warehouse when
    the rep has no van); damaged and expired goods go to the damaged stock area. The shop
    gets a draft credit note, which accounting checks and posts.
    """
    _name = 'beatpro.shop.return'
    _description = 'BeatPro Shop Return'
    _inherit = ['mail.thread', 'beatpro.mobile.mixin']
    _order = 'date desc, id desc'

    name = fields.Char(string="Reference", readonly=True, copy=False, default=lambda self: self.env._("New"))
    partner_id = fields.Many2one('res.partner', string="Shop", required=True, index=True, tracking=True)
    user_id = fields.Many2one('res.users', string="Rep", required=True, index=True,
                              default=lambda self: self.env.user)
    visit_id = fields.Many2one('beatpro.visit', string="Visit", index='btree_not_null')
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')
    date = fields.Date(required=True, default=fields.Date.context_today, index=True)
    state = fields.Selection([
        ('draft', "Draft"),
        ('done', "Taken Back"),
        ('cancel', "Cancelled"),
    ], default='draft', required=True, tracking=True, copy=False)
    line_ids = fields.One2many('beatpro.shop.return.line', 'return_id', string="Products", copy=True)
    amount_total = fields.Monetary(compute='_compute_amount_total', string="Credit")
    credit_note_id = fields.Many2one('account.move', string="Credit Note", readonly=True, copy=False)
    picking_ids = fields.Many2many('stock.picking', string="Receipts", readonly=True, copy=False)

    @api.depends('line_ids.subtotal')
    def _compute_amount_total(self):
        for ret in self:
            ret.amount_total = sum(ret.line_ids.mapped('subtotal'))

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if vals.get('name', self.env._("New")) == self.env._("New"):
                vals['name'] = self.env['ir.sequence'].sudo().next_by_code('beatpro.shop.return') or self.env._("New")
        return super().create(vals_list)

    @api.model
    def beatpro_return_candidates(self, partner_id):
        """Products the shop bought in the last 120 days, with the last date and
        price, so the rep can pick what to take back.

        :return: list of ``{'product_id', 'name', 'last_date', 'price_unit', 'bought'}``
        """
        partner = self.env['res.partner'].browse(partner_id).commercial_partner_id
        lines = self.env['sale.order.line'].sudo().search([
            ('order_id.partner_id', 'child_of', partner.id), ('order_id.state', '=', 'sale'),
            ('product_id', '!=', False), ('display_type', '=', False),
            ('order_id.date_order', '>=', fields.Datetime.now() - timedelta(days=120)),
        ], order='id desc')
        result = {}
        bought = defaultdict(float)
        for line in lines:
            product = line.product_id
            bought[product] += line.product_uom_id._compute_quantity(line.qty_delivered, product.uom_id)
            if product not in result:
                qty = line.product_uom_id._compute_quantity(1.0, product.uom_id) or 1.0
                result[product] = {
                    'product_id': product.id,
                    'name': product.display_name,
                    'last_date': fields.Date.to_string(line.order_id.date_order.date()),
                    'price_unit': round(line.price_unit * (1 - (line.discount or 0.0) / 100.0) / qty, 2),
                }
        return [dict(item, bought=bought[product]) for product, item in result.items()]

    def action_confirm(self):
        """Take the goods back: receive them and make the shop's credit note."""
        for ret in self:
            if ret.state != 'draft':
                continue
            lines = ret.line_ids.filtered(lambda l: l.qty > 0)
            if not lines:
                raise UserError(self.env._("Add the products the shop is giving back."))
            ret._receive_goods(lines)
            ret._make_credit_note(lines)
            ret.state = 'done'
        return True

    def _receive_goods(self, lines):
        van = self.user_id.beatpro_van_warehouse_id
        main = self.env['stock.warehouse']._beatpro_main(self.company_id)
        customer = self.partner_id.property_stock_customer
        resell = defaultdict(float)
        damaged = defaultdict(float)
        for line in lines.filtered(lambda l: l.product_id.is_storable):
            (resell if line.resellable else damaged)[line.product_id] += line.qty
        sellable_wh = van or main
        pickings = move_stock(
            self.env, customer, sellable_wh.lot_stock_id, resell, sellable_wh.in_type_id, self.name, self.partner_id)
        pickings |= move_stock(
            self.env, customer, main._beatpro_damaged_location(), damaged, main.in_type_id, self.name, self.partner_id)
        self.sudo().picking_ids = [Command.set(pickings.ids)]

    def _make_credit_note(self, lines):
        reasons = dict(RETURN_REASONS)
        credit_note = self.env['account.move'].sudo().with_company(self.company_id).create({
            'move_type': 'out_refund',
            'partner_id': self.partner_id.id,
            'invoice_user_id': self.user_id.id,
            'invoice_origin': self.name,
            'ref': self.env._("Goods taken back by %s", self.user_id.name),
            'invoice_line_ids': [Command.create({
                'product_id': line.product_id.id,
                'quantity': line.qty,
                'price_unit': line.price_unit,
                'name': "%s (%s)" % (line.product_id.display_name, reasons.get(line.reason)),
            }) for line in lines],
        })
        self.sudo().credit_note_id = credit_note

    def action_cancel(self):
        if any(ret.state == 'done' for ret in self):
            raise UserError(self.env._("Goods already taken back cannot be cancelled. Return them with a new order."))
        self.write({'state': 'cancel'})
        return True

    def action_open_credit_note(self):
        self.ensure_one()
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'account.move',
            'res_id': self.credit_note_id.id,
            'views': [(False, 'form')],
        }

    @api.model
    def beatpro_submit_returns(self, vals_list):
        """Create the returns sent by the app and take the goods back.

        :return: ``{mobile_uuid: {'id', 'name', 'state', 'amount_total', 'credit_note'}}``
        """
        ids_by_uuid = self.beatpro_upsert(vals_list)
        returns = self.browse(list(ids_by_uuid.values()))
        returns.filtered(lambda r: r.state == 'draft').action_confirm()
        return {r.mobile_uuid: {
            'id': r.id, 'name': r.name, 'state': r.state, 'amount_total': r.amount_total,
            'credit_note': r.credit_note_id.name or False,
        } for r in returns.sudo()}

    def _beatpro_panel_item(self):
        self.ensure_one()
        count = sum(self.line_ids.mapped('qty'))
        return {
            'kind': 'return', 'res_model': self._name, 'res_id': self.id,
            'title': self.env._("Goods taken back %s", self.name),
            'sub': self.env._("%(count)s items · credit note %(state)s", count=int(count) if count == int(count) else count,
                              state=self.sudo().credit_note_id.name or self.env._("draft")),
            'amount': money(self.env, -self.amount_total),
        }


class BeatproShopReturnLine(models.Model):
    _name = 'beatpro.shop.return.line'
    _description = 'BeatPro Shop Return Line'

    return_id = fields.Many2one('beatpro.shop.return', required=True, ondelete='cascade', index=True)
    product_id = fields.Many2one('product.product', string="Product", required=True)
    qty = fields.Float(string="Quantity", digits='Product Unit', default=1.0)
    price_unit = fields.Float(string="Credit Each", digits='Product Price',
                              compute='_compute_price_unit', store=True, readonly=False)
    reason = fields.Selection(RETURN_REASONS, required=True, default='damaged')
    resellable = fields.Boolean(
        string="Can Be Sold Again", compute='_compute_resellable', store=True, readonly=False,
        help="Goes back into the van. Otherwise it goes to the damaged stock area.")
    subtotal = fields.Float(compute='_compute_subtotal', string="Credit")

    @api.depends('product_id', 'return_id.partner_id')
    def _compute_price_unit(self):
        for line in self:
            if not line.product_id:
                continue
            candidates = {c['product_id']: c for c in line.return_id.beatpro_return_candidates(
                line.return_id.partner_id.id)} if line.return_id.partner_id else {}
            last = candidates.get(line.product_id.id)
            line.price_unit = last['price_unit'] if last else line.product_id.lst_price

    @api.depends('reason')
    def _compute_resellable(self):
        for line in self:
            line.resellable = line.reason not in NOT_RESELLABLE

    @api.depends('qty', 'price_unit')
    def _compute_subtotal(self):
        for line in self:
            line.subtotal = line.qty * line.price_unit
