import math
from collections import defaultdict

from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError
from odoo.fields import Command
from odoo.tools import float_compare, float_is_zero

from .beatpro_tools import day_bounds_utc, initials, money

STOREKEEPER_GROUPS = ('stock.group_stock_user', 'beatpro_field_sales.group_beatpro_supervisor')


def is_storekeeper(env):
    return any(env.user.has_group(group) for group in STOREKEEPER_GROUPS)


def move_stock(env, source, destination, quantities, picking_type, origin, partner=False):
    """Move ``quantities`` ({product: qty in the product's unit}) from ``source`` to
    ``destination`` with one validated transfer. The stock moves even when the source
    location shows less than that: the goods have physically moved, so the books follow.

    :return: the validated stock.picking, or an empty recordset when nothing moves
    """
    Picking = env['stock.picking'].sudo()
    lines = [(product, qty) for product, qty in quantities.items()
             if not float_is_zero(qty, precision_rounding=product.uom_id.rounding)]
    if not lines:
        return Picking
    picking = Picking.create({
        'picking_type_id': picking_type.id,
        'location_id': source.id,
        'location_dest_id': destination.id,
        'origin': origin,
        'partner_id': partner and partner.id,
        'move_ids': [Command.create({
            'product_id': product.id,
            'product_uom_qty': qty,
            'product_uom': product.uom_id.id,
            'location_id': source.id,
            'location_dest_id': destination.id,
        }) for product, qty in lines],
    })
    picking.action_confirm()
    validate(picking)
    return picking


def fallback_lot(env, product, company):
    """A lot for stock that moves without one known: goods coming back from a shop, or
    more leaving a location than its lots hold. The lot that expires first is used, as
    that is the stock most likely to be there; a product with no lot yet gets one."""
    Lot = env['stock.lot'].sudo()
    domain = [('product_id', '=', product.id), '|', ('company_id', '=', False), ('company_id', '=', company.id)]
    order = 'expiration_date asc, id desc' if 'expiration_date' in Lot._fields else 'id desc'
    lot = Lot.search(domain, order=order, limit=1)
    return lot or Lot.create({'name': env._("%s-NO-LOT", product.default_code or product.id),
                              'product_id': product.id, 'company_id': company.id})


def fill_quantities(moves):
    """Set each move's done quantity to its full demand. Lot-tracked products take the
    lots reserved for them (earliest expiry first when the warehouse removes stock FEFO);
    whatever is left goes on :func:`fallback_lot`."""
    tracked = moves.filtered(lambda m: m.product_id.tracking != 'none' and m.state not in ('done', 'cancel'))
    if tracked:
        tracked._action_assign()
    for move in moves.filtered(lambda m: m.state not in ('done', 'cancel')):
        if move.product_id.tracking == 'none':
            move.quantity = move.product_uom_qty
        else:
            # Stock coming in from a shop or a loss location is reserved without a lot.
            for line in move.move_line_ids.filtered(lambda ml: not ml.lot_id and not ml.lot_name):
                line.lot_id = fallback_lot(move.env, move.product_id, move.company_id)
            missing = move.product_uom_qty - move.quantity
            if float_compare(missing, 0, precision_rounding=move.product_uom.rounding) > 0:
                lot = fallback_lot(move.env, move.product_id, move.company_id)
                line = move.move_line_ids.filtered(lambda ml: ml.lot_id == lot)[:1]
                if line:
                    line.quantity += missing
                else:
                    move.env['stock.move.line'].sudo().create({
                        'move_id': move.id,
                        'product_id': move.product_id.id,
                        'product_uom_id': move.product_uom.id,
                        'location_id': move.location_id.id,
                        'location_dest_id': move.location_dest_id.id,
                        'lot_id': lot.id,
                        'quantity': missing,
                        'company_id': move.company_id.id,
                        'picking_id': move.picking_id.id,
                    })
        move.picked = True


