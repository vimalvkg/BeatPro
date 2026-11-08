from collections import defaultdict
from datetime import date, datetime, time, timedelta

from dateutil.relativedelta import relativedelta

from odoo import api, fields, models
from odoo.exceptions import AccessError

from odoo.addons.beatpro_field_sales.models.beatpro_tools import day_bounds_utc, money

SUPERVISOR = 'beatpro_field_sales.group_beatpro_supervisor'
REP = 'beatpro_field_sales.group_beatpro_rep'

# The side menu: label, icon, action, and who sees it. A list of actions means
# "the first one this user may open". Items the user can't open are left out.
SIDEBAR = [
    ('dashboard', "Dashboard", 'fa-home', ['beatpro_theme.action_van_sales_dashboard',
                                            'beatpro_field_sales.action_beatpro_my_day_screen']),
    ('orders', "Sales Orders", 'fa-file-text-o', ['sale.action_orders']),
    ('customers', "Customers", 'fa-users', ['account.res_partner_action_customer']),
    ('routes', "Routes", 'fa-map-marker', ['beatpro_field_sales.action_beatpro_route']),
    ('vans', "Vans", 'fa-truck', ['beatpro_field_sales.action_beatpro_van_desk',
                                  'beatpro_field_sales.action_beatpro_my_van']),
    ('products', "Products", 'fa-cube', ['sale.product_template_action']),
    ('schemes', "Schemes", 'fa-gift', ['beatpro_field_sales.action_beatpro_scheme']),
    ('returns', "Returns", 'fa-undo', ['beatpro_field_sales.action_beatpro_shop_return']),
    ('cash', "Cash Handover", 'fa-money', ['beatpro_field_sales.action_beatpro_cash_handover']),
    ('expenses', "Expenses", 'fa-credit-card', ['beatpro_field_sales.action_beatpro_expense']),
    ('targets', "Targets", 'fa-bullseye', ['beatpro_field_sales.action_beatpro_targets_board']),
    ('live_map', "Live Map", 'fa-map', ['beatpro_field_sales.action_beatpro_live_map']),
    ('surveys', "Surveys", 'fa-camera', ['beatpro_field_sales.action_beatpro_survey_answer']),
    ('invoices', "Invoices", 'fa-money', ['account.action_move_out_invoice_type']),
    ('reports', "Reports", 'fa-bar-chart', ['sale.action_order_report_all']),
    ('settings', "Settings", 'fa-cog', ['base.res_config_setting_act_window']),
]

# Client actions don't name a model: who may open each one.
CLIENT_ACTION_GROUPS = {
    'beatpro.sales_dashboard': (SUPERVISOR, 'sales_team.group_sale_salesman_all_leads'),
    'beatpro.my_day': (REP,),
    'beatpro.van_desk': (SUPERVISOR, 'stock.group_stock_user'),
    'beatpro.my_van': (REP,),
    'beatpro.targets_board': (SUPERVISOR,),
    'beatpro.live_map': (SUPERVISOR,),
    'beatpro.cash_handover': (SUPERVISOR, 'account.group_account_user'),
}


