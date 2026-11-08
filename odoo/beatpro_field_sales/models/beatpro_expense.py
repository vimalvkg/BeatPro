from dateutil.relativedelta import relativedelta

from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError
from odoo.fields import Command

PAID_FROM = [
    ('cash', "Cash collected"),
    ('own', "Own money"),
    ('card', "Company card"),
]


def is_cashier(env):
    """Accountants count the cash reps hand in."""
    user = env.user
    return user.has_group('account.group_account_user') or user.has_group('account.group_account_manager')


class BeatproExpenseCategory(models.Model):
    _name = 'beatpro.expense.category'
    _description = "Rep Expense Category"
    _order = 'sequence, id'

    name = fields.Char(required=True, translate=True)
    sequence = fields.Integer(default=10)
    active = fields.Boolean(default=True)
    company_id = fields.Many2one('res.company', default=lambda self: self.env.company)
    account_id = fields.Many2one(
        'account.account', string="Expense Account", company_dependent=True,
        domain="[('account_type', 'in', ('expense', 'expense_direct_cost'))]",
        help="Where approved expenses of this kind are booked. Empty: the company's default expense account.")

    def _beatpro_account(self, company):
        self.ensure_one()
        account = self.with_company(company).account_id
        if not account:
            account = company.expense_account_id or self.env['account.account'].sudo().search([
                *self.env['account.account']._check_company_domain(company), ('account_type', '=', 'expense')], limit=1)
        if not account:
            raise UserError(self.env._("Set an expense account on the expense category %s.", self.name))
        return account


class BeatproExpense(models.Model):
    _name = 'beatpro.expense'
    _description = "Rep Expense"
    _inherit = ['mail.thread', 'beatpro.mobile.mixin']
    _order = 'date desc, id desc'

    user_id = fields.Many2one('res.users', string="Rep", required=True, index=True, default=lambda self: self.env.user)
    date = fields.Date(required=True, default=fields.Date.context_today, index=True)
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    currency_id = fields.Many2one(related='company_id.currency_id')
    category_id = fields.Many2one('beatpro.expense.category', string="Expense", required=True)
    amount = fields.Monetary(required=True)
    paid_from = fields.Selection(PAID_FROM, required=True, default='cash',
                                 help="Cash collected: taken off the cash the rep hands in. Own money: paid back "
                                      "to the rep. Company card: nothing to hand in or pay back.")
    note = fields.Char(string="Where", help="Shop or supplier, e.g. ENOC Al Quoz.")
    receipt = fields.Image(max_width=1600, max_height=1600, attachment=True)
    has_receipt = fields.Boolean(compute='_compute_has_receipt')
    state = fields.Selection([
        ('waiting', "Waiting"),
        ('approved', "Approved"),
        ('rejected', "Rejected"),
    ], default='waiting', required=True, tracking=True, copy=False)
    reject_reason = fields.Char(copy=False, tracking=True)
    move_id = fields.Many2one('account.move', string="Journal Entry", readonly=True, copy=False)

    @api.depends('receipt')
    def _compute_has_receipt(self):
        for expense in self:
            expense.has_receipt = bool(expense.receipt)

    @api.depends('category_id', 'user_id', 'date')
    def _compute_display_name(self):
        for expense in self:
            expense.display_name = '%s · %s · %s' % (expense.category_id.name or '', expense.user_id.name or '', expense.date or '')

    @api.constrains('amount')
    def _check_amount(self):
        if any(expense.amount <= 0 for expense in self):
            raise UserError(self.env._("An expense must be more than zero."))

    def _check_supervisor(self):
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("Only a BeatPro supervisor can approve expenses."))

    def _journals(self):
        """The rep's field cash journal, and a miscellaneous journal for the rest."""
        self.ensure_one()
        company = self.company_id
        cash = company._beatpro_field_cash_journal()
        misc = self.env['account.journal'].sudo().search([
            *self.env['account.journal']._check_company_domain(company), ('type', '=', 'general')], limit=1)
        return cash, misc

    def _credit_account(self):
        self.ensure_one()
        company = self.company_id
        if self.paid_from == 'cash':
            return company._beatpro_field_cash_journal().default_account_id
        if self.paid_from == 'card':
            if not company.beatpro_card_journal_id:
                raise UserError(self.env._("Choose the company card's journal in BeatPro settings before approving card expenses."))
            return company.beatpro_card_journal_id.default_account_id
        return company._beatpro_reimburse_account()

    def action_approve(self):
        self._check_supervisor()
        for expense in self.filtered(lambda e: e.state == 'waiting'):
            cash, misc = expense._journals()
            journal = cash if expense.paid_from == 'cash' else misc
            partner = expense.user_id.partner_id
            label = '%s · %s%s' % (expense.category_id.name, expense.user_id.name, (' · ' + expense.note) if expense.note else '')
            move = self.env['account.move'].sudo().with_company(expense.company_id).create({
                'move_type': 'entry',
                'journal_id': journal.id,
                'date': expense.date,
                'ref': self.env._("Rep expense: %s", label),
                'line_ids': [
                    Command.create({'name': label, 'account_id': expense.category_id._beatpro_account(expense.company_id).id,
                                    'debit': expense.amount, 'partner_id': partner.id}),
                    Command.create({'name': label, 'account_id': expense._credit_account().id,
                                    'credit': expense.amount, 'partner_id': partner.id}),
                ],
            })
            move.action_post()
            expense.write({'state': 'approved', 'move_id': move.id})
        return True

    def action_reject(self):
        self._check_supervisor()
        for expense in self.filtered(lambda e: e.state == 'waiting'):
            expense.write({'state': 'rejected', 'reject_reason': self.env.context.get('reject_reason') or expense.reject_reason})
            if expense.paid_from == 'cash':
                expense.message_post(body=self.env._(
                    "Rejected, but paid from cash collected: the money is missing from the hand over and "
                    "shows as a shortage for the supervisor."))
                close = self.env['beatpro.day.close'].sudo().search([
                    ('user_id', '=', expense.user_id.id), ('date', '=', expense.date),
                    ('company_id', '=', expense.company_id.id)], limit=1)
                close._beatpro_expense_rejected(expense)
        return True

    # -- For the app ----------------------------------------------------------------

    @api.model
    def beatpro_submit_expenses(self, vals_list):
        """Expenses recorded on the rep's phone. Expenses already received are left as they are.

        :return: ``{mobile_uuid: {'id', 'state'}}``
        """
        for vals in vals_list:
            vals['user_id'] = self.env.uid
            vals.pop('state', None)
        ids = self.beatpro_upsert(vals_list)
        expenses = self.browse(list(ids.values()))
        return {e.mobile_uuid: {'id': e.id, 'state': e.state} for e in expenses}

    @api.model
    def beatpro_my_expenses(self):
        """The rep's expenses this month and last, newest first, for the app."""
        first = fields.Date.context_today(self).replace(day=1)
        start = first - relativedelta(months=1)
        expenses = self.search([('user_id', '=', self.env.uid), ('date', '>=', start)])
        return [{
            'id': e.id,
            'mobile_uuid': e.mobile_uuid or False,
            'date': fields.Date.to_string(e.date),
            'category': e.category_id.name,
            'category_id': e.category_id.id,
            'amount': e.amount,
            'paid_from': e.paid_from,
            'note': e.note or False,
            'state': e.state,
            'reject_reason': e.reject_reason or False,
        } for e in expenses]

    @api.model
    def beatpro_expense_categories(self):
        return [{'id': c.id, 'name': c.name} for c in self.env['beatpro.expense.category'].search([])]


