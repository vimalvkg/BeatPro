from odoo import api, fields, models
from odoo.exceptions import UserError


class StockWarehouse(models.Model):
    _inherit = 'stock.warehouse'

    beatpro_is_van = fields.Boolean(
        string="Sales Van",
        help="This warehouse is a rep's van. It is loaded from the main warehouse in the "
             "morning and unloaded back at day end.")
    beatpro_vehicle = fields.Char(string="Vehicle Number")
    beatpro_rep_ids = fields.One2many('res.users', 'beatpro_van_warehouse_id', string="Reps")
    beatpro_damaged_location_id = fields.Many2one(
        'stock.location', string="Damaged Stock Location", copy=False,
        help="Where damaged and expired goods taken back from shops are kept. It is not "
             "part of the sellable stock.")

    @api.model
    def _beatpro_main(self, company=None):
        """The warehouse vans load from and unload to: the company's first warehouse
        that is not a van."""
        company = company or self.env.company
        main = self.sudo().search([('company_id', '=', company.id), ('beatpro_is_van', '=', False)], limit=1)
        if not main:
            raise UserError(self.env._("Set up a main warehouse for %s before using vans.", company.name))
        return main

    def _beatpro_damaged_location(self):
        """The damaged stock area of this warehouse, created the first time it is needed."""
        self.ensure_one()
        warehouse = self.sudo()
        if not warehouse.beatpro_damaged_location_id:
            warehouse.beatpro_damaged_location_id = self.env['stock.location'].sudo().create({
                'name': self.env._("Damaged"),
                'location_id': warehouse.view_location_id.id,
                'usage': 'internal',
                'company_id': warehouse.company_id.id,
            })
        return warehouse.beatpro_damaged_location_id

    @api.model
    def beatpro_create_van(self, user_id, vehicle=False):
        """Create a van warehouse for a rep and link it to them.

        :return: the new warehouse's id
        """
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise UserError(self.env._("Only a BeatPro supervisor can set up vans."))
        user = self.env['res.users'].browse(user_id)
        company = user.company_id
        existing = self.sudo().with_context(active_test=False).search([('company_id', '=', company.id)]).mapped('code')
        number = 1
        while 'VAN%s' % number in existing:
            number += 1
        van = self.sudo().create({
            'name': self.env._("Van %(number)s · %(rep)s", number=number, rep=user.name),
            'code': 'VAN%s' % number,
            'company_id': company.id,
            'beatpro_is_van': True,
            'beatpro_vehicle': vehicle,
        })
        user.sudo().beatpro_van_warehouse_id = van
        return van.id