class BeatproTheme(models.AbstractModel):
    _name = 'beatpro.theme'
    _description = 'BeatPro Theme'

    # ------------------------------------------------------------------
    # Side menu
    # ------------------------------------------------------------------

    def _can_open(self, action):
        user = self.env.user
        action_groups = action.sudo().group_ids if 'group_ids' in action._fields else self.env['res.groups']
        if action_groups and not (action_groups & user.all_group_ids):
            return False
        if action._name == 'ir.actions.act_window':
            return action.res_model in self.env and self.env[action.res_model].has_access('read')
        if action._name == 'ir.actions.client':
            groups = CLIENT_ACTION_GROUPS.get(action.tag)
            return groups is None or any(user.has_group(group) for group in groups)
        return True

    @api.model
    def beatpro_sidebar(self):
        """The side menu items this user can open: ``[{key, label, icon, action_id}]``."""
        items = []
        for key, label, icon, xmlids in SIDEBAR:
            if key == 'settings' and not self.env.user.has_group('base.group_system'):
                continue
            if key == 'invoices' and not self.env.user.has_group('account.group_account_invoice'):
                continue
            for xmlid in xmlids:
                action = self.env.ref(xmlid, raise_if_not_found=False)
                if action and self._can_open(action.sudo().browse(action.id)):
                    items.append({'key': key, 'label': self.env._(label), 'icon': icon, 'action_id': action.id})
                    break
        company = self.env.company
        return {'items': items, 'company': company.name, 'brand': 'BeatPro', 'tagline': self.env._("Van Sales")}

    # ------------------------------------------------------------------
    # Van Sales Dashboard
    # ------------------------------------------------------------------

    @api.model
    def _period_range(self, period, today):
        if period == 'week':
            start = today - timedelta(days=today.weekday())
            return start, start + timedelta(days=7), start - timedelta(days=7)
        if period == 'quarter':
            start = date(today.year, 3 * ((today.month - 1) // 3) + 1, 1)
            return start, start + relativedelta(months=3), start - relativedelta(months=3)
        if period == 'year':
            start = date(today.year, 1, 1)
            return start, start + relativedelta(years=1), start - relativedelta(years=1)
        start = today.replace(day=1)
        return start, start + relativedelta(months=1), start - relativedelta(months=1)

    @api.model
    def _buckets(self, period, start, end):
        """Chart buckets for the period: (label, start, end)."""
        buckets = []
        if period == 'week':
            for i in range(7):
                day = start + timedelta(days=i)
                buckets.append((day.strftime('%a'), day, day + timedelta(days=1)))
        elif period == 'month':
            day, n = start, 1
            while day < end:
                stop = min(day + timedelta(days=7), end)
                buckets.append((self.env._("Week %s", n), day, stop))
                day, n = stop, n + 1
        else:
            day = start
            while day < end:
                stop = day + relativedelta(months=1)
                buckets.append((day.strftime('%b'), day, stop))
                day = stop
        return buckets

    def _utc(self, day):
        """Midnight of ``day`` in the user's time zone, as naive UTC."""
        return day_bounds_utc(day, self.env.user.tz or 'UTC')[0]

    @api.model
    def get_sales_dashboard(self, period='week', route_id=False):
        user = self.env.user
        if not any(user.has_group(g) for g in CLIENT_ACTION_GROUPS['beatpro.sales_dashboard']):
            raise AccessError(self.env._("The Van Sales Dashboard is for supervisors and sales managers."))
        company = self.env.company
        today = fields.Date.context_today(self)
        start, end, prev_start = self._period_range(period, today)
        SaleOrder = self.env['sale.order']
        partner_ids = None
        routes = self.env['beatpro.route'].search([('company_id', '=', company.id)])
        route = routes.filtered(lambda r: r.id == route_id)
        if route:
            partner_ids = route.line_ids.partner_id.ids

        def order_domain(a, b):
            domain = [('company_id', '=', company.id), ('state', '=', 'sale'),
                      ('date_order', '>=', self._utc(a)), ('date_order', '<', self._utc(b))]
            if partner_ids is not None:
                domain.append(('partner_id', 'child_of', partner_ids))
            return domain

        def payment_domain(a, b):
            domain = [('company_id', '=', company.id), ('state', 'in', ('in_process', 'paid')),
                      ('payment_type', '=', 'inbound'), ('partner_type', '=', 'customer'),
                      ('date', '>=', a), ('date', '<', b)]
            if partner_ids is not None:
                domain.append(('partner_id', 'child_of', partner_ids))
            return domain

        orders = SaleOrder.search(order_domain(start, end))
        prev_orders = SaleOrder.search(order_domain(prev_start, start))
        Payment = self.env['account.payment'].sudo()
        collected = sum(Payment.search(payment_domain(start, end)).mapped('amount_company_currency_signed'))
        prev_collected = sum(Payment.search(payment_domain(prev_start, start)).mapped('amount_company_currency_signed'))

        def trend(now, before):
            if not before:
                return None
            return round((now - before) / before * 100, 1)

        buckets = self._buckets(period, start, end)
        chart = []
        for label, a, b in buckets:
            in_bucket = orders.filtered(lambda o: self._utc(a) <= o.date_order < self._utc(b))
            chart.append({'label': label, 'amount': sum(in_bucket.mapped('amount_total')), 'count': len(in_bucket)})
        spark_sales = [c['amount'] for c in chart]
        spark_orders = [c['count'] for c in chart]

        sales = sum(orders.mapped('amount_total'))
        prev_sales = sum(prev_orders.mapped('amount_total'))
        shops = orders.partner_id.commercial_partner_id
        prev_shops = prev_orders.partner_id.commercial_partner_id

        # Sales by product category (untaxed, by order line).
        by_categ = defaultdict(float)
        for line in orders.order_line.filtered(lambda l: not l.display_type and l.product_id):
            by_categ[line.product_id.categ_id.name or self.env._("Uncategorized")] += line.price_subtotal
        categ_total = sum(by_categ.values()) or 1.0
        ranked = sorted(by_categ.items(), key=lambda item: -item[1])
        categories = [{'name': n, 'share': round(v / categ_total * 100)} for n, v in ranked[:3]]
        if len(ranked) > 3:
            categories.append({'name': self.env._("Others"), 'share': round(sum(v for _n, v in ranked[3:]) / categ_total * 100)})

        # Top shops.
        by_shop = defaultdict(float)
        for order in orders:
            by_shop[order.partner_id.commercial_partner_id] += order.amount_total
        top = [{'id': p.id, 'name': p.name, 'amount': money(self.env, v)}
               for p, v in sorted(by_shop.items(), key=lambda item: -item[1])[:5]]

        # Sales by route: the visit's route, else the shop's route.
        route_of_partner = {}
        for r in routes:
            for line in r.line_ids:
                route_of_partner.setdefault(line.partner_id.commercial_partner_id.id, r)
        by_route = defaultdict(float)
        for order in orders:
            r = order.beatpro_visit_id.route_id or route_of_partner.get(order.partner_id.commercial_partner_id.id)
            by_route[r.name if r else self.env._("Other shops")] += order.amount_total
        route_max = max(by_route.values()) if by_route else 1.0
        route_rows = [{'name': n, 'amount': money(self.env, v), 'pct': round(v / route_max * 100)}
                      for n, v in sorted(by_route.items(), key=lambda item: -item[1])[:5]]

        # Collections against what is still owed.
        invoice_domain = [('company_id', '=', company.id), ('move_type', '=', 'out_invoice'),
                          ('state', '=', 'posted'), ('payment_state', 'in', ('not_paid', 'partial'))]
        if partner_ids is not None:
            invoice_domain.append(('partner_id', 'child_of', partner_ids))
        due = sum(self.env['account.move'].sudo().search(invoice_domain).mapped('amount_residual_signed'))
        collect_total = collected + due

        return {
            'period': period,
            'route_id': route.id or False,
            'routes': [{'id': r.id, 'name': r.name} for r in routes],
            'greeting_name': user.name,
            'company': company.name,
            'kpis': [
                {'key': 'sales', 'label': self.env._("Total sales"), 'value': money(self.env, sales),
                 'trend': trend(sales, prev_sales), 'spark': spark_sales, 'icon': 'fa-line-chart'},
                {'key': 'orders', 'label': self.env._("Orders"), 'value': str(len(orders)),
                 'trend': trend(len(orders), len(prev_orders)), 'spark': spark_orders, 'icon': 'fa-shopping-bag'},
                {'key': 'shops', 'label': self.env._("Active shops"), 'value': str(len(shops)),
                 'trend': trend(len(shops), len(prev_shops)), 'spark': spark_orders, 'icon': 'fa-users'},
                {'key': 'collected', 'label': self.env._("Collected"), 'value': money(self.env, collected),
                 'trend': trend(collected, prev_collected), 'spark': spark_sales, 'icon': 'fa-database'},
            ],
            'chart': chart,
            'chart_max_amount': max([c['amount'] for c in chart] + [1.0]),
            'chart_max_count': max([c['count'] for c in chart] + [1]),
            'categories': categories,
            'sales_total': money(self.env, sales),
            'top_shops': top,
            'routes_sales': route_rows,
            'collected': money(self.env, collected),
            'due': money(self.env, due),
            'collect_total': money(self.env, collect_total),
            'collected_pct': round(collected / collect_total * 100) if collect_total else 0,
            'activity': self._recent_activity(company),
        }

    @api.model
    def _recent_activity(self, company, limit=6):
        events = []
        for order in self.env['sale.order'].search(
                [('company_id', '=', company.id), ('state', '=', 'sale')], order='date_order desc', limit=limit):
            events.append((order.date_order, 'order', self.env._(
                "Order %(name)s · %(shop)s · %(amount)s", name=order.name, shop=order.partner_id.name,
                amount=money(self.env, order.amount_total))))
        for payment in self.env['account.payment'].sudo().search(
                [('company_id', '=', company.id), ('payment_type', '=', 'inbound'),
                 ('state', 'in', ('in_process', 'paid'))], order='create_date desc', limit=limit):
            events.append((payment.create_date, 'payment', self.env._(
                "%(amount)s collected · %(shop)s", amount=money(self.env, payment.amount), shop=payment.partner_id.name)))
        for transfer in self.env['beatpro.van.transfer'].sudo().search(
                [('company_id', '=', company.id), ('state', 'in', ('sent', 'to_approve', 'done'))],
                order='write_date desc', limit=limit):
            if transfer.kind == 'unload' and transfer.has_difference:
                diff = transfer.total_difference
                text = self.env._("%(rep)s: unload %(qty)s %(way)s", rep=transfer.user_id.name,
                                  qty='%g' % abs(diff), way=self.env._("short") if diff < 0 else self.env._("extra"))
                kind = 'alert'
            else:
                text = self.env._("%(rep)s: %(kind)s %(state)s", rep=transfer.user_id.name,
                                  kind=dict(transfer._fields['kind'].selection)[transfer.kind].lower(),
                                  state=dict(transfer._fields['state'].selection)[transfer.state].lower())
                kind = 'van'
            events.append((transfer.write_date, kind, text))
        events.sort(key=lambda e: e[0], reverse=True)
        return [{
            'kind': kind,
            'text': text,
            'time': fields.Datetime.context_timestamp(self, when).strftime('%d %b, %I:%M %p'),
        } for when, kind, text in events[:limit]]
