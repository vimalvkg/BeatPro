from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    beatpro_van_invoice = fields.Boolean(related='company_id.beatpro_van_invoice', readonly=False)
    beatpro_slip_width = fields.Selection(related='company_id.beatpro_slip_width', readonly=False)
    beatpro_field_cash_journal_id = fields.Many2one(related='company_id.beatpro_field_cash_journal_id', readonly=False)
    beatpro_card_journal_id = fields.Many2one(related='company_id.beatpro_card_journal_id', readonly=False)
    beatpro_reimburse_account_id = fields.Many2one(related='company_id.beatpro_reimburse_account_id', readonly=False)
    beatpro_statement_note = fields.Text(related='company_id.beatpro_statement_note', readonly=False)
    beatpro_lost_days = fields.Integer(related='company_id.beatpro_lost_days', readonly=False)
    beatpro_expiry_days = fields.Integer(related='company_id.beatpro_expiry_days', readonly=False)
    beatpro_not_moving_days = fields.Integer(related='company_id.beatpro_not_moving_days', readonly=False)
    beatpro_alert_unload_diff = fields.Monetary(related='company_id.beatpro_alert_unload_diff', readonly=False,
                                                currency_field='beatpro_currency_id')
    beatpro_currency_id = fields.Many2one(related='company_id.currency_id', string="BeatPro Currency")
    beatpro_alert_load_wait = fields.Integer(related='company_id.beatpro_alert_load_wait', readonly=False)
    beatpro_fefo = fields.Boolean(related='company_id.beatpro_fefo', readonly=False)

    def set_values(self):
        super().set_values()
        self.env['stock.warehouse']._beatpro_apply_fefo()
