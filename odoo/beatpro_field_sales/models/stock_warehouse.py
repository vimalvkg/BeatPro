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
    beatpro_invoice_journal_id = fields.Many2one(
        'account.journal', string="Van Invoice Series", copy=False,
        domain="[('type', '=', 'sale')]",
        help="Invoices made at the shop from this van are numbered in this journal's own "
             "series (for example VAN1/2026/00001), so the rep's phone can number them "
             "without signal.")
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

    def _beatpro_invoice_journal(self):
        """The van's own invoice journal, created the first time it is needed."""
        self.ensure_one()
        van = self.sudo()
        if not van.beatpro_invoice_journal_id:
            Journal = self.env['account.journal'].sudo()
            sales = Journal.search([*Journal._check_company_domain(van.company_id), ('type', '=', 'sale')], limit=1)
            code = (van.code or 'VAN')[:5].upper()
            existing = set(Journal.with_context(active_test=False).search(
                Journal._check_company_domain(van.company_id)).mapped('code'))
            n = 1
            while code in existing:
                code = ('V%s' % n)[:5]
                n += 1
            van.beatpro_invoice_journal_id = Journal.create({
                'name': self.env._("Van invoices · %s", van.beatpro_vehicle or van.name),
                'code': code,
                'type': 'sale',
                'company_id': van.company_id.id,
                'default_account_id': sales.default_account_id.id,
                'sequence': (sales.sequence or 10) + 1,
            })
        return van.beatpro_invoice_journal_id

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
