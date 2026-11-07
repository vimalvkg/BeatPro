import calendar
from datetime import date

from dateutil.relativedelta import relativedelta

from odoo import api, fields, models
from odoo.exceptions import AccessError, ValidationError
from odoo.tools import formatLang

PAY_TYPES = [
    ('salary', "Monthly salary only"),
    ('incentive', "Salary + targets and incentive"),
]


def month_start(day):
    return day.replace(day=1)


def money(env, amount):
    return formatLang(env, amount, currency_obj=env.company.currency_id)


class BeatproIncentivePlan(models.Model):
    _name = 'beatpro.incentive.plan'
    _description = "Incentive Plan"
    _order = 'name'

    name = fields.Char(required=True)
    active = fields.Boolean(default=True)
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')
    slab_basis = fields.Selection([
        ('amount', "Sales amount"),
        ('target', "% of the rep's target"),
    ], string="Lines Start From", required=True, default='amount',
        help="Commission lines start from an amount of sales (AED 10,000) or from a share of "
             "the rep's monthly target (80%).")
    method = fields.Selection([
        ('tiered', "Each part of sales at its own rate"),
        ('whole', "All sales at the rate reached"),
    ], string="Commission On", required=True, default='tiered',
        help="Each part: with lines from 10,000 at 5% and from 40,000 at 2%, sales of 50,000 earn "
             "5% on 30,000 and 2% on 10,000. All sales: sales of 50,000 earn 2% on all 50,000.")
    line_ids = fields.One2many('beatpro.incentive.plan.line', 'plan_id', string="Commission Lines", copy=True)
    product_target_bonus = fields.Monetary(
        string="Bonus per Product Target Met",
        help="Added for each product target the rep reaches in the month.")
    example_amount = fields.Monetary(string="Example Sales", default=50000.0,
                                     help="Sales to show an example payout for.")
    example_target = fields.Monetary(string="Example Target", default=60000.0)
    example_text = fields.Char(string="Example", compute='_compute_example_text')
    user_ids = fields.One2many('res.users', 'beatpro_incentive_plan_id', string="Reps on This Plan")

    @api.depends('line_ids.threshold', 'line_ids.rate', 'line_ids.bonus', 'slab_basis', 'method',
                 'example_amount', 'example_target')
    def _compute_example_text(self):
        for plan in self:
            amount = plan._commission(plan.example_amount, plan.example_target)
            plan.example_text = self.env._(
                "Sales of %(sales)s earn %(amount)s", sales=money(self.env, plan.example_amount),
                amount=money(self.env, amount))

    def _lines_in_amounts(self, target):
        """The commission lines with their start as an amount of sales, lowest first."""
        self.ensure_one()
        lines = []
        for line in self.line_ids.sorted('threshold'):
            start = line.threshold if self.slab_basis == 'amount' else (target or 0.0) * line.threshold / 100.0
            if self.slab_basis == 'target' and not target:
                continue
            lines.append((start, line.rate, line.bonus))
        return lines

    def _commission(self, sales, target):
        """Commission on ``sales`` (bonuses included, product bonuses not)."""
        self.ensure_one()
        lines = self._lines_in_amounts(target)
        reached = [line for line in lines if sales + 0.005 >= line[0]]
        if not reached:
            return 0.0
        bonus = sum(line[2] for line in reached)
        if self.method == 'whole':
            return sales * reached[-1][1] / 100.0 + bonus
        total = 0.0
        for i, (start, rate, _bonus) in enumerate(lines):
            end = lines[i + 1][0] if i + 1 < len(lines) else None
            part = (min(sales, end) if end is not None else sales) - start
            if part > 0:
                total += part * rate / 100.0
        return total + bonus

    def _next_step(self, sales, target):
        """The next commission line not reached yet: ``(start amount, rate, bonus)`` or None."""
        self.ensure_one()
        for line in self._lines_in_amounts(target):
            if line[0] > sales + 0.005:
                return line
        return None

    def _describe_lines(self, target):
        """The commission lines in words, for the rep's phone."""
        self.ensure_one()
        result = []
        for line in self.line_ids.sorted('threshold'):
            if self.slab_basis == 'target' and not target:
                continue
            start = line.threshold if self.slab_basis == 'amount' else target * line.threshold / 100.0
            label = (self.env._("From %s", money(self.env, line.threshold)) if self.slab_basis == 'amount'
                     else self.env._("From %(pct)g%% of target (%(amount)s)", pct=line.threshold, amount=money(self.env, start)))
            what = self.env._("%(rate)g%% on each part", rate=line.rate) if self.method == 'tiered' \
                else self.env._("%(rate)g%% of all sales", rate=line.rate)
            if line.bonus:
                what += ' + ' + self.env._("%s bonus", money(self.env, line.bonus))
            result.append({'from': label, 'from_amount': start, 'rate': line.rate, 'bonus': line.bonus, 'text': what})
        return result