class ResCompany(models.Model):
    _inherit = 'res.company'

    beatpro_field_cash_journal_id = fields.Many2one(
        'account.journal', string="Reps' Field Cash", domain="[('type', '=', 'cash')]",
        help="The cash journal reps collect cash into. Expenses paid from collected cash and "
             "differences at the hand over are booked in it.")
    beatpro_card_journal_id = fields.Many2one(
        'account.journal', string="Company Card", domain="[('type', 'in', ('bank', 'credit'))]",
        help="The journal of the company card reps pay fuel and tolls with.")
    beatpro_reimburse_account_id = fields.Many2one(
        'account.account', string="Owed to Reps",
        help="What the company owes reps for expenses they paid with their own money.")

    def _beatpro_field_cash_journal(self):
        self.ensure_one()
        journal = self.beatpro_field_cash_journal_id
        if not journal:
            cash_lines = self._beatpro_payment_methods().filtered(lambda l: l.journal_id.type == 'cash')
            journal = cash_lines[:1].journal_id or self.env['account.journal'].sudo().search([
                *self.env['account.journal']._check_company_domain(self), ('type', '=', 'cash')], limit=1)
        if not journal:
            raise UserError(self.env._("Set up a cash journal for the reps' field cash."))
        return journal

    def _beatpro_reimburse_account(self):
        """The account for expenses paid with reps' own money, created the first time it is needed."""
        self.ensure_one()
        company = self.sudo()
        if not company.beatpro_reimburse_account_id:
            Account = self.env['account.account'].sudo()
            code = '201099'
            while Account.search_count([*Account._check_company_domain(company), ('code', '=', code)]):
                code = str(int(code) + 1)
            company.beatpro_reimburse_account_id = Account.with_company(company).create({
                'name': self.env._("Rep expense reimbursements"),
                'code': code,
                'account_type': 'liability_current',
                'reconcile': True,
                'company_ids': [Command.set(company.ids)],
            })
        return company.beatpro_reimburse_account_id
