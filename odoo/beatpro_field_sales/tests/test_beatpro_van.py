from odoo import fields
from odoo.exceptions import AccessError, UserError
from odoo.fields import Command
from odoo.tests import new_test_user, tagged

from odoo.addons.account.tests.common import AccountTestInvoicingCommon


@tagged('post_install', '-at_install')
class TestBeatproVan(AccountTestInvoicingCommon):

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        company_ids = [(6, 0, cls.env.company.ids)]
        common = {'company_id': cls.env.company.id, 'company_ids': company_ids}
        cls.rep = new_test_user(cls.env, login='van_rep', groups='beatpro_field_sales.group_beatpro_rep', **common)
        cls.supervisor = new_test_user(
            cls.env, login='van_sup', groups='beatpro_field_sales.group_beatpro_supervisor', **common)
        cls.storekeeper = new_test_user(cls.env, login='van_store', groups='stock.group_stock_user', **common)
        cls.shop = cls.env['res.partner'].create({'name': 'Patel Kirana'})
        cls.biscuits = cls.env['product.product'].create({
            'name': 'Parle-G Biscuits', 'type': 'consu', 'is_storable': True, 'list_price': 240.0, 'taxes_id': False,
        })
        cls.salt = cls.env['product.product'].create({
            'name': 'Tata Salt', 'type': 'consu', 'is_storable': True, 'list_price': 280.0, 'taxes_id': False,
        })
        cls.main = cls.env['stock.warehouse'].search([('company_id', '=', cls.env.company.id)], limit=1)
        cls.van = cls.env['stock.warehouse'].browse(
            cls.env['stock.warehouse'].with_user(cls.supervisor).beatpro_create_van(cls.rep.id, 'MH 02 AB 4521'))
        Quant = cls.env['stock.quant']
        Quant._update_available_quantity(cls.biscuits, cls.main.lot_stock_id, 100)
        Quant._update_available_quantity(cls.salt, cls.main.lot_stock_id, 50)

    def qty(self, product, location):
        return product.with_context(location=location.id).qty_available

    def _load(self, quantities, user=None):
        transfer = self.env['beatpro.van.transfer'].with_user(user or self.rep).create({
            'kind': 'load',
            'line_ids': [Command.create({'product_id': p.id, 'qty': q}) for p, q in quantities.items()],
        })
        transfer.action_send()
        return transfer

    def _loaded_van(self):
        transfer = self._load({self.biscuits: 18, self.salt: 10})
        transfer.with_user(self.storekeeper).action_load()
        return transfer

    def _order(self, mode, quantities, user=None):
        order = self.env['sale.order'].with_user(user or self.rep).create({
            'partner_id': self.shop.id,
            'beatpro_delivery_mode': mode,
            'order_line': [Command.create({'product_id': p.id, 'product_uom_qty': q}) for p, q in quantities.items()],
        })
        order.action_confirm()
        return order

    # ------------------------------------------------------------------
    # Morning load
    # ------------------------------------------------------------------

    def test_van_setup(self):
        self.assertTrue(self.van.beatpro_is_van)
        self.assertEqual(self.rep.beatpro_van_warehouse_id, self.van)
        self.assertEqual(self.env['stock.warehouse']._beatpro_main(), self.main)
        context = self.env['res.users'].with_user(self.rep).beatpro_app_context()
        self.assertEqual(context['van']['vehicle'], 'MH 02 AB 4521')
        self.assertFalse(context['van']['self_load'])
        self.assertIn('not_selling', [r['value'] for r in context['return_reasons']])
        with self.assertRaises(UserError):
            self.env['stock.warehouse'].with_user(self.rep).beatpro_create_van(self.rep.id)

    def test_load_waits_for_storekeeper(self):
        transfer = self._load({self.biscuits: 18, self.salt: 10})
        self.assertEqual(transfer.state, 'sent')
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 0)
        with self.assertRaises(AccessError):
            transfer.with_user(self.rep).action_load()
        with self.assertRaises(UserError):
            transfer.line_ids[0].with_user(self.rep).qty = 30

        # The storekeeper can change the quantities, then loads the van.
        transfer.line_ids.filtered(lambda l: l.product_id == self.salt).with_user(self.storekeeper).qty = 12
        transfer.with_user(self.storekeeper).action_load()
        self.assertEqual(transfer.state, 'done')
        self.assertEqual(transfer.picking_id.state, 'done')
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 18)
        self.assertEqual(self.qty(self.salt, self.van.lot_stock_id), 12)
        self.assertEqual(self.qty(self.biscuits, self.main.lot_stock_id), 82)

    def test_rep_who_loads_own_van(self):
        self.rep.beatpro_self_load = True
        transfer = self._load({self.biscuits: 5})
        self.assertEqual(transfer.state, 'done')
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 5)

    def test_load_suggestion_from_last_orders(self):
        self.env['beatpro.route'].with_user(self.supervisor).create({
            'name': 'Andheri', 'user_id': self.rep.id,
            'line_ids': [Command.create({'partner_id': self.shop.id})],
        })
        self._order('warehouse', {self.biscuits: 4})
        self._order('warehouse', {self.biscuits: 7, self.salt: 2})
        suggestion = self.env['beatpro.van.transfer'].with_user(self.rep).beatpro_load_suggestion()
        by_product = {s['product_id']: s['qty'] for s in suggestion}
        self.assertEqual(by_product, {self.biscuits.id: 6, self.salt.id: 1})

        action = self.env['beatpro.van.transfer'].with_user(self.rep).action_beatpro_new('load')
        transfer = self.env['beatpro.van.transfer'].browse(action['res_id'])
        self.assertEqual(transfer.state, 'draft')
        self.assertEqual(transfer.total_qty, 7)

    # ------------------------------------------------------------------
    # Orders: van, split, main warehouse
    # ------------------------------------------------------------------

    def test_van_order_is_delivered_now(self):
        self._loaded_van()
        order = self._order('van', {self.biscuits: 6})
        self.assertEqual(order.warehouse_id, self.van)
        self.assertEqual(order.picking_ids.state, 'done')
        self.assertEqual(order.order_line.qty_delivered, 6)
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 12)

    def test_van_order_needs_stock_in_the_web_client(self):
        self._loaded_van()
        with self.assertRaises(UserError):
            self._order('van', {self.biscuits: 30})

    def test_split_order(self):
        self._loaded_van()
        order = self._order('split', {self.biscuits: 6, self.salt: 40})
        self.assertEqual(order.user_id, self.rep)
        van_picking = order.picking_ids.filtered(lambda p: p.picking_type_id.warehouse_id == self.van)
        main_picking = order.picking_ids.filtered(lambda p: p.picking_type_id.warehouse_id == self.main)
        self.assertEqual(van_picking.state, 'done')
        self.assertEqual(van_picking.move_ids.product_id, self.biscuits)
        self.assertNotEqual(main_picking.state, 'done')
        self.assertEqual(main_picking.move_ids.product_id, self.salt)
        self.assertEqual(self.qty(self.salt, self.van.lot_stock_id), 10)

    def test_main_warehouse_order_counts_for_rep(self):
        order = self._order('warehouse', {self.salt: 4})
        self.assertEqual(order.warehouse_id, self.main)
        self.assertEqual(order.user_id, self.rep)
        self.assertNotEqual(order.picking_ids.state, 'done')

    def test_app_order_from_van(self):
        self._loaded_van()
        result = self.env['sale.order'].with_user(self.rep).beatpro_submit_orders([{
            'mobile_uuid': 'van-order-1', 'partner_id': self.shop.id, 'beatpro_delivery_mode': 'van',
            'order_line': [Command.create({'product_id': self.biscuits.id, 'product_uom_qty': 20})],
        }])
        # The rep already handed the goods over, so the van goes below zero instead of failing.
        self.assertTrue(result['van-order-1']['delivered_now'])
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), -2)

    # ------------------------------------------------------------------
    # Shop returns
    # ------------------------------------------------------------------

    def test_shop_return(self):
        self._loaded_van()
        self._order('van', {self.biscuits: 6})
        candidates = self.env['beatpro.shop.return'].with_user(self.rep).beatpro_return_candidates(self.shop.id)
        self.assertEqual(candidates[0]['product_id'], self.biscuits.id)
        self.assertEqual(candidates[0]['price_unit'], 240.0)

        result = self.env['beatpro.shop.return'].with_user(self.rep).beatpro_submit_returns([{
            'mobile_uuid': 'ret-1', 'partner_id': self.shop.id,
            'line_ids': [
                Command.create({'product_id': self.biscuits.id, 'qty': 3, 'reason': 'not_selling'}),
                Command.create({'product_id': self.salt.id, 'qty': 2, 'reason': 'damaged', 'price_unit': 280.0}),
            ],
        }])['ret-1']
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['amount_total'], 3 * 240 + 2 * 280)
        ret = self.env['beatpro.shop.return'].browse(result['id'])
        self.assertEqual(ret.credit_note_id.move_type, 'out_refund')
        self.assertEqual(ret.credit_note_id.state, 'draft')
        self.assertEqual(ret.credit_note_id.amount_total, 1280.0)
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 15)
        self.assertEqual(self.qty(self.salt, self.van.lot_stock_id), 10)
        self.assertEqual(self.qty(self.salt, self.main.beatpro_damaged_location_id), 2)
        # Damaged goods are not sellable stock.
        self.assertEqual(self.qty(self.salt, self.main.lot_stock_id), 40)
        # A retry does not take the goods back twice.
        self.env['beatpro.shop.return'].with_user(self.rep).beatpro_submit_returns([{
            'mobile_uuid': 'ret-1', 'partner_id': self.shop.id, 'line_ids': [],
        }])
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 15)

        stock = self.env['beatpro.van.transfer'].with_user(self.rep).beatpro_van_stock()
        row = next(i for i in stock['van_items'] if i['product_id'] == self.biscuits.id)
        self.assertEqual((row['loaded'], row['sold'], row['returned'], row['left']), (18, 6, 3, 15))
        self.assertEqual(stock['in_van'], 25)

    # ------------------------------------------------------------------
    # Day-end unload
    # ------------------------------------------------------------------

    def test_unload_with_shortage_needs_supervisor(self):
        self._loaded_van()
        self._order('van', {self.biscuits: 6})
        Transfer = self.env['beatpro.van.transfer'].with_user(self.rep)
        expected = {l['product_id']: l['qty_expected'] for l in Transfer.beatpro_unload_start()}
        self.assertEqual(expected, {self.biscuits.id: 12, self.salt.id: 10})

        unload = Transfer.create({
            'kind': 'unload',
            'line_ids': [
                Command.create({'product_id': self.biscuits.id, 'qty_expected': 12, 'qty': 11}),
                Command.create({'product_id': self.salt.id, 'qty_expected': 10, 'qty': 10}),
            ],
        })
        self.assertTrue(unload.has_difference)
        with self.assertRaises(UserError):
            unload.action_send()
        unload.note = "One box torn, given to the shop as a free sample."
        unload.action_send()
        self.assertEqual(unload.state, 'sent')

        desk = self.env['beatpro.van.transfer'].with_user(self.storekeeper).beatpro_desk_data()
        self.assertEqual([c['id'] for c in desk['unloads']], unload.ids)
        self.assertEqual(desk['unloads'][0]['differences'][0]['difference'], -1)
        self.assertFalse(desk['vans'], "A van being unloaded is not on the road.")
        with self.assertRaises(AccessError):
            self.env['beatpro.van.transfer'].with_user(self.rep).beatpro_desk_data()

        unload.with_user(self.storekeeper).action_receive()
        self.assertEqual(unload.state, 'to_approve')
        self.assertEqual(self.qty(self.biscuits, self.main.lot_stock_id), 82 + 11)
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 1)
        with self.assertRaises(AccessError):
            unload.with_user(self.storekeeper).action_approve_difference()

        unload.with_user(self.supervisor).action_approve_difference()
        self.assertEqual(unload.state, 'done')
        self.assertEqual(self.qty(self.biscuits, self.van.lot_stock_id), 0)
        self.assertEqual(self.qty(self.salt, self.van.lot_stock_id), 0)

    def test_unload_from_app_matching_count(self):
        self._loaded_van()
        result = self.env['beatpro.van.transfer'].with_user(self.rep).beatpro_submit_transfers([{
            'mobile_uuid': 'unload-1', 'kind': 'unload',
            # Salt was not counted on the phone: it is added as 0 against 10 expected.
            'line_ids': [Command.create({'product_id': self.biscuits.id, 'qty_expected': 99, 'qty': 18})],
            'note': 'Salt bag left at the depot',
        }])
        unload = self.env['beatpro.van.transfer'].browse(result['unload-1']['id'])
        self.assertEqual(unload.state, 'sent')
        lines = {l.product_id: (l.qty_expected, l.qty) for l in unload.line_ids}
        self.assertEqual(lines, {self.biscuits: (18, 18), self.salt: (10, 0)})
        self.assertEqual(self.env['beatpro.van.transfer'].with_user(self.rep).beatpro_submit_transfers([{
            'mobile_uuid': 'unload-1', 'kind': 'unload', 'line_ids': [],
        }])['unload-1']['id'], unload.id)