class BeatproIncentivePlanLine(models.Model):
    _name = 'beatpro.incentive.plan.line'
    _description = "Incentive Plan Commission Line"
    _order = 'threshold'

    plan_id = fields.Many2one('beatpro.incentive.plan', required=True, ondelete='cascade', index=True)
    currency_id = fields.Many2one(related='plan_id.currency_id')
    threshold = fields.Float(string="From", required=True,
                             help="Sales amount, or % of the target, from which this line counts.")
    rate = fields.Float(string="Commission (%)", required=True, digits=(5, 2))
    bonus = fields.Monetary(string="Bonus", help="A fixed amount added once this line is reached.")

    @api.constrains('rate', 'threshold')
    def _check_values(self):
        for line in self:
            if line.rate < 0 or line.threshold < 0:
                raise ValidationError(self.env._("Commission lines can't be negative."))


class BeatproTarget(models.Model):
    _name = 'beatpro.target'
    _description = "Rep Monthly Target"
    _order = 'month desc, user_id'
    _rec_name = 'display_name'

    user_id = fields.Many2one('res.users', string="Rep", required=True, index=True,
                              domain="[('beatpro_pay_type', '=', 'incentive')]")
    month = fields.Date(required=True, default=lambda self: month_start(fields.Date.context_today(self)),
                        help="Any day of the month; it is kept as the 1st.")
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')
    plan_id = fields.Many2one('beatpro.incentive.plan', string="Incentive Plan",
                              compute='_compute_plan_id', store=True, readonly=False)
    amount = fields.Monetary(string="Sales Target", required=True)
    line_ids = fields.One2many('beatpro.target.line', 'target_id', string="Product Targets", copy=True)
    achieved = fields.Monetary(string="Sold", compute='_compute_progress',
                               help="Invoiced in the month, before VAT, less credit notes.")
    progress = fields.Float(string="Reached (%)", compute='_compute_progress')
    earned = fields.Monetary(string="Incentive Earned", compute='_compute_progress')
    projected = fields.Monetary(string="Sold at This Pace", compute='_compute_progress')
    projected_earned = fields.Monetary(string="Incentive at This Pace", compute='_compute_progress')
    state = fields.Selection([('open', "Open"), ('approved', "Approved")], default='open', required=True, copy=False)
    approved_amount = fields.Monetary(string="Approved Incentive", readonly=True, copy=False)
    approved_by_id = fields.Many2one('res.users', string="Approved By", readonly=True, copy=False)

    _user_month_unique = models.UniqueIndex('(user_id, month)', "A rep has one target per month.")

    @api.depends('user_id', 'month')
    def _compute_display_name(self):
        for target in self:
            target.display_name = '%s · %s' % (target.user_id.name or '', target.month and target.month.strftime('%B %Y') or '')

    @api.depends('user_id')
    def _compute_plan_id(self):
        for target in self:
            if not target.plan_id:
                target.plan_id = target.user_id.beatpro_incentive_plan_id

    @api.model_create_multi
    def create(self, vals_list):
        for vals in vals_list:
            if vals.get('month'):
                vals['month'] = month_start(fields.Date.to_date(vals['month']))
        return super().create(vals_list)

    def write(self, vals):
        if vals.get('month'):
            vals['month'] = month_start(fields.Date.to_date(vals['month']))
        return super().write(vals)

    def _period(self):
        self.ensure_one()
        first = self.month
        last = first + relativedelta(months=1, days=-1)
        return first, last

    @api.model
    def _beatpro_sold(self, users, first, last, company):
        """Invoiced before VAT, less credit notes, per rep, between two dates."""
        groups = self.env['account.move'].sudo()._read_group([
            ('invoice_user_id', 'in', users.ids),
            ('move_type', 'in', ('out_invoice', 'out_refund')),
            ('state', '=', 'posted'),
            ('invoice_date', '>=', first),
            ('invoice_date', '<=', last),
            ('company_id', '=', company.id),
        ], ['invoice_user_id'], ['amount_untaxed_signed:sum'])
        return {user.id: total for user, total in groups}

    @api.model
    def _pace(self, sold, first, last):
        today = fields.Date.context_today(self)
        if today > last:
            return sold
        if today < first:
            return 0.0
        days = (last - first).days + 1
        elapsed = (today - first).days + 1
        return sold * days / elapsed

    @api.depends('user_id', 'month', 'amount', 'plan_id', 'line_ids.achieved_qty')
    def _compute_progress(self):
        for target in self:
            if not (target.user_id and target.month):
                target.update({'achieved': 0, 'progress': 0, 'earned': 0, 'projected': 0, 'projected_earned': 0})
                continue
            first, last = target._period()
            sold = self._beatpro_sold(target.user_id, first, last, target.company_id).get(target.user_id.id, 0.0)
            target.achieved = sold
            target.progress = sold * 100.0 / target.amount if target.amount else 0.0
            target.earned = target._incentive(sold)
            target.projected = self._pace(sold, first, last)
            target.projected_earned = target._incentive(target.projected, pace=True)

    def _incentive(self, sold, pace=False):
        self.ensure_one()
        plan = self.plan_id
        if not plan:
            return 0.0
        met = sum(1 for line in self.line_ids if (line.projected_qty if pace else line.achieved_qty) + 1e-9 >= line.qty)
        return plan._commission(sold, self.amount) + met * plan.product_target_bonus

    def _check_supervisor(self):
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Only a BeatPro supervisor can approve incentives."))

    def action_approve(self):
        self._check_supervisor()
        for target in self:
            target.write({'state': 'approved', 'approved_amount': target.earned, 'approved_by_id': self.env.uid})
        return True

    def action_reopen(self):
        self._check_supervisor()
        self.write({'state': 'open', 'approved_amount': 0.0, 'approved_by_id': False})
        return True

    # -- For the app and the Targets board ------------------------------------------

    def _beatpro_card(self):
        """What the rep's phone shows about this target."""
        self.ensure_one()
        first, last = self._period()
        today = fields.Date.context_today(self)
        days_left = max((last - today).days + 1, 0) if today <= last else 0
        to_go = max(self.amount - self.achieved, 0.0)
        step = self.plan_id and self.plan_id._next_step(self.achieved, self.amount)
        next_step = False
        if step:
            gain = self._incentive(step[0]) - self.earned
            next_step = {
                'amount': step[0] - self.achieved,
                'rate': step[1],
                'earns': gain,
                'text': self.env._("%(more)s more to reach %(rate)g%%: you earn %(gain)s",
                                   more=money(self.env, step[0] - self.achieved), rate=step[1],
                                   gain=money(self.env, gain)),
            }
        return {
            'id': self.id,
            'month': fields.Date.to_string(first),
            'month_label': first.strftime('%B'),
            'target': self.amount,
            'achieved': self.achieved,
            'progress': self.progress,
            'earned': self.earned,
            'projected': self.projected,
            'projected_earned': self.projected_earned,
            'days_left': days_left,
            'per_day': to_go / days_left if days_left else 0.0,
            'next_step': next_step,
            'plan': self.plan_id.name or False,
            'method': self.plan_id.method or False,
            'lines': self.plan_id._describe_lines(self.amount) if self.plan_id else [],
            'product_bonus': self.plan_id.product_target_bonus or 0.0,
            'products': [{
                'product_id': line.product_id.id,
                'name': line.product_id.display_name,
                'qty': line.qty,
                'achieved': line.achieved_qty,
                'unit': line._unit_short(),
            } for line in self.line_ids],
            'approved': self.state == 'approved',
        }

    @api.model
    def beatpro_my_target(self):
        """The signed-in rep's target this month, or False for reps on salary only."""
        user = self.env.user
        if user.beatpro_pay_type != 'incentive':
            return False
        target = self.sudo().search([('user_id', '=', user.id),
                                     ('month', '=', month_start(fields.Date.context_today(self)))], limit=1)
        return target._beatpro_card() if target else False

    @api.model
    def beatpro_targets_board(self, month=None):
        """The supervisor's Targets board for a month: every rep, with or without a target."""
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("The Targets board is for BeatPro supervisors."))
        first = month_start(fields.Date.to_date(month) if month else fields.Date.context_today(self))
        last = first + relativedelta(months=1, days=-1)
        company = self.env.company
        reps = self.env['res.users'].sudo().search([
            ('all_group_ids', 'in', self.env.ref('beatpro_field_sales.group_beatpro_rep').id),
            ('company_ids', 'in', company.id), ('share', '=', False),
        ]).filtered(lambda u: not u.has_group('beatpro_field_sales.group_beatpro_supervisor') or u.beatpro_pay_type == 'incentive')
        targets = {t.user_id.id: t for t in self.sudo().search([('month', '=', first), ('user_id', 'in', reps.ids)])}
        sold = self._beatpro_sold(reps, first, last, company)
        rows = []
        for rep in reps.sorted(lambda u: (u.beatpro_pay_type != 'incentive', u.name)):
            target = targets.get(rep.id)
            row = {
                'user_id': rep.id,
                'name': rep.name,
                'initials': ''.join(w[0] for w in rep.name.split()[:2]).upper(),
                'pay_type': rep.beatpro_pay_type,
                'pay_label': dict(PAY_TYPES)[rep.beatpro_pay_type],
                'sold': sold.get(rep.id, 0.0),
                'sold_text': money(self.env, sold.get(rep.id, 0.0)),
                'target_id': target.id if target else False,
            }
            if rep.beatpro_pay_type == 'incentive' and target:
                row.update({
                    'target': target.amount,
                    'target_text': money(self.env, target.amount),
                    'progress': target.progress,
                    'earned': target.earned,
                    'earned_text': money(self.env, target.earned),
                    'projected_earned': target.projected_earned,
                    'projected_text': money(self.env, target.projected_earned),
                    'approved': target.state == 'approved',
                    'approved_text': money(self.env, target.approved_amount) if target.state == 'approved' else False,
                })
            rows.append(row)
        with_target = [r for r in rows if r.get('target')]
        team_target = sum(r['target'] for r in with_target)
        team_sold = sum(r['sold'] for r in with_target)
        return {
            'month': fields.Date.to_string(first),
            'month_label': first.strftime('%B %Y'),
            'rows': rows,
            'team_target': money(self.env, team_target),
            'team_sold': money(self.env, team_sold),
            'team_progress': round(team_sold * 100 / team_target) if team_target else 0,
            'earned': money(self.env, sum(r['earned'] for r in with_target)),
            'payout': money(self.env, sum(r['projected_earned'] for r in with_target)),
            'past': last < fields.Date.context_today(self),
        }


