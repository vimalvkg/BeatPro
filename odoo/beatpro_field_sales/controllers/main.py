import logging
from datetime import datetime, timedelta

from odoo import api, http, SUPERUSER_ID
from odoo.exceptions import AccessDenied
from odoo.http import request
from odoo.modules.registry import Registry

_logger = logging.getLogger(__name__)

KEY_DAYS_PARAM = 'beatpro_field_sales.app_key_days'
DEFAULT_KEY_DAYS = 365


class BeatproAppLogin(http.Controller):

    @http.route('/beatpro/app/login', type='jsonrpc', auth='none', methods=['POST'], csrf=False, readonly=False)
    def app_login(self, login, password, db=None, device=None, **kw):
        """Sign the BeatPro app in with the rep's Odoo login and password.

        The password is checked like on Odoo's sign-in page (with its protection against
        repeated attempts) and never stored. The phone gets an API key of its own for
        Odoo's JSON-2 API: one per phone, named after it, which the user or an
        administrator can revoke from the user's profile (Security tab).

        :return: ``{'api_key', 'database', 'expires'}`` or ``{'error': message}``
        """
        dbname = db or request.db
        if not dbname:
            dbs = http.db_list(force=True)
            if len(dbs) != 1:
                return {'error': "This Odoo server has several databases. Enter the database name."}
            dbname = dbs[0]
        if dbname not in http.db_list(force=True):
            return {'error': "There is no database called %s on this server." % dbname}

        registry = Registry(dbname)
        with registry.cursor() as cr:
            env = api.Environment(cr, SUPERUSER_ID, {})
            try:
                auth = env['res.users'].authenticate(
                    {'type': 'password', 'login': login, 'password': password},
                    {'interactive': False},
                )
            except AccessDenied as e:
                message = e.args[0] if e.args and e.args[0] != 'Access Denied' else None
                return {'error': message or "Wrong login or password."}
            user = env['res.users'].browse(auth['uid'])
            if user._mfa_type():
                return {'error': "Your account uses two-step sign-in. Sign in with an API key instead."}
            if not user._is_internal() or not user.has_group('beatpro_field_sales.group_beatpro_rep'):
                return {'error': "This user is not a BeatPro rep. Ask your administrator to add you to "
                                 "the BeatPro Field Sales group."}

            days = int(env['ir.config_parameter'].get_param(KEY_DAYS_PARAM, DEFAULT_KEY_DAYS) or DEFAULT_KEY_DAYS)
            expires = datetime.now() + timedelta(days=days)
            name = "BeatPro app · %s" % (device or "phone")[:60]
            Keys = env(user=user.id, su=True)['res.users.apikeys']
            # Signing in again on the same phone replaces its key.
            Keys.search([('user_id', '=', user.id), ('name', '=', name)])._remove()
            key = Keys._generate('rpc', name, expires)
            _logger.info("BeatPro app signed in for %s (%s)", user.login, name)
            return {'api_key': key, 'database': dbname, 'expires': expires.date().isoformat()}
