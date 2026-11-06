from odoo import api, models


class ResUsers(models.Model):
    _inherit = 'res.users'

    @api.model
    def beatpro_app_context(self):
        """Tell the app that this server has the Van Sales Dashboard and whether the user may open it."""
        context = super().beatpro_app_context()
        context['sales_dashboard'] = any(
            self.env.user.has_group(group) for group in (
                'beatpro_field_sales.group_beatpro_supervisor', 'sales_team.group_sale_salesman_all_leads'))
        return context