class BeatproTargetLine(models.Model):
    _name = 'beatpro.target.line'
    _description = "Rep Monthly Product Target"

    target_id = fields.Many2one('beatpro.target', required=True, ondelete='cascade', index=True)
    product_id = fields.Many2one('product.product', required=True)
    qty = fields.Float(string="Target", required=True, digits='Product Unit')
    uom_id = fields.Many2one('uom.uom', string="Unit", compute='_compute_uom_id', store=True, readonly=False,
                             help="Counted in this unit, for example cases.")
    achieved_qty = fields.Float(string="Sold", compute='_compute_achieved', digits='Product Unit')
    projected_qty = fields.Float(compute='_compute_achieved', digits='Product Unit')

    @api.depends('product_id')
    def _compute_uom_id(self):
        for line in self:
            if line.product_id and not line.uom_id:
                cases = line.product_id.uom_ids.filtered(lambda u: u.factor > line.product_id.uom_id.factor)
                line.uom_id = max(cases, key=lambda u: u.factor) if cases else line.product_id.uom_id

    def _unit_short(self):
        from .beatpro_scheme import unit_short
        return unit_short(self.env, self.uom_id, self.product_id) if self.uom_id else ''

    @api.depends('product_id', 'uom_id', 'target_id.month', 'target_id.user_id')
    def _compute_achieved(self):
        for line in self:
            target = line.target_id
            if not (line.product_id and target.month and target.user_id):
                line.achieved_qty = line.projected_qty = 0.0
                continue
            first, last = target._period()
            moves = self.env['account.move.line'].sudo().search([
                ('move_id.invoice_user_id', '=', target.user_id.id),
                ('move_id.move_type', 'in', ('out_invoice', 'out_refund')),
                ('move_id.state', '=', 'posted'),
                ('move_id.invoice_date', '>=', first),
                ('move_id.invoice_date', '<=', last),
                ('product_id', '=', line.product_id.id),
                ('display_type', '=', 'product'),
            ])
            total = 0.0
            uom = line.uom_id or line.product_id.uom_id
            for move_line in moves:
                qty = move_line.product_uom_id._compute_quantity(move_line.quantity, uom, raise_if_failure=False)
                total += -qty if move_line.move_id.move_type == 'out_refund' else qty
            line.achieved_qty = total
            line.projected_qty = self.env['beatpro.target']._pace(total, first, last)
