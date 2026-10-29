from odoo import api, fields, models
from odoo.exceptions import UserError


class BeatproMobileMixin(models.AbstractModel):
    """Lets the mobile app upload records made offline without creating duplicates.

    Every record made on the phone carries a ``mobile_uuid``. When a sync is
    retried after a dropped connection, ``beatpro_upsert`` returns the record
    already received instead of creating a second one.
    """
    _name = 'beatpro.mobile.mixin'
    _description = 'BeatPro Mobile Sync Mixin'

    mobile_uuid = fields.Char(
        string="Mobile ID", copy=False, index=True, readonly=True,
        help="Unique ID given by the BeatPro app to a record made on the phone.")

    _mobile_uuid_unique = models.UniqueIndex(
        '(mobile_uuid) WHERE mobile_uuid IS NOT NULL',
        "A record with this mobile ID already exists.")

    @api.model
    def beatpro_upsert(self, vals_list):
        """Create the records sent by the app, skipping any already received.

        :param list vals_list: values for each record; each must have ``mobile_uuid``
        :return: ``{mobile_uuid: record id}`` for every record in ``vals_list``
        """
        uuids = [vals.get('mobile_uuid') for vals in vals_list]
        if not all(uuids):
            raise UserError(self.env._("Every record sent by the app needs a mobile ID."))

        # Look up as superuser so a retry finds the first copy even if a record
        # rule hides it; only the id is returned.
        existing = self.sudo().with_context(active_test=False).search([('mobile_uuid', 'in', uuids)])
        result = {record.mobile_uuid: record.id for record in existing}

        to_create = []
        for vals in vals_list:
            if vals['mobile_uuid'] not in result:
                result[vals['mobile_uuid']] = None
                to_create.append(vals)
        for record in self.create(to_create):
            result[record.mobile_uuid] = record.id
        return result