def validate(pickings):
    """Validate pickings for their full demand, without backorders."""
    fill_quantities(pickings.move_ids)
    pickings.with_context(skip_backorder=True, skip_sms=True, skip_expired=True).button_validate()


def location_quantities(env, location):
    """{product: on-hand quantity} for products with stock in ``location`` (and below it)."""
    groups = env['stock.quant'].sudo()._read_group(
        [('location_id', 'child_of', location.id)], ['product_id'], ['quantity:sum'])
    return {product: qty for product, qty in groups
            if not float_is_zero(qty, precision_rounding=product.uom_id.rounding)}


class BeatproVanTransfer(models.Model):
    """A morning van load or a day-end van unload.

    A load moves stock from the main warehouse into the rep's van once the storekeeper
    confirms it (or straight away for reps who load their own van). An unload moves
    what the rep counted back to the main warehouse. A difference between what should
    be in the van and what was counted is written off only after a supervisor approves it.
    """
    _name = 'beatpro.van.transfer'
    _description = 'BeatPro Van Load or Unload'
    _inherit = ['mail.thread', 'beatpro.mobile.mixin']
    _order = 'date desc, id desc'

    name = fields.Char(string="Reference", readonly=True, copy=False, default=lambda self: self.env._("New"))
    kind = fields.Selection([
        ('load', "Load"),
        ('unload', "Unload"),
    ], required=True, default='load', readonly=True, tracking=True)
    user_id = fields.Many2one(
        'res.users', string="Rep", required=True, index=True, tracking=True,
        default=lambda self: self.env.user)
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    van_id = fields.Many2one(
        'stock.warehouse', string="Van", required=True, check_company=True,
        domain="[('beatpro_is_van', '=', True)]",
        default=lambda self: self.env.user.beatpro_van_warehouse_id)
    vehicle = fields.Char(related='van_id.beatpro_vehicle')
    main_warehouse_id = fields.Many2one(
        'stock.warehouse', string="Main Warehouse", required=True, check_company=True,
        default=lambda self: self.env['stock.warehouse']._beatpro_main())
    date = fields.Date(required=True, default=fields.Date.context_today, index=True)
    state = fields.Selection([
        ('draft', "Draft"),
        ('sent', "Sent to Storekeeper"),
        ('to_approve', "Difference to Approve"),
        ('done', "Done"),
        ('cancel', "Cancelled"),
    ], default='draft', required=True, tracking=True, copy=False)
    line_ids = fields.One2many('beatpro.van.transfer.line', 'transfer_id', string="Products", copy=True)
    note = fields.Text(string="Rep's Note", help="Why the count differs from what should be in the van.")
    sent_at = fields.Datetime(string="Sent", readonly=True, copy=False)
    done_by_id = fields.Many2one('res.users', string="Confirmed By", readonly=True, copy=False)
    approved_by_id = fields.Many2one('res.users', string="Difference Approved By", readonly=True, copy=False)
    picking_id = fields.Many2one('stock.picking', string="Transfer", readonly=True, copy=False)
    writeoff_move_ids = fields.Many2many('stock.move', string="Write-off Moves", readonly=True, copy=False)

    total_qty = fields.Float(compute='_compute_totals', string="Quantity")
    total_expected = fields.Float(compute='_compute_totals', string="Expected")
    total_difference = fields.Float(compute='_compute_totals', string="Difference")
    total_value = fields.Monetary(compute='_compute_totals', string="Value", currency_field='currency_id')
    currency_id = fields.Many2one(related='company_id.currency_id')
    has_difference = fields.Boolean(compute='_compute_totals')
    can_edit_lines = fields.Boolean(compute='_compute_can_edit_lines')

    @api.depends('state')
    @api.depends_context('uid')
    def _compute_can_edit_lines(self):
        storekeeper = is_storekeeper(self.env)
        for transfer in self:
            transfer.can_edit_lines = transfer.state == 'draft' or (storekeeper and transfer.state == 'sent')

    @api.depends('line_ids.qty', 'line_ids.qty_expected', 'line_ids.product_id')
    def _compute_totals(self):
        for transfer in self:
            lines = transfer.line_ids
            transfer.total_qty = sum(lines.mapped('qty'))
            transfer.total_expected = sum(lines.mapped('qty_expected'))
            transfer.total_difference = sum(lines.mapped('qty_difference'))
            transfer.total_value = sum(line.qty * line.product_id.lst_price for line in lines)
            transfer.has_difference = transfer.kind == 'unload' and any(lines.mapped('has_difference'))

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if vals.get('name', self.env._("New")) == self.env._("New"):
                code = 'beatpro.van.unload' if vals.get('kind') == 'unload' else 'beatpro.van.load'
                vals['name'] = self.env['ir.sequence'].sudo().next_by_code(code) or self.env._("New")
        return super().create(vals_list)

    @api.depends('name', 'user_id')
    def _compute_display_name(self):
        for transfer in self:
            transfer.display_name = "%s · %s" % (transfer.name, transfer.user_id.name) if transfer.user_id else transfer.name

    # ------------------------------------------------------------------
    # Rep: build and send
    # ------------------------------------------------------------------

    @api.model
    def _beatpro_rep_van(self):
        van = self.env.user.beatpro_van_warehouse_id
        if not van:
            raise UserError(self.env._("You have no van. Ask your supervisor to set one up for you."))
        return van

    @api.model
    def beatpro_load_suggestion(self):
        """What the rep should load today: for each shop on today's route, the
        average of what it bought in its last 4 orders.

        :return: list of ``{'product_id', 'name', 'qty', 'main_qty'}``
        """
        van = self._beatpro_rep_van()
        main = self.env['stock.warehouse']._beatpro_main(van.company_id)
        partner_ids = [stop['partner_id'] for stop in self.env['beatpro.route'].beatpro_today_plan()]
        needed = defaultdict(float)
        SaleOrder = self.env['sale.order'].sudo()
        for partner_id in partner_ids:
            orders = SaleOrder.search([
                ('partner_id', 'child_of', partner_id), ('state', '=', 'sale'),
            ], order='date_order desc', limit=4)
            if not orders:
                continue
            for line in orders.order_line.filtered(lambda l: l.product_id.is_storable):
                qty = line.product_uom_id._compute_quantity(line.product_uom_qty, line.product_id.uom_id)
                needed[line.product_id] += qty / len(orders)
        main_stock = location_quantities(self.env, main.lot_stock_id)
        return [{
            'product_id': product.id,
            'name': product.display_name,
            'qty': math.ceil(qty - 1e-6),
            'main_qty': main_stock.get(product, 0.0),
        } for product, qty in sorted(needed.items(), key=lambda item: item[0].display_name) if qty > 0]

    @api.model
    def beatpro_unload_start(self):
        """What should be in the rep's van now, to count against at day end.

        :return: list of ``{'product_id', 'name', 'qty_expected'}``
        """
        van = self._beatpro_rep_van()
        stock = location_quantities(self.env, van.lot_stock_id)
        return [{
            'product_id': product.id, 'name': product.display_name, 'qty_expected': qty,
        } for product, qty in sorted(stock.items(), key=lambda item: item[0].display_name)]

    @api.model
    def action_beatpro_new(self, kind='load'):
        """Open a new load (with today's suggestion) or unload (with what should be
        in the van) in the web client."""
        if kind == 'unload':
            lines = [Command.create({'product_id': l['product_id'], 'qty_expected': l['qty_expected'],
                                     'qty': l['qty_expected']}) for l in self.beatpro_unload_start()]
        else:
            lines = [Command.create({'product_id': l['product_id'], 'qty': l['qty']})
                     for l in self.beatpro_load_suggestion()]
            self._beatpro_rep_van()
        transfer = self.create({'kind': kind, 'line_ids': lines})
        return {
            'type': 'ir.actions.act_window',
            'res_model': self._name,
            'res_id': transfer.id,
            'views': [(False, 'form')],
            'target': 'current',
        }

    def action_send(self):
        """The rep sends the load request or the counted unload. Reps who load their
        own van have their load done straight away."""
        for transfer in self:
            if transfer.state != 'draft':
                raise UserError(self.env._("%s was already sent.", transfer.name))
            if transfer.kind == 'unload':
                transfer._refresh_expected()
            if not transfer.line_ids:
                raise UserError(self.env._("Add at least one product."))
            if transfer.kind == 'load' and not any(transfer.line_ids.mapped('qty')):
                raise UserError(self.env._("Enter the quantities to load."))
            if transfer.has_difference and not (transfer.note or '').strip():
                raise UserError(self.env._(
                    "Your count differs from what should be in the van. Add a note saying why."))
            transfer.write({'state': 'sent', 'sent_at': fields.Datetime.now()})
            if transfer.kind == 'load' and transfer.user_id.beatpro_self_load and transfer.user_id == self.env.user:
                transfer._do_load()
        return True

    def _refresh_expected(self):
        """Set what should be in the van from its stock records, adding products the
        rep did not count (counted as 0)."""
        self.ensure_one()
        stock = location_quantities(self.env, self.van_id.lot_stock_id)
        for line in self.line_ids:
            line.qty_expected = stock.pop(line.product_id, 0.0)
        self.line_ids = [Command.create({'product_id': product.id, 'qty_expected': qty, 'qty': 0.0})
                         for product, qty in stock.items()]

    @api.model
    def beatpro_submit_transfers(self, vals_list):
        """Create the loads and unloads sent by the app and send them.

        :return: ``{mobile_uuid: {'id', 'name', 'state'}}``
        """
        for vals in vals_list:
            vals.setdefault('van_id', self._beatpro_rep_van().id)
        ids_by_uuid = self.beatpro_upsert(vals_list)
        transfers = self.browse(list(ids_by_uuid.values()))
        transfers.filtered(lambda t: t.state == 'draft').action_send()
        return {t.mobile_uuid: {'id': t.id, 'name': t.name, 'state': t.state} for t in transfers.sudo()}

    # ------------------------------------------------------------------
    # Storekeeper and supervisor
    # ------------------------------------------------------------------

    def _check_storekeeper(self):
        if not is_storekeeper(self.env):
            raise AccessError(self.env._("Only a storekeeper or a BeatPro supervisor can do this."))

    def action_load(self):
        """The storekeeper has loaded the van: move the stock into it."""
        self._check_storekeeper()
        for transfer in self:
            if transfer.kind != 'load' or transfer.state != 'sent':
                raise UserError(self.env._("%s is not a load request waiting for the storekeeper.", transfer.name))
            transfer._do_load()
        return True

    def _do_load(self):
        self.ensure_one()
        quantities = defaultdict(float)
        for line in self.line_ids:
            quantities[line.product_id] += line.qty
        picking = move_stock(
            self.env, self.main_warehouse_id.lot_stock_id, self.van_id.lot_stock_id, quantities,
            self.main_warehouse_id.with_context(active_test=False).int_type_id, self.name)
        self.sudo().write({'state': 'done', 'picking_id': picking.id, 'done_by_id': self.env.user.id})

    def action_receive(self):
        """The storekeeper has received the van: move what was counted back to the
        main warehouse. A difference waits for a supervisor."""
        self._check_storekeeper()
        for transfer in self:
            if transfer.kind != 'unload' or transfer.state != 'sent':
                raise UserError(self.env._("%s is not an unload waiting to be received.", transfer.name))
            quantities = defaultdict(float)
            for line in transfer.line_ids:
                quantities[line.product_id] += line.qty
            picking = move_stock(
                self.env, transfer.van_id.lot_stock_id, transfer.main_warehouse_id.lot_stock_id, quantities,
                transfer.main_warehouse_id.with_context(active_test=False).int_type_id, transfer.name)
            transfer.sudo().write({
                'picking_id': picking.id,
                'done_by_id': self.env.user.id,
                'state': 'to_approve' if transfer.has_difference else 'done',
            })
            if transfer.has_difference:
                transfer.message_post(body=self.env._(
                    "Received with a difference of %s. Waiting for a supervisor to approve the write-off.",
                    transfer.total_difference))
        return True

    def action_approve_difference(self):
        """The supervisor accepts the difference: write it off so the van is empty."""
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Only a BeatPro supervisor can approve a stock difference."))
        for transfer in self:
            if transfer.state != 'to_approve':
                raise UserError(self.env._("%s has no difference waiting for approval.", transfer.name))
            moves = self.env['stock.move'].sudo()
            van_stock = transfer.van_id.lot_stock_id
            for line in transfer.line_ids.filtered('has_difference'):
                product = line.product_id
                loss = product.with_company(transfer.company_id).property_stock_inventory
                short = -line.qty_difference
                source, destination = (van_stock, loss) if short > 0 else (loss, van_stock)
                move = moves.create({
                    'product_id': product.id,
                    'product_uom_qty': abs(short),
                    'product_uom': product.uom_id.id,
                    'location_id': source.id,
                    'location_dest_id': destination.id,
                    'company_id': transfer.company_id.id,
                    'is_inventory': True,
                    'origin': transfer.name,
                })
                move._action_confirm()
                fill_quantities(move)
                move._action_done()
                moves |= move
            transfer.sudo().write({
                'state': 'done', 'approved_by_id': self.env.user.id,
                'writeoff_move_ids': [Command.set(moves.ids)],
            })
            transfer.message_post(body=self.env._("Difference approved and written off by %s.", self.env.user.name))
        return True

    def action_cancel(self):
        for transfer in self:
            if transfer.state in ('done', 'to_approve'):
                raise UserError(self.env._("%s has already moved stock and cannot be cancelled.", transfer.name))
        self.write({'state': 'cancel'})
        return True

    def action_reset_draft(self):
        self.filtered(lambda t: t.state in ('sent', 'cancel')).write({'state': 'draft'})
        return True

    # ------------------------------------------------------------------
    # Screens
    # ------------------------------------------------------------------

    @api.model
    def _beatpro_van_day(self, van, day=None):
        """Today's figures for one van, per product: loaded from the warehouse,
        delivered to shops, taken back from shops, and in the van now."""
        tz = self.env.user.tz or 'UTC'
        day = day or fields.Date.context_today(self)
        start, end = day_bounds_utc(day, tz)
        van_stock = van.lot_stock_id
        rows = defaultdict(lambda: {'loaded': 0.0, 'sold': 0.0, 'returned': 0.0, 'left': 0.0})
        moves = self.env['stock.move'].sudo().search([
            ('state', '=', 'done'), ('date', '>=', start), ('date', '<', end),
            '|', ('location_id', 'child_of', van_stock.id), ('location_dest_id', 'child_of', van_stock.id),
        ])
        for move in moves:
            into_van = move.location_dest_id.parent_path.startswith(van_stock.parent_path)
            out_of_van = move.location_id.parent_path.startswith(van_stock.parent_path)
            if into_van == out_of_van:
                continue
            qty = move.product_uom._compute_quantity(move.quantity, move.product_id.uom_id)
            other = move.location_id if into_van else move.location_dest_id
            if into_van and other.usage == 'internal':
                rows[move.product_id]['loaded'] += qty
            elif into_van and other.usage == 'customer':
                rows[move.product_id]['returned'] += qty
            elif out_of_van and other.usage == 'customer':
                rows[move.product_id]['sold'] += qty
        for product, qty in location_quantities(self.env, van_stock).items():
            rows[product]['left'] = qty
        return rows

    @api.model
    def beatpro_van_stock(self):
        """The rep's stock screen: what is in their van and in the main warehouse."""
        van = self.env.user.beatpro_van_warehouse_id
        company = van.company_id or self.env.company
        main = self.env['stock.warehouse']._beatpro_main(company)
        main_stock = location_quantities(self.env, main.lot_stock_id)
        rows = self._beatpro_van_day(van) if van else {}
        products = sorted(set(rows) | set(main_stock), key=lambda p: p.display_name)
        items = []
        for product in products:
            row = rows.get(product, {'loaded': 0.0, 'sold': 0.0, 'returned': 0.0, 'left': 0.0})
            if not van or not any(row.values()):
                status = False
            elif row['left'] <= 0:
                status = 'out'
            elif row['loaded'] and row['left'] <= 0.25 * row['loaded']:
                status = 'low'
            else:
                status = 'ok'
            items.append({
                'product_id': product.id,
                'name': product.display_name,
                'loaded': row['loaded'], 'sold': row['sold'], 'returned': row['returned'], 'left': row['left'],
                'main_qty': main_stock.get(product, 0.0),
                'left_text': product._beatpro_pack_text(row['left']),
                'main_text': product._beatpro_pack_text(main_stock.get(product, 0.0)),
                'price': product.lst_price,
                'status': status,
            })
        van_items = [item for item in items if item['status']]
        in_van = sum(item['left'] for item in van_items)
        transfers = self.search([('user_id', '=', self.env.user.id), ('date', '=', fields.Date.context_today(self))])
        open_load = transfers.filtered(lambda t: t.kind == 'load' and t.state in ('draft', 'sent'))[:1]
        unload = transfers.filtered(lambda t: t.kind == 'unload' and t.state != 'cancel')[:1]
        return {
            'has_van': bool(van),
            'van_name': van.name or False,
            'vehicle': van.beatpro_vehicle or False,
            'main_name': self.env._("Main warehouse"),
            'self_load': self.env.user.beatpro_self_load,
            'in_van': in_van,
            'in_van_value': money(self.env, sum(item['left'] * item['price'] for item in van_items)),
            'loaded': sum(item['loaded'] for item in van_items),
            'sold': sum(item['sold'] for item in van_items),
            'returned': sum(item['returned'] for item in van_items),
            'van_items': van_items,
            'main_items': [item for item in items if item['main_qty'] > 0],
            'open_load': open_load and {'id': open_load.id, 'name': open_load.name, 'state': open_load.state} or False,
            'unload': unload and {'id': unload.id, 'name': unload.name, 'state': unload.state} or False,
        }

    @api.model
    def beatpro_desk_data(self):
        """The storekeeper's Vans page."""
        if not is_storekeeper(self.env):
            raise AccessError(self.env._("The Vans page is for storekeepers and BeatPro supervisors."))
        company = self.env.company
        main = self.env['stock.warehouse']._beatpro_main(company)
        open_transfers = self.sudo().search([
            ('company_id', '=', company.id), ('state', 'in', ('sent', 'to_approve')),
        ], order='sent_at, id')

        def card(transfer):
            lines = transfer.line_ids
            short = lines.filtered('has_difference')
            return {
                'id': transfer.id,
                'name': transfer.name,
                'rep': transfer.user_id.name,
                'initials': initials(transfer.user_id.name),
                'van': transfer.van_id.beatpro_vehicle or transfer.van_id.name,
                'qty': transfer.total_qty,
                'expected': transfer.total_expected,
                'products': len(lines),
                'value': money(self.env, transfer.total_value),
                'sent': fields.Datetime.context_timestamp(self, transfer.sent_at).strftime('%I:%M %p').lstrip('0')
                if transfer.sent_at else '',
                'note': transfer.note or '',
                'differences': [{
                    'product': line.product_id.display_name,
                    'difference': line.qty_difference,
                } for line in short],
                'damaged': transfer._beatpro_damaged_today() if transfer.kind == 'unload' else 0,
            }

        loads = open_transfers.filtered(lambda t: t.kind == 'load' and t.state == 'sent')
        unloads = open_transfers.filtered(lambda t: t.kind == 'unload' and t.state == 'sent')
        to_approve = open_transfers.filtered(lambda t: t.state == 'to_approve')
        unloading = open_transfers.filtered(lambda t: t.kind == 'unload').van_id
        vans = []
        for van in self.env['stock.warehouse'].sudo().search([
            ('company_id', '=', company.id), ('beatpro_is_van', '=', True),
        ]):
            rows = self._beatpro_van_day(van)
            left = sum(row['left'] for row in rows.values())
            if van in unloading or float_is_zero(left, precision_digits=2):
                continue
            vans.append({
                'id': van.id,
                'rep': ', '.join(van.beatpro_rep_ids.mapped('name')) or van.name,
                'van': van.beatpro_vehicle or van.name,
                'loaded': sum(row['loaded'] for row in rows.values()),
                'sold': sum(row['sold'] for row in rows.values()),
                'left': left,
                'value': money(self.env, sum(row['left'] * product.lst_price for product, row in rows.items())),
            })
        return {
            'warehouse': main.name,
            'date_label': fields.Date.context_today(self).strftime('%a, %-d %b'),
            'is_supervisor': self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'),
            'loads': [card(t) for t in loads],
            'unloads': [card(t) for t in unloads],
            'to_approve': [card(t) for t in to_approve],
            'vans': vans,
            'difference_qty': sum(abs(t.total_difference) for t in unloads | to_approve),
        }

    def _beatpro_damaged_today(self):
        """How many damaged items the rep took back from shops today."""
        self.ensure_one()
        lines = self.env['beatpro.shop.return.line'].sudo().search([
            ('return_id.user_id', '=', self.user_id.id), ('return_id.date', '=', self.date),
            ('return_id.state', '=', 'done'), ('resellable', '=', False),
        ])
        return sum(lines.mapped('qty'))


