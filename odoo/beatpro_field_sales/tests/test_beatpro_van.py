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
        self.assertEqual(ret.credit_note_id.state, 'posted', 'The credit note counts at once')
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


@tagged('post_install', '-at_install')
class TestBeatproVanInvoice(TestBeatproVan):
    """Tax invoices made at the shop for van deliveries (UAE VAT 5%)."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.vat5 = cls.env['account.tax'].create({
            'name': 'VAT 5%', 'amount': 5.0, 'amount_type': 'percent', 'type_tax_use': 'sale',
            'company_id': cls.env.company.id,
        })
        (cls.biscuits | cls.salt).taxes_id = cls.vat5
        cls.env.company.vat = '100234567800003'
        cls.shop.vat = '100987654300003'

    def test_van_delivery_is_invoiced_in_the_van_series(self):
        self._loaded_van()
        order = self._order('split', {self.biscuits: 6, self.salt: 40})
        invoice = order.sudo().invoice_ids
        self.assertEqual(len(invoice), 1)
        self.assertEqual(invoice.state, 'posted')
        self.assertEqual(invoice.journal_id, self.van.beatpro_invoice_journal_id)
        self.assertTrue(invoice.name.startswith(invoice.journal_id.code + '/'))
        self.assertEqual(invoice.beatpro_van_id, self.van)
        # Only what the van handed over: 6 biscuits at 240, plus 5% VAT. Salt comes from the warehouse later.
        self.assertEqual(invoice.invoice_line_ids.product_id, self.biscuits)
        self.assertAlmostEqual(invoice.amount_untaxed, 1440.0)
        self.assertAlmostEqual(invoice.amount_tax, 72.0)
        self.assertFalse(invoice._beatpro_is_simplified())
        self.assertEqual(order.beatpro_van_invoice_name, invoice.name)

        # Switched off: no invoice at the shop.
        self.env.company.beatpro_van_invoice = False
        self.assertFalse(self._order('van', {self.biscuits: 1}).sudo().invoice_ids)

    def test_app_numbers_invoices_offline(self):
        self._loaded_van()
        series = self.env['res.users'].with_user(self.rep).beatpro_app_context()['van_invoice']
        self.assertEqual(series['next'], 1)
        self.assertEqual(series['company']['trn'], '100234567800003')
        name = '%s/%s/%05d' % (series['journal'], series['year'], series['next'])

        def submit(uuid, number):
            return self.env['sale.order'].with_user(self.rep).beatpro_submit_orders([{
                'mobile_uuid': uuid, 'partner_id': self.shop.id, 'beatpro_delivery_mode': 'van',
                'beatpro_van_invoice_name': number,
                'beatpro_van_invoice_date': fields.Date.to_string(fields.Date.today()),
                'order_line': [Command.create({'product_id': self.biscuits.id, 'product_uom_qty': 2})],
            }])[uuid]

        result = submit('inv-order-1', name)
        self.assertEqual(result['invoice']['name'], name, 'Odoo keeps the number printed on the slip')
        self.assertAlmostEqual(result['invoice']['amount_total'], 504.0)
        # A retry does not make a second invoice.
        self.assertEqual(submit('inv-order-1', name)['invoice']['id'], result['invoice']['id'])
        self.assertEqual(self.env['res.users'].with_user(self.rep).beatpro_app_context()['van_invoice']['next'], 2)
        # A number already used (e.g. by an invoice made in Odoo meanwhile) gets the next free one.
        clash = submit('inv-order-2', name)
        self.assertNotEqual(clash['invoice']['name'], name)
        self.assertTrue(clash['invoice']['name'].startswith(series['journal'] + '/'))

    def test_thermal_slip(self):
        self._loaded_van()
        invoice = self._order('van', {self.biscuits: 6, self.salt: 2}).sudo().invoice_ids
        html = self.env['ir.actions.report']._render_qweb_html(
            'beatpro_field_sales.report_invoice_slip_80', invoice.ids)[0].decode()
        for text in ('TAX INVOICE', 'فاتورة ضريبية', 'TRN 100234567800003', 'TRN 100987654300003',
                     'VAT 5%', invoice.name, 'Received by'):
            self.assertIn(text, html)
        self.shop.vat = False
        html58 = self.env['ir.actions.report']._render_qweb_html(
            'beatpro_field_sales.report_invoice_slip_58', invoice.ids)[0].decode()
        self.assertIn('SIMPLIFIED TAX INVOICE', html58)
        self.assertIn('bp-slip-58', html58)

        # The PDF is as long as the slip, on 80 mm paper.
        report = self.env['ir.actions.report'].with_context(beatpro_slip_height_mm=168)
        args = report._build_wkhtmltopdf_args(self.env.ref('beatpro_field_sales.paperformat_slip_80'), False)
        self.assertEqual(args[args.index('--page-width') + 1], '80mm')
        self.assertEqual(args[args.index('--page-height') + 1], '168mm')
        self.assertEqual(self.env['account.move']._beatpro_slip_height_mm(invoice, '80'), 105 + 9 * 3)

        action = invoice.action_beatpro_print_slip()
        self.assertEqual(action['report_name'], 'beatpro_field_sales.report_invoice_slip_80')

    def test_collection_settles_shop_invoice_and_credit_notes(self):
        """A payment collected for an invoice printed at the shop settles that invoice,
        and credit notes for goods taken back can be used against invoices."""
        self._loaded_van()
        cash = self.company_data['default_journal_cash'].inbound_payment_method_line_ids[:1]
        Order = self.env['sale.order'].with_user(self.rep)
        Payment = self.env['account.payment'].with_user(self.rep)

        def van_order(uuid, qty):
            return Order.beatpro_submit_orders([{
                'mobile_uuid': uuid, 'partner_id': self.shop.id, 'beatpro_delivery_mode': 'van',
                'beatpro_van_invoice_name': 'X',
                'order_line': [Command.create({'product_id': self.biscuits.id, 'product_uom_qty': qty})],
            }])[uuid]['invoice']

        # The phone doesn't know the invoice's id: it names the order it was printed for.
        info = van_order('pay-ord-1', 2)
        Payment.beatpro_register_payment([{
            'mobile_uuid': 'pay-a', 'partner_id': self.shop.id, 'amount': info['amount_total'],
            'payment_method_line_id': cash.id, 'order_uuids': ['pay-ord-1'],
        }])
        invoice = self.env['account.move'].browse(info['id'])
        self.assertIn(invoice.payment_state, ('paid', 'in_payment'))

        # Goods taken back: a posted credit note the shop can use later.
        ret = self.env['beatpro.shop.return'].with_user(self.rep).beatpro_submit_returns([{
            'mobile_uuid': 'pay-ret-1', 'partner_id': self.shop.id,
            'line_ids': [Command.create({'product_id': self.biscuits.id, 'qty': 1, 'reason': 'expired', 'price_unit': 240.0})],
        }])['pay-ret-1']
        credit_note = self.env['beatpro.shop.return'].browse(ret['id']).credit_note_id
        self.assertEqual(credit_note.state, 'posted')
        open_items = self.env['res.partner'].with_user(self.rep).beatpro_open_invoices(self.shop.ids)
        credit = next(i for i in open_items if i['id'] == credit_note.id)
        self.assertEqual(credit['kind'], 'credit_note')
        self.assertAlmostEqual(credit['amount_due'], -252.0)

        # Next invoice: the credit note pays part of it, cash the rest.
        info = van_order('pay-ord-2', 3)
        self.assertAlmostEqual(info['amount_total'], 756.0)
        Payment.beatpro_register_payment([{
            'mobile_uuid': 'pay-b', 'partner_id': self.shop.id, 'amount': 504.0,
            'payment_method_line_id': cash.id, 'order_uuids': ['pay-ord-2'], 'return_uuids': ['pay-ret-1'],
        }])
        invoice = self.env['account.move'].browse(info['id'])
        self.assertIn(invoice.payment_state, ('paid', 'in_payment'))
        self.assertIn(credit_note.payment_state, ('paid', 'reversed'))

        # A credit note bigger than the invoice: no money changes hands.
        big = self.env['beatpro.shop.return'].with_user(self.rep).beatpro_submit_returns([{
            'mobile_uuid': 'pay-ret-2', 'partner_id': self.shop.id,
            'line_ids': [Command.create({'product_id': self.biscuits.id, 'qty': 2, 'reason': 'expired', 'price_unit': 240.0})],
        }])['pay-ret-2']
        info = van_order('pay-ord-3', 1)
        result = Payment.beatpro_register_payment([{
            'mobile_uuid': 'pay-c', 'partner_id': self.shop.id, 'amount': 0,
            'invoice_ids': [info['id']], 'return_uuids': ['pay-ret-2'],
        }])
        self.assertEqual(result['pay-c'], 0)
        self.assertIn(self.env['account.move'].browse(info['id']).payment_state, ('paid', 'reversed'))
        left = self.env['beatpro.shop.return'].browse(big['id']).credit_note_id
        self.assertAlmostEqual(left.amount_residual, 252.0, msg='The rest of the credit stays for later')
        with self.assertRaises(UserError):
            Payment.beatpro_register_payment([{'mobile_uuid': 'pay-d', 'partner_id': self.shop.id, 'amount': 0,
                                               'return_uuids': ['pay-ret-2']}])
