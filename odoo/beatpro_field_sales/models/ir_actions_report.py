from odoo import models

SLIP_REPORTS = {
    'beatpro_field_sales.report_invoice_slip_80': '80',
    'beatpro_field_sales.report_invoice_slip_58': '58',
}


class IrActionsReport(models.Model):
    _inherit = 'ir.actions.report'

    def _render_qweb_pdf(self, report_ref, res_ids=None, data=None):
        report = self._get_report(report_ref)
        width = SLIP_REPORTS.get(report.report_name)
        if width and res_ids:
            invoices = self.env['account.move'].browse(res_ids)
            height = self.env['account.move']._beatpro_slip_height_mm(invoices, width)
            self = self.with_context(beatpro_slip_height_mm=height)
        return super(IrActionsReport, self)._render_qweb_pdf(report_ref, res_ids=res_ids, data=data)

    def _build_wkhtmltopdf_args(self, paperformat_id, landscape, specific_paperformat_args=None,
                                set_viewport_size=False):
        args = super()._build_wkhtmltopdf_args(
            paperformat_id, landscape, specific_paperformat_args=specific_paperformat_args,
            set_viewport_size=set_viewport_size)
        height = self.env.context.get('beatpro_slip_height_mm')
        if height and '--page-height' in args:
            # A receipt is as long as its content.
            args[args.index('--page-height') + 1] = '%smm' % height
        return args
