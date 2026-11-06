from odoo import api, models

from .beatpro_scheme import unit_short


class ProductProduct(models.Model):
    _inherit = 'product.product'

    @api.model
    def beatpro_units(self, product_ids):
        """The units each product sells in: its own unit first, then its packagings (cases).

        ``factor`` is the unit's absolute size (24 for a case of 24 pieces), so the app
        converts cases and pieces without Odoo.

        :return: ``{product_id: [{'id', 'name', 'short', 'factor'}, ...]}`` (ids as strings)
        """
        result = {}
        for product in self.browse(product_ids):
            uoms = product.uom_id | product.uom_ids.filtered(lambda u: u._has_common_reference(product.uom_id))
            result[str(product.id)] = [{
                'id': uom.id,
                'name': uom.name,
                'short': unit_short(self.env, uom, product),
                'factor': uom.factor,
            } for uom in uoms]
        return result

    def _beatpro_pack_text(self, qty):
        """``12 cs + 5 pc`` for a quantity in the product's own unit, using its biggest case."""
        self.ensure_one()
        cases = self.uom_ids.filtered(lambda u: u._has_common_reference(self.uom_id) and u.factor > self.uom_id.factor)
        if not cases:
            return '%g %s' % (qty, unit_short(self.env, self.uom_id, self))
        case = max(cases, key=lambda u: u.factor)
        per_case = case.factor / self.uom_id.factor
        sign = '-' if qty < 0 else ''
        qty = abs(qty)
        full = int((qty + 1e-9) // per_case)
        rest = round(qty - full * per_case, 3)
        parts = []
        if full:
            parts.append('%d cs' % full)
        if rest or not full:
            parts.append('%g %s' % (rest, unit_short(self.env, self.uom_id, self)))
        return sign + ' + '.join(parts)
