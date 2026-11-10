"""Inventory for supervisors: van stock, warehouse stock against the next 7 days,
expiring lots, returns, load requests waiting and stock lost by rep."""

import math
from collections import defaultdict
from datetime import datetime, time, timedelta

from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError
from odoo.fields import Command
from odoo.tools import float_is_zero

from .beatpro_shop_return import RETURN_REASONS
from .beatpro_tools import day_bounds_utc
from .beatpro_van_transfer import location_quantities


class ResCompany(models.Model):
    _inherit = 'res.company'

    beatpro_expiry_days = fields.Integer(
        string="Expiring Within (days)", default=30,
        help="Lots expiring within this many days show under Expiring on the Inventory dashboard.")
    beatpro_not_moving_days = fields.Integer(
        string="Not Moving After (days)", default=3,
        help="Stock in a van that hasn't sold for this many days shows as not moving.")
    beatpro_alert_unload_diff = fields.Monetary(
        string="Alert on Unload Difference Above", default=100.0, currency_field='currency_id',
        help="An unload counted short or over by more than this value raises an alert.")
    beatpro_alert_load_wait = fields.Integer(
        string="Alert When a Load Waits (minutes)", default=30,
        help="A load request the storekeeper hasn't confirmed after this many minutes raises an alert.")
    beatpro_fefo = fields.Boolean(
        string="Load Vans Earliest Expiry First", default=True,
        help="Vans are loaded from the lots that expire first (FEFO). Applies to products "
             "tracked by lots with expiry dates.")


class StockWarehouse(models.Model):
    _inherit = 'stock.warehouse'

    @api.model
    def _beatpro_apply_fefo(self):
        """Make the main warehouses of companies loading vans FEFO remove the lot that
        expires first. A removal strategy already chosen in Inventory is kept."""
        fefo = self.env.ref('product_expiry.removal_fefo', raise_if_not_found=False)
        if not fefo:
            return
        warehouses = self.sudo().search([('beatpro_is_van', '=', False)])
        for warehouse in warehouses.filtered(lambda w: w.company_id.beatpro_fefo):
            location = warehouse.lot_stock_id
            if not location.removal_strategy_id:
                location.removal_strategy_id = fefo


def weekday_average_need(env, company, products_domain=None, today=None, weeks=4):
    """{product: quantity expected to sell in the next 7 days}: for each of the next 7
    days, the average of that weekday over the last ``weeks`` weeks."""
    today = today or fields.Date.context_today(env['res.users'])
    start = datetime.combine(today - timedelta(days=7 * weeks), time.min)
    end = datetime.combine(today, time.min)
    domain = [
        ('state', '=', 'done'), ('company_id', '=', company.id),
        ('location_dest_id.usage', '=', 'customer'), ('location_id.usage', '=', 'internal'),
        ('date', '>=', start), ('date', '<', end),
    ] + (products_domain or [])
    by_weekday = defaultdict(lambda: defaultdict(float))
    for move in env['stock.move'].sudo().search(domain):
        qty = move.product_uom._compute_quantity(move.quantity, move.product_id.uom_id)
        by_weekday[move.product_id][move.date.weekday()] += qty
    # Every weekday appears once in the next 7 days, so the week's need is the sum of
    # the weekday averages.
    return {product: math.ceil(sum(days.values()) / weeks - 1e-9) for product, days in by_weekday.items()}


