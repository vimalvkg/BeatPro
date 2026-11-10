from datetime import timedelta

from odoo import fields
from odoo.exceptions import AccessError
from odoo.fields import Command
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon
from odoo.addons.beatpro_field_sales.models.beatpro_inventory import weekday_average_need


@tagged('post_install', '-at_install')
class TestBeatproInventory(AccountTestInvoicingCommon):

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        common = {'company_id': cls.env.company.id, 'company_ids': [(6, 0, cls.env.company.ids)]}
        cls.rep = new_test_user(cls.env, login='inv_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(
            cls.env, login='inv_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        cls.storekeeper = new_test_user(cls.env, login='inv_store', groups='stock.group_stock_user', **common)
        cls.env.user.group_ids |= cls.env.ref('stock.group_production_lot')
        cls.shop = cls.env['res.partner'].create({'name': 'Al Madina Supermarket'})
        cls.laban = cls.env['product.product'].create({
            'name': 'Almarai Laban 1 L', 'type': 'consu', 'is_storable': True, 'list_price': 6.0, 'taxes_id': False,
            'tracking': 'lot', 'use_expiration_date': True,
        })
        cls.tide = cls.env['product.product'].create({
            'name': 'Tide 1 kg', 'type': 'consu', 'is_storable': True, 'list_price': 18.0, 'taxes_id': False,
        })
        cls.main = cls.env['stock.warehouse'].search([('company_id', '=', cls.env.company.id)], limit=1)
        cls.van = cls.env['stock.warehouse'].browse(
            cls.env['stock.warehouse'].with_user(cls.supervisor).beatpro_create_van(cls.rep.id, 'DXB 4521'))
        cls.env['stock.warehouse']._beatpro_apply_fefo()
        now = fields.Datetime.now()
        Lot = cls.env['stock.lot']
        cls.lot_late = Lot.create({'name': 'L-LATE', 'product_id': cls.laban.id, 'expiration_date': now + timedelta(days=60)})
        cls.lot_soon = Lot.create({'name': 'L-SOON', 'product_id': cls.laban.id, 'expiration_date': now + timedelta(days=5)})
        Quant = cls.env['stock.quant']
        Quant._update_available_quantity(cls.laban, cls.main.lot_stock_id, 30, lot_id=cls.lot_late)
        Quant._update_available_quantity(cls.laban, cls.main.lot_stock_id, 10, lot_id=cls.lot_soon)
        Quant._update_available_quantity(cls.tide, cls.main.lot_stock_id, 40)

    def qty(self, product, location, lot=None):
        context = {'location': location.id}
        if lot:
            context['lot_id'] = lot.id
        return product.with_context(**context).qty_available

    def _load(self, quantities):
        transfer = self.env['beatpro.van.transfer'].with_user(self.rep).create({
            'kind': 'load',
            'line_ids': [Command.create({'product_id': p.id, 'qty': q}) for p, q in quantities.items()],
        })
        transfer.action_send()
        return transfer

    def test_van_day_with_lots(self):
        self.assertEqual(self.main.lot_stock_id.removal_strategy_id, self.env.ref('product_expiry.removal_fefo'))

        # The morning load takes the lot that expires first.
        load = self._load({self.laban: 14, self.tide: 8})
        load.with_user(self.storekeeper).action_load()
        self.assertEqual(load.state, 'done')
        self.assertEqual(self.qty(self.laban, self.van.lot_stock_id, self.lot_soon), 10)
        self.assertEqual(self.qty(self.laban, self.van.lot_stock_id, self.lot_late), 4)

        # Delivered from the van and taken back from the shop: lots follow without the rep choosing.
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id, 'beatpro_delivery_mode': 'van',
            'order_line': [Command.create({'product_id': self.laban.id, 'product_uom_qty': 6})],
        })
        order.action_confirm()
        self.assertEqual(order.picking_ids.state, 'done')
        self.assertEqual(self.qty(self.laban, self.van.lot_stock_id), 8)
        self.env['beatpro.shop.return'].with_user(self.rep).beatpro_submit_returns([{
            'mobile_uuid': 'inv-ret-1', 'partner_id': self.shop.id,
            'line_ids': [Command.create({'product_id': self.laban.id, 'qty': 2, 'reason': 'not_selling'})],
        }])
        self.assertEqual(self.qty(self.laban, self.van.lot_stock_id), 10)

        # Unload one short: received and written off with lots.
        unload = self.env['beatpro.van.transfer'].with_user(self.rep).create({
            'kind': 'unload', 'note': 'One pack burst.',
            'line_ids': [
                Command.create({'product_id': self.laban.id, 'qty_expected': 10, 'qty': 9}),
                Command.create({'product_id': self.tide.id, 'qty_expected': 8, 'qty': 8}),
            ],
        })
        unload.action_send()
        unload.with_user(self.storekeeper).action_receive()
        unload.with_user(self.supervisor).action_approve_difference()
        self.assertEqual(unload.state, 'done')
        self.assertEqual(self.qty(self.laban, self.van.lot_stock_id), 0)
        self.assertEqual(self.qty(self.laban, self.main.lot_stock_id), 26 + 9)

    def test_dashboard(self):
        Inventory = self.env['beatpro.inventory']
        with self.assertRaises(AccessError):
            Inventory.with_user(self.rep).beatpro_inventory_dashboard()

        load = self._load({self.laban: 12, self.tide: 8})
        load.with_user(self.storekeeper).action_load()
        order = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id, 'beatpro_delivery_mode': 'van',
            'order_line': [Command.create({'product_id': self.tide.id, 'product_uom_qty': 8})],
        })
        order.action_confirm()
        # The van has no more Tide: the next order's Tide comes from the warehouse.
        short = self.env['sale.order'].with_user(self.rep).create({
            'partner_id': self.shop.id, 'beatpro_delivery_mode': 'split',
            'order_line': [Command.create({'product_id': self.tide.id, 'product_uom_qty': 5})],
        })
        short.action_confirm()
        self._load({self.tide: 10})  # waiting for the storekeeper

        data = Inventory.with_user(self.supervisor).beatpro_inventory_dashboard()
        van = next(v for v in data['vans'] if v['id'] == self.van.id)
        self.assertEqual(van['state'], 'red', 'Tide is out and a shop is waiting')
        self.assertIn('Tide 1 kg', van['note'])

        self.assertIn('1 orders went to the warehouse', data['kpis']['short_note'])
        self.assertEqual(len(data['waiting']), 1)
        # Lot L-SOON went into the van with the load: it expires in 5 days.
        lots = {row['lot'] for row in data['expiry']}
        self.assertIn('L-SOON', lots)
        self.assertTrue(any(a['title'].startswith('Expires in 7 days') for a in data['alerts']))


        detail = Inventory.with_user(self.supervisor).beatpro_inventory_van(self.van.id)
        rows = {p['name']: p for p in detail['products']}
        self.assertEqual(rows['Tide 1 kg']['status'], 'out')
        self.assertEqual(rows['Tide 1 kg']['label'], 'Out · 1 shop wants it')
        self.assertEqual(rows['Almarai Laban 1 L']['status'], 'expiring')
        self.assertEqual(detail['today']['short_orders'], 1)
        self.assertEqual(len(detail['unloads']), 7)

    def test_next_seven_days(self):
        # 4 weeks of 7 Tide a week, sold from the main warehouse, gives 7 for the next week.
        customer = self.env.ref('stock.stock_location_customers')
        today = fields.Date.context_today(self.env.user)
        for back in range(1, 29):
            if back % 7:
                continue
            move = self.env['stock.move'].create({
                'product_id': self.tide.id, 'product_uom_qty': 7, 'product_uom': self.tide.uom_id.id,
                'location_id': self.main.lot_stock_id.id, 'location_dest_id': customer.id,
            })
            move._action_confirm()
            move.quantity = 7
            move.picked = True
            move._action_done()
            move.date = fields.Datetime.now() - timedelta(days=back)
        need = weekday_average_need(self.env, self.env.company, today=today)
        self.assertAlmostEqual(need[self.tide], 7.0)
