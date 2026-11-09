from datetime import datetime, time, timedelta

import pytz

from odoo import api, fields, models
from odoo.exceptions import AccessError


class BeatproLocation(models.Model):
    _name = 'beatpro.location'
    _description = "Rep Location"
    _order = 'at desc, id desc'

    user_id = fields.Many2one('res.users', required=True, index=True, ondelete='cascade')
    at = fields.Datetime(required=True, index=True)
    latitude = fields.Float(digits=(10, 7), required=True)
    longitude = fields.Float(digits=(10, 7), required=True)
    accuracy = fields.Float(help="In metres, as the phone reported it.")
    mobile_uuid = fields.Char(index=True)

    _mobile_uuid_unique = models.UniqueIndex('(mobile_uuid) WHERE mobile_uuid IS NOT NULL',
                                             "This location was already received.")

    @api.model
    def beatpro_submit_locations(self, points):
        """Positions the rep's phone recorded while working.

        Each point: ``mobile_uuid``, ``at`` (UTC), ``latitude``, ``longitude``, ``accuracy``.
        Ignored when location sharing is off for the rep.

        :return: how many points Odoo now has from this call
        """
        user = self.env.user
        if not user.beatpro_track_location or not points:
            return 0
        Location = self.sudo()
        have = set(Location.search([('mobile_uuid', 'in', [p['mobile_uuid'] for p in points])]).mapped('mobile_uuid'))
        Location.create([{
            'user_id': user.id,
            'at': p['at'],
            'latitude': p['latitude'],
            'longitude': p['longitude'],
            'accuracy': p.get('accuracy') or 0.0,
            'mobile_uuid': p['mobile_uuid'],
        } for p in points if p['mobile_uuid'] not in have])
        return len(points)

    @api.autovacuum
    def _gc_old_locations(self):
        """Keep three months of positions."""
        self.sudo().search([('at', '<', fields.Datetime.now() - timedelta(days=90))]).unlink()

    @api.model
    def _today_bounds(self, user):
        tz = pytz.timezone(user.tz or self.env.user.tz or 'UTC')
        today = datetime.now(tz).date()
        start = tz.localize(datetime.combine(today, time.min)).astimezone(pytz.utc).replace(tzinfo=None)
        return today, start, start + timedelta(days=1)

    @api.model
    def beatpro_live_map(self):
        """The supervisor's Live Map: where each rep is and how today's route is going."""
        if not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
            raise AccessError(self.env._("The Live Map is for BeatPro supervisors."))
        company = self.env.company
        reps = self.env['res.users'].sudo().search([
            ('all_group_ids', 'in', self.env.ref('beatpro_field_sales.group_beatpro_rep').id),
            ('company_ids', 'in', company.id), ('share', '=', False),
        ]).filtered(lambda u: not u.has_group('beatpro_field_sales.group_beatpro_supervisor'))
        now = fields.Datetime.now()
        result = []
        for rep in reps.sorted('name'):
            today, start, end = self._today_bounds(rep)
            points = self.sudo().search([('user_id', '=', rep.id), ('at', '>=', start), ('at', '<', end)], order='at')
            weekday = str(today.weekday())
            routes = self.env['beatpro.route'].sudo().search([
                ('user_id', '=', rep.id), '|', ('weekday', '=', weekday), ('weekday', '=', False)])
            visits = self.env['beatpro.visit'].sudo().search([
                ('user_id', '=', rep.id), ('check_in', '>=', start), ('check_in', '<', end)])
            visited = {v.partner_id.id: v for v in visits}
            closed = self.env['beatpro.day.close'].sudo().search(
                [('user_id', '=', rep.id), ('date', '=', today)], limit=1)
            moved_out, _moved_in, skipped = self.env['beatpro.route']._beatpro_moves_for(rep, today)
            lines = routes.line_ids.filtered(lambda l: l.partner_id not in moved_out.partner_id)
            last_done = max([i for i, line in enumerate(lines) if line.partner_id.id in visited], default=-1)
            stops, next_given = [], False
            for i, line in enumerate(lines):
                partner = line.partner_id
                if partner.id in visited:
                    status = 'visited'
                elif partner in skipped.partner_id:
                    status = 'skipped'
                elif closed or i < last_done:
                    status = 'missed'
                elif not next_given:
                    status, next_given = 'next', True
                else:
                    status = 'later'
                stops.append({
                    'name': partner.display_name,
                    'lat': partner.partner_latitude or False,
                    'lng': partner.partner_longitude or False,
                    'status': status,
                })
            last = points[-1:] or None
            seen_minutes = int((now - last.at).total_seconds() // 60) if last else None
            in_visit = visits.filtered(lambda v: v.state == 'in_progress')[:1]
            if closed:
                where = self.env._("Day closed %s", fields.Datetime.context_timestamp(self, closed.create_date).strftime('%H:%M'))
            elif last is None:
                where = self.env._("No location today")
            else:
                ago = self.env._("just now") if seen_minutes < 1 else self.env._("%s min ago", seen_minutes)
                doing = self.env._("at %s", in_visit.partner_id.display_name) if in_visit else (
                    self.env._("no signal") if seen_minutes > 20 else self.env._("on the road"))
                where = self.env._("Seen %(ago)s · %(doing)s", ago=ago, doing=doing)
            done = sum(1 for s in stops if s['status'] == 'visited')
            missed = sum(1 for s in stops if s['status'] == 'missed')
            result.append({
                'user_id': rep.id,
                'name': rep.name,
                'initials': ''.join(w[0] for w in rep.name.split()[:2]).upper(),
                'tracking': rep.beatpro_track_location,
                'where': where,
                'stale': bool(last and seen_minutes > 20 and not closed),
                'progress': self.env._("%(done)s of %(all)s shops", done=done, all=len(stops)) + (
                    self.env._(" · %s missed", missed) if missed else ''),
                'last': last and {'lat': last.latitude, 'lng': last.longitude} or False,
                'trail': [[p.latitude, p.longitude] for p in points],
                'stops': stops,
            })
        return {'reps': result}
