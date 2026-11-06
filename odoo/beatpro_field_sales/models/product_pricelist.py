from odoo import api, models


class ProductPricelist(models.Model):
    _inherit = 'product.pricelist'

    @api.model
    def beatpro_prices(self, pricelist_ids, product_ids):
        """Unit prices of products under each price list, for pricing orders offline.

        :return: ``{pricelist_id: {product_id: price}}`` (ids as strings, for JSON)
        """
        products = self.env['product.product'].browse(product_ids)
        return {
            str(pricelist.id): {
                str(product_id): price
                for product_id, price in pricelist._get_products_price(products, quantity=1.0).items()
            } for pricelist in self.browse(pricelist_ids)
        }

    @api.model
    def beatpro_price_breaks(self, pricelist_ids, product_ids):
        """Quantity prices (slabs) for pricing orders offline.

        Quantities are in each product's own unit (usually pieces), prices are for one of it.

        :return: ``{pricelist_id: {product_id: [[min_qty, price], ...]}}`` (ids as strings),
            lowest quantity first; products without quantity prices are left out
        """
        products = self.env['product.product'].browse(product_ids)
        thresholds = sorted(set(self.env['product.pricelist.item'].sudo().search([
            ('min_quantity', '>', 1),
            ('pricelist_id.company_id', 'in', [False, self.env.company.id]),
        ]).mapped('min_quantity')))
        result = {}
        for pricelist in self.browse(pricelist_ids):
            base = pricelist._get_products_price(products, quantity=1.0)
            breaks = {}
            for qty in thresholds:
                for product_id, price in pricelist._get_products_price(products, quantity=qty).items():
                    last = breaks.get(product_id, [[1.0, base[product_id]]])[-1][1]
                    if pricelist.currency_id.compare_amounts(price, last):
                        breaks.setdefault(product_id, [[1.0, base[product_id]]]).append([qty, price])
            result[str(pricelist.id)] = {str(pid): rows[1:] for pid, rows in breaks.items()}
        return result
