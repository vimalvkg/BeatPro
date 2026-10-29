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