class BeatproVanTransferLine(models.Model):
    _name = 'beatpro.van.transfer.line'
    _description = 'BeatPro Van Load or Unload Line'
    _order = 'transfer_id, id'

    transfer_id = fields.Many2one('beatpro.van.transfer', required=True, ondelete='cascade', index=True)
    kind = fields.Selection(related='transfer_id.kind')
    product_id = fields.Many2one(
        'product.product', string="Product", required=True,
        domain="[('is_storable', '=', True)]")
    uom_id = fields.Many2one(related='product_id.uom_id', string="Unit")
    qty = fields.Float(string="Quantity", digits='Product Unit',
                       help="For a load, how much to put in the van. For an unload, how much the rep counted.")
    qty_expected = fields.Float(string="Expected", digits='Product Unit', readonly=True,
                                help="What should be in the van, from its stock records.")
    qty_difference = fields.Float(string="Difference", compute='_compute_difference', digits='Product Unit')
    qty_text = fields.Char(string="In Cases", compute='_compute_qty_text')
    has_difference = fields.Boolean(compute='_compute_difference')

    @api.depends('qty', 'product_id')
    def _compute_qty_text(self):
        for line in self:
            line.qty_text = line.product_id and line.product_id._beatpro_pack_text(line.qty) or False

    @api.depends('qty', 'qty_expected', 'kind')
    def _compute_difference(self):
        for line in self:
            if line.kind != 'unload':
                line.qty_difference = 0.0
                line.has_difference = False
                continue
            line.qty_difference = line.qty - line.qty_expected
            line.has_difference = float_compare(
                line.qty, line.qty_expected, precision_rounding=line.product_id.uom_id.rounding or 0.01) != 0

    def _check_editable(self):
        """Reps change their lines only before sending; the storekeeper can recount."""
        if is_storekeeper(self.env):
            return
        if any(line.transfer_id.state != 'draft' for line in self):
            raise UserError(self.env._("This was already sent. Ask the storekeeper to change it."))

    @api.model_create_multi
    def create(self, vals_list):
        lines = super().create(vals_list)
        lines._check_editable()
        return lines

    def write(self, vals):
        self._check_editable()
        return super().write(vals)

    def unlink(self):
        self._check_editable()
        return super().unlink()
