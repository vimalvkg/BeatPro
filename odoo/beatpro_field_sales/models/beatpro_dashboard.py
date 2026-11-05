from odoo import api, fields, models
from odoo.exceptions import AccessError

from .beatpro_tools import day_bounds_utc, initials, money, period_bounds_utc


class BeatproDashboard(models.AbstractModel):
    """Figures for the supervisor's Overview screen."""
    _name = 'beatpro.dashboard'
    _description = 'BeatPro Overview'

    @api.model
    def get_data(self, period='today'):
        """Today's, this week's or this month's field figures across all reps.

        :param str period: ``today``, ``week`` or ``month``
        """
        user = self.env.user
        if not user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Only BeatPro supervisors can open the overview."))
        if period not in ('today', 'week', 'month'):
            period = 'today'
        env = self.env
        company = env.company
        today = fields.Date.context_today(self)
        start, end = period_bounds_utc(today, period, user.tz)
        day_start, day_end = day_bounds_utc(today, user.tz)

        reps = env.ref('beatpro_field_sales.group_beatpro_rep').all_user_ids.filtered(
            lambda u: not u.share and company in u.company_ids)
        visits = env['beatpro.visit'].search([
            ('company_id', '=', company.id), ('state', '=', 'done'),
            ('check_in', '>=', start), ('check_in', '<=', end),
        ])
        orders = env['sale.order'].search([
            ('company_id', '=', company.id), ('user_id', 'in', reps.ids), ('state', '!=', 'cancel'),
            ('date_order', '>=', start), ('date_order', '<=', end),
        ])
        payments = env['account.payment'].sudo().search([
            ('company_id', '=', company.id), ('beatpro_method', '!=', False),
            ('state', 'not in', ('canceled', 'rejected')),
            ('date', '>=', fields.Date.to_date(start) if period != 'today' else today), ('date', '<=', today),
        ])
        waiting = env['sale.order'].search([
            ('company_id', '=', company.id), ('beatpro_approval_state', '=', 'waiting'),
        ], order='amount_total desc')

        weekday = str(today.weekday())
        today_routes = env['beatpro.route'].search([
            ('company_id', '=', company.id), ('user_id', 'in', reps.ids),
            '|', ('weekday', '=', weekday), ('weekday', '=', False),
        ])
        planned_today = len(today_routes.line_ids)
        visits_today = visits.filtered(lambda v: day_start <= v.check_in <= day_end)
        in_progress = env['beatpro.visit'].search([
            ('company_id', '=', company.id), ('state', '=', 'in_progress'),
        ])
        closed_today = env['beatpro.day.close'].search([
            ('company_id', '=', company.id), ('date', '=', today), ('state', '=', 'closed'),
        ])

        # Split by the payment methods reps used, as named for them.
        by_method = {}
        for payment in payments:
            label = payment.payment_method_line_id.beatpro_display_name or payment.journal_id.name
            by_method[label] = by_method.get(label, 0.0) + payment.amount
        collected = sum(by_method.values())
        with_order = len(visits.filtered(lambda v: v.result == 'order'))

        # Supervisors are reps too; list only people who actually work in the field.
        has_routes = env['beatpro.route'].search([('company_id', '=', company.id)]).user_id
        reps = reps.filtered(lambda r: r in has_routes or r in visits.user_id or r in orders.user_id)

        rep_rows = []
        for rep in reps.sorted('name'):
            rep_routes = today_routes.filtered(lambda r: r.user_id == rep)
            planned = len(rep_routes.line_ids)
            done = len(visits_today.filtered(lambda v: v.user_id == rep))
            current = in_progress.filtered(lambda v: v.user_id == rep)[:1]
            rep_orders = orders.filtered(lambda o: o.user_id == rep)
            rep_collected = sum(payments.filtered(lambda p: p.beatpro_user_id == rep).mapped('amount'))
            if current:
                status, now = 'live', self.env._("At %s", current.partner_id.display_name)
            elif closed_today.filtered(lambda c: c.user_id == rep):
                status, now = 'done', self.env._("Day closed")
            elif done:
                status, now = 'live', self.env._("On the road")
            elif rep_orders:
                status, now = 'idle', self.env._("Phone orders only")
            else:
                status, now = 'idle', self.env._("Not started")
            rep_rows.append({
                'id': rep.id,
                'initials': initials(rep.name),
                'name': rep.name,
                'route': ', '.join(rep_routes.mapped('name')) or self.env._("No route today"),
                'visits': f"{done} / {planned}",
                'pct': min(100, round(100 * done / planned)) if planned else 0,
                'orders': money(env, sum(rep_orders.mapped('amount_total'))),
                'collected': money(env, rep_collected),
                'status': status,
                'now': now,
            })

        reason_names = dict(env['beatpro.visit']._fields['no_order_reason'].selection)
        no_order = visits.filtered(lambda v: v.result in ('no_order', 'closed'))
        counts = {}
        for visit in no_order:
            label = reason_names.get(visit.no_order_reason) if visit.result == 'no_order' else self.env._("Shop closed")
            label = label or self.env._("Other")
            counts[label] = counts.get(label, 0) + 1
        top = max(counts.values()) if counts else 1

        return {
            'period': period,
            'greeting_name': user.name.split()[0] if user.name else '',
            'date_label': today.strftime('%a, %d %b'),
            'visits_done': len(visits),
            'visits_planned': planned_today if period == 'today' else False,
            'visits_pct': min(100, round(100 * len(visits) / planned_today)) if period == 'today' and planned_today else 0,
            'visits_left': max(planned_today - len(visits_today), 0),
            'reps_out': len({v.user_id.id for v in visits_today} | {v.user_id.id for v in in_progress}),
            'order_value': money(env, sum(orders.mapped('amount_total'))),
            'order_count': len(orders),
            'visits_with_order': with_order,
            'strike_rate': round(100 * with_order / len(visits)) if visits else 0,
            'collected': money(env, collected),
            'collected_split': [
                {'key': f'm{index}', 'color': index % 4, 'label': label, 'amount': money(env, amount),
                 'share': round(100 * amount / collected) if collected else 0}
                for index, (label, amount) in enumerate(sorted(by_method.items(), key=lambda kv: -kv[1]))
            ],
            'approval_count': len(waiting),
            'approval_value': money(env, sum(waiting.mapped('amount_total'))),
            'approvals': [{
                'id': order.id,
                'shop': order.partner_id.display_name,
                'detail': ' · '.join([
                    order.user_id.name or '',
                    self.env._("up to %s%% off", f"{max(order.order_line.mapped('discount') or [0]):g}"),
                    money(env, order.amount_total),
                ]),
            } for order in waiting[:5]],
            'reps': rep_rows,
            'no_order_count': len(no_order),
            'reasons': [
                {'label': label, 'count': count, 'pct': round(100 * count / top)}
                for label, count in sorted(counts.items(), key=lambda kv: -kv[1])
            ],
        }
