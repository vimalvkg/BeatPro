from collections import defaultdict
from datetime import timedelta

from odoo import api, fields, models
from odoo.exceptions import AccessError
from odoo.tools import formatLang

from .beatpro_statement import period_dates


class ResCompany(models.Model):
    _inherit = 'res.company'

    beatpro_lost_days = fields.Integer(
        string="Lost Shop After (days)", default=30,
        help="A shop that bought before but has no invoice for this many days shows under Lost shops.")


class BeatproReports(models.AbstractModel):
    _name = 'beatpro.reports'
    _description = "BeatPro Sales Reports"

    def _money(self, amount):
        return formatLang(self.env, amount, currency_obj=self.env.company.currency_id, digits=0)

    def _invoice_lines(self, start, end):
        return self.env['account.move.line'].sudo().search([
            ('move_id.move_type', 'in', ('out_invoice', 'out_refund')),
            ('parent_state', '=', 'posted'),
            ('move_id.invoice_date', '>=', start), ('move_id.invoice_date', '<=', end),
            ('display_type', '=', 'product'),
            ('company_id', '=', self.env.company.id),
        ])

    @staticmethod
    def _net(line):
        return -line.balance  # income lines are credits; refunds come back positive

    @api.model
    def beatpro_sales_reports(self, period='this_month'):
        """Everything the Sales Reports page shows, for one period."""
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Sales Reports are for BeatPro supervisors."))
        today = fields.Date.context_today(self)
        start, end = period_dates(period, today)
        length = (end - start).days + 1
        prev_end = start - timedelta(days=1)
        prev_start = prev_end - timedelta(days=length - 1)
        company = self.env.company

        lines = self._invoice_lines(start, end)
        prev_lines = self._invoice_lines(prev_start, prev_end)
        net = sum(self._net(l) for l in lines)
        prev_net = sum(self._net(l) for l in prev_lines)

        # Brands (product categories) and products.
        by_categ, by_product, qty_product = defaultdict(float), defaultdict(float), defaultdict(float)
        for line in lines:
            by_categ[line.product_id.categ_id.name or self.env._("Other")] += self._net(line)
            if not line.product_id:
                continue
            by_product[line.product_id] += self._net(line)
            sign = -1 if line.move_id.move_type == 'out_refund' else 1
            qty_product[line.product_id] += sign * line.product_uom_id._compute_quantity(
                line.quantity, line.product_id.uom_id, raise_if_failure=False)
        top = max(by_categ.values(), default=0) or 1
        categories = [{'name': n, 'amount': self._money(v), 'pct': round(v * 100 / top)}
                      for n, v in sorted(by_categ.items(), key=lambda kv: -kv[1])]
        products = [{'name': p.display_name, 'amount': self._money(v), 'qty': p._beatpro_pack_text(qty_product[p])}
                    for p, v in sorted(by_product.items(), key=lambda kv: -kv[1])[:20]]

        # Reps and routes.
        reps = self.env['res.users'].sudo().search([
            ('all_group_ids', 'in', self.env.ref('beatpro_field_sales.group_beatpro_rep').id),
            ('company_ids', 'in', company.id), ('share', '=', False),
        ]).filtered(lambda u: not u.has_group('beatpro_field_sales.group_beatpro_supervisor'))
        by_rep = defaultdict(float)
        for line in lines:
            by_rep[line.move_id.invoice_user_id.id] += self._net(line)
        compliance = self._compliance(reps, start, min(end, today))
        orders = self.env['sale.order'].sudo().search([
            ('state', '=', 'sale'), ('company_id', '=', company.id),
            ('date_order', '>=', fields.Datetime.to_string(start)),
            ('date_order', '<', fields.Datetime.to_string(end + timedelta(days=1)))])
        order_count = defaultdict(int)
        for order in orders:
            order_count[order.user_id.id] += 1
        rep_rows = [{
            'name': rep.name,
            'sales': self._money(by_rep.get(rep.id, 0.0)),
            'orders': order_count.get(rep.id, 0),
            **compliance.get(rep.id, {'planned': 0, 'visited': 0, 'missed': 0, 'pct': 0}),
        } for rep in reps.sorted(lambda r: -by_rep.get(r.id, 0.0))]
        routes = self.env['beatpro.route'].sudo().search([('company_id', '=', company.id)])
        partner_route = {}
        for route in routes:
            for line in route.line_ids:
                partner_route.setdefault(line.partner_id.commercial_partner_id.id, route)
        by_route = defaultdict(float)
        for line in lines:
            route = partner_route.get(line.move_id.commercial_partner_id.id)
            by_route[route.name if route else self.env._("Not on a route")] += self._net(line)
        route_rows = [{'name': n, 'sales': self._money(v)} for n, v in sorted(by_route.items(), key=lambda kv: -kv[1])]

        # Schemes.
        scheme_lines = self.env['sale.order.line'].sudo().search([
            ('beatpro_scheme_id', '!=', False), ('state', '=', 'sale'), ('company_id', '=', company.id),
            ('order_id.date_order', '>=', fields.Datetime.to_string(start)),
            ('order_id.date_order', '<', fields.Datetime.to_string(end + timedelta(days=1)))])
        schemes, scheme_cost = [], 0.0
        for scheme in scheme_lines.beatpro_scheme_id:
            mine = scheme_lines.filtered(lambda l: l.beatpro_scheme_id == scheme)
            cost = sum(l.price_unit * l.product_uom_qty * l.discount / 100.0 for l in mine)
            scheme_cost += cost
            now = sum(qty_product.get(p, 0.0) for p in scheme.product_ids)
            before = 0.0
            for line in prev_lines.filtered(lambda l: l.product_id in scheme.product_ids):
                sign = -1 if line.move_id.move_type == 'out_refund' else 1
                before += sign * line.product_uom_id._compute_quantity(line.quantity, line.product_id.uom_id, raise_if_failure=False)
            lift = round((now - before) * 100 / before) if before else None
            schemes.append({'name': scheme.name, 'orders': len(mine.order_id), 'cost': self._money(cost),
                            'lift': lift})

        # Shops.
        route_partners = set(partner_route)
        buying = {l.move_id.commercial_partner_id.id for l in lines}
        lost = self._lost_shops(company)
        planned = sum(r['planned'] for r in compliance.values())
        visited = sum(r['visited'] for r in compliance.values())
        return {
            'period': period,
            'label': '%s – %s' % (start.strftime('%d %b'), end.strftime('%d %b %Y')),
            'kpis': {
                'net': self._money(net),
                'net_change': round((net - prev_net) * 100 / prev_net) if prev_net else None,
                'active': len(route_partners & buying),
                'shops': len(route_partners),
                'compliance': round(visited * 100 / planned) if planned else None,
                'missed': planned - visited,
                'scheme_cost': self._money(scheme_cost),
                'scheme_share': round(scheme_cost * 1000 / net) / 10 if net else 0,
            },
            'categories': categories,
            'products': products,
            'reps': rep_rows,
            'routes': route_rows,
            'schemes': schemes,
            'lost': lost,
            'lost_days': company.beatpro_lost_days,
        }

    def _compliance(self, reps, start, end):
        """Planned shops visited per rep: a shop skipped because it was closed counts as visited,
        a shop moved to the next day counts on that day."""
        result = {}
        if end < start:
            return result
        Route = self.env['beatpro.route'].sudo()
        Visit = self.env['beatpro.visit'].sudo()
        for rep in reps:
            routes = Route.search([('user_id', '=', rep.id)])
            visits = Visit.search([('user_id', '=', rep.id), ('state', 'in', ('in_progress', 'done')),
                                   ('check_in', '>=', fields.Datetime.to_string(start)),
                                   ('check_in', '<', fields.Datetime.to_string(end + timedelta(days=1)))])
            visited_on = {(fields.Date.context_today(v, v.check_in), v.partner_id.id) for v in visits}
            planned = done = 0
            day = start
            while day <= end:
                plan = set(routes.filtered(lambda r: not r.weekday or r.weekday == str(day.weekday())).line_ids.partner_id.ids)
                moved_out, moved_in, skipped = Route._beatpro_moves_for(rep, day)
                plan = (plan - set(moved_out.partner_id.ids)) | set(moved_in.partner_id.ids)
                planned += len(plan)
                done += sum(1 for p in plan if (day, p) in visited_on or p in skipped.partner_id.ids)
                day += timedelta(days=1)
            result[rep.id] = {'planned': planned, 'visited': done, 'missed': planned - done,
                              'pct': round(done * 100 / planned) if planned else 0}
        return result

    def _lost_shops(self, company):
        today = fields.Date.context_today(self)
        cutoff = today - timedelta(days=company.beatpro_lost_days or 30)
        groups = self.env['account.move'].sudo()._read_group([
            ('move_type', '=', 'out_invoice'), ('state', '=', 'posted'), ('company_id', '=', company.id),
            ('invoice_date', '>=', today - timedelta(days=180)),
        ], ['commercial_partner_id'], ['invoice_date:max'])
        rows = []
        for partner, last in groups:
            if last and last < cutoff:
                invoice = self.env['account.move'].sudo().search([
                    ('commercial_partner_id', '=', partner.id), ('move_type', '=', 'out_invoice'),
                    ('state', '=', 'posted')], order='invoice_date desc', limit=1)
                rows.append({'name': partner.name, 'city': partner.city or partner.street or '',
                             'rep': invoice.invoice_user_id.name or '', 'days': (today - last).days})
        return sorted(rows, key=lambda r: r['days'])
