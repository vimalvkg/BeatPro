from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    beatpro_cash_journal_id = fields.Many2one(
        related='company_id.beatpro_cash_journal_id', readonly=False)
    beatpro_bank_journal_id = fields.Many2one(
        related='company_id.beatpro_bank_journal_id', readonly=False)
