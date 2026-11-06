import math

from odoo import api, fields, models
from odoo.exceptions import ValidationError

SCHEME_KINDS = [
    ('free_goods', "Free goods"),
    ('discount', "Discount"),
]


def unit_short(env, uom, product):
    """Short unit name for slips and the app: ``pc`` for pieces, ``cs`` for a case."""
    if uom == product.uom_id:
        return 'pc' if uom == env.ref('uom.product_uom_unit', raise_if_not_found=False) else uom.name
    return 'cs'


class BeatproScheme(models.Model):
    _name = 'beatpro.scheme'
    _description = "Sales Scheme"
    _order = 'sequence, id'

    name = fields.Char(required=True, translate=True,
                       help="What the shop sees on the slip, for example \"Oreo: buy 10 get 1 free\".")
    active = fields.Boolean(default=True)
    sequence = fields.Integer(default=10)
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    kind = fields.Selection(SCHEME_KINDS, required=True, default='free_goods')
    product_ids = fields.Many2many(
        'product.product', string="Products Bought", required=True,
        help="The products the shop must buy. Quantities of all of them count together.")
    min_qty = fields.Float(string="Buy at Least", required=True, default=1.0, digits='Product Unit')
    uom_id = fields.Many2one(
        'uom.uom', string="Counted In", required=True,
        default=lambda self: self.env.ref('uom.product_uom_unit', raise_if_not_found=False),
        help="The unit the quantity above is counted in, for example a case.")
    free_product_id = fields.Many2one(
        'product.product', string="Free Product",
        help="Leave empty to give the product bought (schemes on one product only).")
    free_qty = fields.Float(string="Free Quantity", default=1.0, digits='Product Unit',
                            help="Given for each full \"Buy at Least\" quantity: buy 20 get 2.")
    free_uom_id = fields.Many2one('uom.uom', string="Free Unit",
                                  help="Leave empty to give the free goods in the unit above.")
    discount = fields.Float(string="Discount (%)", digits='Discount')
    date_from = fields.Date(string="From")
    date_to = fields.Date(string="Until")
    rule = fields.Char(compute='_compute_rule')
    order_count = fields.Integer(string="Orders", compute='_compute_order_count')

    _min_qty_positive = models.Constraint('CHECK(min_qty > 0)', "The quantity to buy must be more than zero.")

    @api.constrains('kind', 'product_ids', 'free_product_id', 'free_qty', 'free_uom_id', 'uom_id', 'discount', 'date_from', 'date_to')
    def _check_rule(self):
        for scheme in self:
            if scheme.date_from and scheme.date_to and scheme.date_from > scheme.date_to:
                raise ValidationError(self.env._("Scheme %s ends before it starts.", scheme.name))
            if scheme.kind == 'free_goods':
                if scheme.free_qty <= 0:
                    raise ValidationError(self.env._("Scheme %s gives no free goods.", scheme.name))
                if not scheme.free_product_id and len(scheme.product_ids) > 1:
                    raise ValidationError(self.env._(
                        "Scheme %s is on several products: choose the free product.", scheme.name))
                free = scheme._free_product()
                if free and scheme._free_uom() not in free.product_tmpl_id._get_available_uoms():
                    raise ValidationError(self.env._(
                        "%(product)s isn't sold in %(uom)s. Pick one of its units for the free goods.",
                        product=free.display_name, uom=scheme._free_uom().name))
            elif not 0 < scheme.discount <= 100:
                raise ValidationError(self.env._("The discount of scheme %s must be between 0 and 100%%.", scheme.name))

    @api.depends('kind', 'min_qty', 'uom_id', 'free_qty', 'free_uom_id', 'free_product_id', 'discount', 'product_ids')
    def _compute_rule(self):
        for scheme in self:
            buy = "%g %s" % (scheme.min_qty, scheme.uom_id.name or '')
            if scheme.kind == 'discount':
                scheme.rule = self.env._("%(discount)g%% off from %(buy)s", discount=scheme.discount, buy=buy)
            else:
                free = scheme._free_product()
                scheme.rule = self.env._("Buy %(buy)s, get %(qty)g %(uom)s %(product)s free",
                                         buy=buy, qty=scheme.free_qty, uom=scheme._free_uom().name or '',
                                         product=free.name or '')

    def _compute_order_count(self):
        groups = self.env['sale.order.line'].sudo()._read_group(
            [('beatpro_scheme_id', 'in', self.ids), ('state', '=', 'sale')],
            ['beatpro_scheme_id'], ['order_id:count_distinct'])
        counts = {scheme.id: count for scheme, count in groups}
        for scheme in self:
            scheme.order_count = counts.get(scheme.id, 0)

    def _free_product(self):
        self.ensure_one()
        return self.free_product_id or self.product_ids[:1]

    def _free_uom(self):
        self.ensure_one()
        return self.free_uom_id or self.uom_id

    @api.model
    def _beatpro_running(self, company, day):
        return self.search([
            ('company_id', '=', company.id),
            '|', ('date_from', '=', False), ('date_from', '<=', day),
            '|', ('date_to', '=', False), ('date_to', '>=', day),
        ])

    def _beatpro_reward(self, lines):
        """What this scheme gives for the order lines bought.

        :param lines: the order's paid lines (not free ones)
        :return: ``(matching lines, times earned)``; times is 0 when the shop bought too little
        """
        self.ensure_one()
        matching = lines.filtered(lambda l: l.product_id in self.product_ids)
        bought = sum(l.product_uom_id.factor * l.product_uom_qty for l in matching)
        needed = self.min_qty * self.uom_id.factor
        times = math.floor(bought / needed + 1e-9) if needed else 0
        return matching, times

    @api.model
    def beatpro_schemes(self):
        """The schemes running now, for the app to apply offline.

        Quantities are in each unit's absolute factor (pieces for products sold by the piece),
        so the phone can add up cases and pieces of different products.
        """
        today = fields.Date.context_today(self)
        result = []
        for scheme in self.sudo()._beatpro_running(self.env.company, today):
            free = scheme._free_product()
            result.append({
                'id': scheme.id,
                'name': scheme.name,
                'kind': scheme.kind,
                'product_ids': scheme.product_ids.ids,
                'min_qty': scheme.min_qty * scheme.uom_id.factor,
                'min_label': "%g %s" % (scheme.min_qty, scheme.uom_id.name),
                'discount': scheme.discount,
                'free_product_id': free.id if scheme.kind == 'free_goods' else False,
                'free_qty': scheme.free_qty,
                'free_uom_id': scheme._free_uom().id,
                'date_to': fields.Date.to_string(scheme.date_to) if scheme.date_to else False,
                'rule': scheme.rule,
            })
        return result
