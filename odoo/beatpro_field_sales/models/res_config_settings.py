from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    beatpro_van_invoice = fields.Boolean(related='company_id.beatpro_van_invoice', readonly=False)
    beatpro_slip_width = fields.Selection(related='company_id.beatpro_slip_width', readonly=False)
    beatpro_field_cash_journal_id = fields.Many2one(related='company_id.beatpro_field_cash_journal_id', readonly=False)
    beatpro_card_journal_id = fields.Many2one(related='company_id.beatpro_card_journal_id', readonly=False)
    beatpro_reimburse_account_id = fields.Many2one(related='company_id.beatpro_reimburse_account_id', readonly=False)