class BeatproInventory(models.AbstractModel):
    _name = 'beatpro.inventory'
    _description = "BeatPro Inventory for Supervisors"

    def _money(self, amount):
        """``AED 48,600``: whole amounts, as supervisors read stock values."""
        return '%s %s' % (self.env.company.currency_id.name, '{:,.0f}'.format(round(amount or 0.0)))

    def _check_supervisor(self):
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("The Inventory dashboard is for BeatPro supervisors."))

    @staticmethod
    def _cases(qty, product):
        return product._beatpro_pack_text(qty)

    # ------------------------------------------------------------------
    # Building blocks
    # ------------------------------------------------------------------

    def _vans(self):
        return self.env['stock.warehouse'].sudo().search([
            ('company_id', '=', self.env.company.id), ('beatpro_is_van', '=', True)])

    def _last_sold(self, van):
        """{product: date of the last delivery to a shop from this van}."""
        groups = self.env['stock.move'].sudo()._read_group([
            ('state', '=', 'done'), ('location_id', 'child_of', van.lot_stock_id.id),
            ('location_dest_id.usage', '=', 'customer'),
        ], ['product_id'], ['date:max'])
        return {product: last for product, last in groups}

    def _expiring(self, days):
        """Quants of lots expiring within ``days`` in the company's own stock."""
        Quant = self.env['stock.quant'].sudo()
        if 'expiration_date' not in self.env['stock.lot']._fields:
            return Quant
        limit = fields.Datetime.now() + timedelta(days=days)
        return Quant.search([
            ('company_id', '=', self.env.company.id), ('location_id.usage', '=', 'internal'),
            ('lot_id.expiration_date', '!=', False), ('lot_id.expiration_date', '<=', limit),
            ('quantity', '>', 0),
        ], order='id')

    def _short_lines(self, start, end):
        """Order lines taken by reps with a van today that went to the warehouse instead:
        the van didn't have enough."""
        lines = self.env['sale.order.line'].sudo().search([
            ('order_id.state', '=', 'sale'), ('order_id.company_id', '=', self.env.company.id),
            ('order_id.date_order', '>=', start), ('order_id.date_order', '<', end),
            ('order_id.user_id.beatpro_van_warehouse_id', '!=', False),
            ('order_id.beatpro_delivery_mode', 'in', ('split', 'warehouse')),
            ('display_type', '=', False), ('product_id.is_storable', '=', True),
        ])
        return lines.filtered(lambda l: l.warehouse_id != l.order_id.user_id.beatpro_van_warehouse_id)

    def _unloads(self, since):
        return self.env['beatpro.van.transfer'].sudo().search([
            ('company_id', '=', self.env.company.id), ('kind', '=', 'unload'),
            ('state', 'in', ('to_approve', 'done')), ('date', '>=', since),
        ])

    @staticmethod
    def _difference_value(transfer):
        """Value of what an unload counted short (positive) or over (negative)."""
        return sum(-line.qty_difference * line.product_id.lst_price for line in transfer.line_ids)

    @staticmethod
    def _who(van, user):
        """``Van 2 · Anil Sawant``, without the rep twice when the van is named after them."""
        if not user or user.name in (van.name or ''):
            return van.name
        return '%s · %s' % (van.name, user.name)

    def _van_rows(self, van, today):
        """Per product in a van: today's figures and its status for the supervisor."""
        company = self.env.company
        Transfer = self.env['beatpro.van.transfer']
        rows = Transfer._beatpro_van_day(van, today)
        last_sold = self._last_sold(van)
        expiring = defaultdict(lambda: None)
        for quant in self._expiring(company.beatpro_expiry_days).filtered(
                lambda q: q.location_id.parent_path.startswith(van.lot_stock_id.parent_path)):
            day = quant.lot_id.expiration_date.date()
            if expiring[quant.product_id] is None or day < expiring[quant.product_id]:
                expiring[quant.product_id] = day
        not_moving_since = fields.Datetime.now() - timedelta(days=company.beatpro_not_moving_days)
        result = []
        for product, row in rows.items():
            if not any(row.values()):
                continue
            moved = row['sold'] + row['left']
            sold_pct = round(100 * row['sold'] / moved) if moved else 0
            last = last_sold.get(product)
            expires = expiring[product]
            if row['left'] <= 0 and (row['loaded'] > 0 or row['sold'] > 0):
                status = 'out'
            elif expires:
                status = 'expiring'
            elif row['left'] > 0 and (not last or last < not_moving_since):
                status = 'not_moving'
            elif row['loaded'] and row['left'] <= 0.25 * row['loaded']:
                status = 'low'
            else:
                status = 'selling'
            result.append({
                'product': product, 'loaded': row['loaded'], 'sold': row['sold'], 'left': row['left'],
                'returned': row['returned'], 'sold_pct': sold_pct, 'last_sold': last,
                'expires': expires, 'status': status, 'value': row['left'] * product.lst_price,
            })
        return result

    def _last_sold_label(self, when, today):
        if not when:
            return self.env._("Not yet")
        day = fields.Date.context_today(self, when)
        days = (today - day).days
        if days <= 0:
            return self.env._("Today")
        if days == 1:
            return self.env._("Yesterday")
        return self.env._("%s days ago", days)

    # ------------------------------------------------------------------
    # The dashboard
    # ------------------------------------------------------------------

    @api.model
    def beatpro_inventory_dashboard(self):
        """Everything the Inventory dashboard shows, today, for the current company."""
        self._check_supervisor()
        company = self.env.company
        today = fields.Date.context_today(self)
        start, end = day_bounds_utc(today, self.env.user.tz)
        now = fields.Datetime.now()
        _ = self.env._

        # Vans.
        short_lines = self._short_lines(start, end)
        vans, total_value, total_left, carried_value = [], 0.0, 0.0, 0.0
        weekday = str(today.weekday())
        for van in self._vans():
            rep = van.beatpro_rep_ids[:1]
            rows = self._van_rows(van, today)
            loaded = sum(r['loaded'] for r in rows)
            sold = sum(r['sold'] for r in rows)
            left = sum(r['left'] for r in rows)
            value = sum(r['value'] for r in rows)
            carried_value += sum(max(r['left'] - r['loaded'], 0) * r['product'].lst_price for r in rows)
            total_value += value
            total_left += left
            routes = self.env['beatpro.route'].sudo().search([
                ('user_id', '=', rep.id), '|', ('weekday', '=', weekday), ('weekday', '=', False)]) if rep else []
            planned = len(routes.line_ids) if rep else 0
            visited = self.env['beatpro.visit'].sudo().search_count([
                ('user_id', '=', rep.id), ('check_in', '>=', start), ('check_in', '<', end)]) if rep else 0
            van_short = short_lines.filtered(lambda l: l.order_id.user_id == rep) if rep else short_lines.browse()
            out = [r for r in rows if r['status'] == 'out']
            not_moving = [r for r in rows if r['status'] == 'not_moving']
            sold_pct = round(100 * sold / (sold + left)) if sold + left else 0
            if out and van_short:
                waiting_shops = len(van_short.order_id.partner_id)
                state, note = 'red', (_("%s out · 1 shop waiting", out[0]['product'].name) if waiting_shops == 1 else
                                      _("%(product)s out · %(n)s shops waiting", product=out[0]['product'].name, n=waiting_shops))
            elif out:
                state, note = 'amber', _("%s out", out[0]['product'].name)
            elif len(not_moving) >= 5:
                state, note = 'amber', _("%(n)s products not moving %(d)s+ days",
                                         n=len(not_moving), d=company.beatpro_not_moving_days)
            elif rows and left <= 0.15 * max(loaded, 1):
                state, note = 'green', _("Almost empty")
            else:
                state, note = 'green', _("On track")
            vans.append({
                'id': van.id, 'name': van.name, 'vehicle': van.beatpro_vehicle or '',
                # Vans are often named after their rep already: "Van 1 · Ravi Kumar".
                'rep': '' if rep.name and rep.name in van.name else (rep.name or _("No rep")),
                'route': " · ".join(filter(None, [", ".join(routes.mapped('name')) if rep else '',
                                                  _("%(v)s of %(p)s shops visited", v=visited, p=planned) if planned else ''])),
                'sold_pct': sold_pct, 'left': self._money(value),
                'left_cases': sum(r['left'] for r in rows),
                'left_text': _("%(cases)s · %(value)s", cases=self._pack_total(rows, 'left'), value=self._money(value)),
                'state': state, 'note': note,
            })
        vans.sort(key=lambda v: ({'red': 0, 'amber': 1, 'green': 2}[v['state']], v['name']))

        # Warehouse: stock against the next 7 days.
        main = self.env['stock.warehouse']._beatpro_main(company)
        main_stock = location_quantities(self.env, main.lot_stock_id)
        need = weekday_average_need(self.env, company, today=today)
        requested_today = self.env['beatpro.van.transfer.line'].sudo().search([
            ('transfer_id.company_id', '=', company.id), ('transfer_id.kind', '=', 'load'),
            ('transfer_id.date', '=', today), ('transfer_id.state', '!=', 'cancel'),
        ])
        low = []
        for product in set(need) | set(requested_today.product_id):
            week = need.get(product, 0.0)
            have = main_stock.get(product, 0.0)
            if week <= 0 and have > 0:
                continue
            days = have / (week / 7) if week > 0 else 0
            if days >= 14:
                continue
            low.append({
                'product_id': product.id, 'name': product.display_name,
                'have': self._cases(have, product), 'need': self._cases(week, product),
                'days': round(days, 1), 'out': have <= 0,
                'label': _("Out") if have <= 0 else (_("1 day") if days < 1.5 else _("%s days", int(round(days)))),
                'state': 'red' if days < 2 else ('amber' if days < 7 else 'green'),
                'vendor': bool(product.seller_ids),
            })
        low.sort(key=lambda r: r['days'])

        # Alerts.
        alerts = []
        asked = defaultdict(set)
        for line in requested_today:
            asked[line.product_id].add(line.transfer_id.van_id)
        for row in [r for r in low if r['out']]:
            product = self.env['product.product'].browse(row['product_id'])
            if asked.get(product):
                alerts.append({'kind': 'red', 'title': _("Out in the warehouse"), 'product_id': product.id,
                               'text': _("%(product)s · %(n)s vans asked for it today",
                                         product=product.display_name, n=len(asked[product])),
                               'action': 'purchase'})
        # The same product short in the same van three days running.
        for van in self._vans():
            rep = van.beatpro_rep_ids[:1]
            if not rep:
                continue
            streak = None
            for back in range(3):
                d_start, d_end = day_bounds_utc(today - timedelta(days=back), self.env.user.tz)
                products = set(self._short_lines(d_start, d_end).filtered(
                    lambda l: l.order_id.user_id == rep).product_id)
                streak = products if streak is None else streak & products
            for product in streak or ():
                alerts.append({'kind': 'red', 'title': _("Van short 3 days running"), 'van_id': van.id,
                               'text': _("%(van)s · %(product)s", van=self._who(van, rep), product=product.display_name),
                               'action': 'van'})
        for transfer in self._unloads(today - timedelta(days=1)):
            diff = self._difference_value(transfer)
            if abs(diff) > company.beatpro_alert_unload_diff:
                alerts.append({'kind': 'amber', 'title': _("Unload difference"), 'res_id': transfer.id,
                               'text': _("%(van)s counted %(value)s %(how)s", van=transfer.van_id.name,
                                         value=self._money(abs(diff)), how=_("short") if diff > 0 else _("over")),
                               'action': 'transfer'})
        waiting = []
        for transfer in self.env['beatpro.van.transfer'].sudo().search([
                ('company_id', '=', company.id), ('kind', '=', 'load'), ('state', '=', 'sent')], order='sent_at'):
            minutes = int((now - transfer.sent_at).total_seconds() // 60) if transfer.sent_at else 0
            waiting.append({
                'id': transfer.id, 'van': self._who(transfer.van_id, transfer.user_id),
                'items': _("%(n)s products · %(cases)s", n=len(transfer.line_ids),
                           cases=self._pack_lines(transfer.line_ids)),
                'minutes': minutes, 'state': 'red' if minutes >= company.beatpro_alert_load_wait else 'amber',
            })
            if minutes >= company.beatpro_alert_load_wait:
                alerts.append({'kind': 'grey', 'title': _("Load request waiting %s+ min", minutes),
                               'text': _("%s is waiting for the storekeeper", self._who(transfer.van_id, transfer.user_id)),
                               'action': 'desk'})

        # Expiry.
        expiring = self._expiring(company.beatpro_expiry_days)
        in_vans = expiring.filtered(lambda q: q.location_id.warehouse_id.beatpro_is_van)
        soon = fields.Datetime.now() + timedelta(days=7)
        expiry_rows = []
        for quant in expiring.sorted(lambda q: q.lot_id.expiration_date):
            days = (quant.lot_id.expiration_date.date() - today).days
            expiry_rows.append({
                'product': quant.product_id.display_name, 'lot': quant.lot_id.name,
                'where': quant.location_id.warehouse_id.name or quant.location_id.display_name,
                'qty': self._cases(quant.quantity, quant.product_id),
                'value': self._money(quant.quantity * quant.product_id.lst_price),
                'days': days,
                'label': _("Expired") if days < 0 else (_("Today") if days == 0 else _("%s days", days)),
                'state': 'red' if days <= 7 else 'amber',
            })
            if quant.lot_id.expiration_date <= soon:
                alerts.append({'kind': 'amber', 'title': _("Expires in 7 days") if days >= 0 else _("Expired"),
                               'text': _("%(product)s · lot %(lot)s · %(qty)s in %(where)s",
                                         product=quant.product_id.display_name, lot=quant.lot_id.name,
                                         qty=self._cases(quant.quantity, quant.product_id),
                                         where=expiry_rows[-1]['where']),
                               'action': 'expiry'})

        # Returns and damage, this month against last month.
        month_start = today.replace(day=1)
        prev_start = (month_start - timedelta(days=1)).replace(day=1)
        ReturnLine = self.env['beatpro.shop.return.line'].sudo()
        base = [('return_id.company_id', '=', company.id), ('return_id.state', '!=', 'cancel')]
        lines = ReturnLine.search(base + [('return_id.date', '>=', month_start), ('return_id.date', '<=', today)])
        prev = ReturnLine.search(base + [('return_id.date', '>=', prev_start), ('return_id.date', '<', month_start)])
        by_reason = defaultdict(float)
        for line in lines:
            by_reason[line.reason] += line.subtotal
        total, prev_total = sum(lines.mapped('subtotal')), sum(prev.mapped('subtotal'))
        top = max(by_reason.values(), default=0) or 1
        reasons = dict(RETURN_REASONS)

        def most(key):
            values = defaultdict(float)
            for line in lines:
                values[key(line)] += line.subtotal
            return max(values, key=values.get).display_name if values else ''

        # Stock lost by rep: unloads counted short this month.
        lost = defaultdict(float)
        for transfer in self._unloads(month_start):
            lost[transfer.user_id] += max(self._difference_value(transfer), 0.0)
        for rep in self._vans().beatpro_rep_ids:
            lost.setdefault(rep, 0.0)
        top_lost = max(lost.values(), default=0) or 1

        short_value = sum(short_lines.mapped('price_subtotal'))
        short_products = []
        for product in short_lines.product_id:
            short_products.append(product.name)
        unload_diffs = [t for t in self._unloads(today - timedelta(days=1)) if abs(self._difference_value(t)) > 0]
        return {
            'date_label': today.strftime('%A %-d %B'),
            'currency': company.currency_id.name,
            'van_count': len(vans),
            'kpis': {
                'van_stock': self._money(total_value),
                'van_stock_note': _("%(cases)s in %(n)s vans · %(carried)s unsold since yesterday",
                                    cases=self._pack_total_all(), n=len(vans), carried=self._money(carried_value)),
                'short': self._money(short_value),
                'short_note': _("%(n)s orders went to the warehouse", n=len(short_lines.order_id))
                + (" · " + ", ".join(short_products[:3]) if short_products else ''),
                'expiring': self._money(sum(q.quantity * q.product_id.lst_price for q in expiring)),
                'expiring_note': _("%(lots)s lots · %(vans)s in vans", lots=len(expiring.lot_id), vans=len(in_vans.lot_id)),
                'unload_diff': self._money(sum(abs(self._difference_value(t)) for t in unload_diffs)),
                'unload_diff_note': _("Vans counted a difference last night: %s", len(unload_diffs)),
            },
            'alerts': alerts,
            'vans': vans,
            'low': low[:12],
            'has_purchase': 'purchase.order' in self.env,
            'can_purchase': 'purchase.order' in self.env and any(r['vendor'] for r in low),
            'expiry': expiry_rows[:20],
            'expiry_days': company.beatpro_expiry_days,
            'returns': {
                'total': self._money(total),
                'trend': round(100 * (total - prev_total) / prev_total) if prev_total else None,
                'reasons': [{'label': reasons.get(r, r), 'value': self._money(v), 'pct': round(100 * v / top)}
                            for r, v in sorted(by_reason.items(), key=lambda kv: -kv[1])],
                'top_product': most(lambda l: l.product_id),
                'top_shop': most(lambda l: l.return_id.partner_id),
                'top_rep': most(lambda l: l.return_id.user_id),
            },
            'waiting': waiting,
            'lost': [{'rep': rep.name, 'value': self._money(v), 'pct': round(100 * v / top_lost)}
                     for rep, v in sorted(lost.items(), key=lambda kv: -kv[1])],
        }

    @staticmethod
    def _per_case(product):
        cases = product.uom_ids.filtered(
            lambda u: u._has_common_reference(product.uom_id) and u.factor > product.uom_id.factor)
        return max(cases.mapped('factor')) / product.uom_id.factor if cases else 0.0

    def _total_text(self, pairs):
        """``96 cs`` (plus pieces of products sold without cases) for (product, qty) pairs."""
        cases = pieces = 0.0
        for product, qty in pairs:
            per_case = self._per_case(product)
            if per_case:
                cases += qty / per_case
            else:
                pieces += qty
        parts = []
        if cases >= 0.5 or not pieces:
            parts.append('%d cs' % round(cases))
        if pieces:
            parts.append('%d pc' % round(pieces))
        return ' + '.join(parts)

    def _pack_total(self, rows, key):
        return self._total_text([(row['product'], row[key]) for row in rows])

    def _pack_lines(self, lines):
        return self._total_text([(line.product_id, line.qty) for line in lines])

    def _pack_total_all(self):
        pairs = []
        for van in self._vans():
            pairs += list(location_quantities(self.env, van.lot_stock_id).items())
        return self._total_text(pairs)

    # ------------------------------------------------------------------
    # One van
    # ------------------------------------------------------------------

    @api.model
    def beatpro_inventory_van(self, van_id):
        """One van's products, today's figures and its last 7 unloads."""
        self._check_supervisor()
        van = self.env['stock.warehouse'].sudo().browse(van_id).exists()
        if not van or not van.beatpro_is_van or van.company_id != self.env.company:
            raise UserError(self.env._("This van doesn't exist in %s.", self.env.company.name))
        today = fields.Date.context_today(self)
        start, end = day_bounds_utc(today, self.env.user.tz)
        _ = self.env._
        rep = van.beatpro_rep_ids[:1]
        rows = self._van_rows(van, today)
        short = self._short_lines(start, end).filtered(lambda l: l.order_id.user_id == rep) if rep else []
        short_by_product = defaultdict(set)
        for line in short:
            short_by_product[line.product_id].add(line.order_id.partner_id)
        order = {'out': 0, 'expiring': 1, 'low': 2, 'not_moving': 3, 'selling': 4}
        products = []
        for row in sorted(rows, key=lambda r: (order[r['status']], r['product'].display_name)):
            product = row['product']
            if row['status'] == 'out':
                shops = len(short_by_product.get(product, ()))
                label = (_("Out · 1 shop wants it") if shops == 1 else _("Out · %s shops want it", shops)) if shops else _("Out")
            elif row['status'] == 'expiring':
                label = _("Expires in %s days", (row['expires'] - today).days)
            else:
                label = {'low': _("Low"), 'not_moving': _("Not moving"), 'selling': _("Selling")}[row['status']]
            products.append({
                'name': product.display_name,
                'loaded': self._cases(row['loaded'], product), 'left': self._cases(row['left'], product),
                'sold_pct': row['sold_pct'], 'last_sold': self._last_sold_label(row['last_sold'], today),
                'status': row['status'], 'label': label,
            })
        unloads = []
        for back in range(6, -1, -1):
            day = today - timedelta(days=back)
            transfers = self.env['beatpro.van.transfer'].sudo().search([
                ('van_id', '=', van.id), ('kind', '=', 'unload'), ('date', '=', day),
                ('state', 'in', ('to_approve', 'done'))])
            value = sum(self._difference_value(t) for t in transfers)
            unloads.append({'day': day.strftime('%a'), 'value': value, 'label': self._money(value),
                            'state': 'green' if abs(value) < 1 else ('red' if value > 0 else 'amber')})
        month_start = today.replace(day=1)
        month_short = [t for t in self._unloads(month_start) if t.van_id == van and self._difference_value(t) > 0]
        loaded_at = self.env['beatpro.van.transfer'].sudo().search([
            ('van_id', '=', van.id), ('kind', '=', 'load'), ('date', '=', today), ('state', '=', 'done')],
            order='write_date', limit=1)
        return {
            'id': van.id, 'name': van.name, 'vehicle': van.beatpro_vehicle or '',
            'rep': '' if rep.name and rep.name in van.name else (rep.name or _("No rep")),
            'loaded_at': loaded_at and fields.Datetime.context_timestamp(self, loaded_at.write_date).strftime('%I:%M %p').lstrip('0') or '',
            'value_left': self._money(sum(r['value'] for r in rows)),
            'today': {
                'loaded': sum(r['loaded'] for r in rows), 'sold': sum(r['sold'] for r in rows),
                'short_orders': len({l.order_id for l in short}), 'returned': sum(r['returned'] for r in rows),
            },
            'products': products,
            'unloads': unloads,
            'unload_note': _("Counted short this month: %(n)s · %(value)s", n=len(month_short),
                             value=self._money(sum(self._difference_value(t) for t in month_short))),
        }

    # ------------------------------------------------------------------
    # Purchase orders for low stock
    # ------------------------------------------------------------------

    @api.model
    def beatpro_make_purchase_orders(self, product_ids):
        """Draft purchase orders, one per vendor, for the low products: enough for the
        next 7 days plus 7 more, less what is in the warehouse."""
        self._check_supervisor()
        if 'purchase.order' not in self.env:
            raise UserError(self.env._("Install the Purchase app to make purchase orders."))
        company = self.env.company
        products = self.env['product.product'].browse(product_ids).exists()
        main = self.env['stock.warehouse']._beatpro_main(company)
        stock = location_quantities(self.env, main.lot_stock_id)
        need = weekday_average_need(self.env, company, [('product_id', 'in', products.ids)])
        by_vendor = defaultdict(list)
        skipped = []
        for product in products:
            seller = product._select_seller(quantity=None) if product.seller_ids else False
            qty = max(2 * need.get(product, 0.0) - stock.get(product, 0.0), 0.0)
            if not seller:
                skipped.append(product.display_name)
                continue
            if float_is_zero(qty, precision_rounding=product.uom_id.rounding):
                qty = max(seller.min_qty, 1.0)
            by_vendor[seller.partner_id].append((product, max(qty, seller.min_qty)))
        orders = self.env['purchase.order']
        for vendor, items in by_vendor.items():
            orders |= self.env['purchase.order'].create({
                'partner_id': vendor.id,
                'company_id': company.id,
                'picking_type_id': main.in_type_id.id,
                'origin': self.env._("BeatPro low stock"),
                'order_line': [Command.create({'product_id': product.id, 'product_qty': qty}) for product, qty in items],
            })
        action = {
            'type': 'ir.actions.act_window', 'res_model': 'purchase.order', 'name': self.env._("Purchase Orders"),
            'views': [(False, 'list'), (False, 'form')], 'domain': [('id', 'in', orders.ids)],
        }
        if len(orders) == 1:
            action.update({'res_id': orders.id, 'views': [(False, 'form')]})
        return {'action': action if orders else False, 'skipped': skipped}
