import base64
import io

from odoo import http
from odoo.http import request, Response
from odoo.tools import file_path
from odoo.tools.mimetypes import guess_mimetype

from odoo.addons.web.controllers.binary import Binary, send_file

LOGO = 'beatpro_theme/static/img/logo_full.png'


class BeatproBinary(Binary):

    @http.route(['/web/binary/company_logo', '/logo', '/logo.png'], type='http', auth="none", cors="*")
    def company_logo(self, dbname=None, **kw):
        """The company's own logo, or the BeatPro logo when it still has Odoo's default one."""
        if not request.db:
            return http.Stream.from_path(file_path(LOGO)).get_response()
        uid = request.session.uid or 1
        company = int(kw['company']) if kw.get('company', '').isdigit() else False
        if company:
            request.env.cr.execute("SELECT logo_web, write_date, uses_default_logo FROM res_company WHERE id = %s", (company,))
        else:
            request.env.cr.execute("""
                SELECT c.logo_web, c.write_date, c.uses_default_logo
                  FROM res_users u
             LEFT JOIN res_company c ON c.id = u.company_id
                 WHERE u.id = %s
            """, (uid,))
        row = request.env.cr.fetchone()
        if not (row and row[0]) or row[2]:
            return http.Stream.from_path(file_path(LOGO)).get_response()
        image = base64.b64decode(row[0])
        mimetype = guess_mimetype(image, default='image/png')
        ext = '.svg' if mimetype == 'image/svg+xml' else '.' + mimetype.split('/')[1]
        return send_file(io.BytesIO(image), request.httprequest.environ, download_name='logo' + ext,
                              mimetype=mimetype, last_modified=row[1], response_class=Response)
