

from odoo import api, fields, models
from odoo.exceptions import AccessError, UserError

QUESTION_KINDS = [
    ('yes_no', "Yes or no"),
    ('number', "Number"),
    ('price', "Price"),
    ('choice', "One of a list"),
    ('text', "Text"),
]
PHOTO_TAGS = ["Main shelf", "Display stand", "Competitor", "Out of stock", "Price label"]


class BeatproSurvey(models.Model):
    _name = 'beatpro.survey'
    _description = "Shop Survey"
    _order = 'sequence, name'

    name = fields.Char(required=True, translate=True)
    active = fields.Boolean(default=True)
    sequence = fields.Integer(default=10)
    company_id = fields.Many2one('res.company', required=True, default=lambda self: self.env.company)
    frequency = fields.Selection([
        ('visit', "Every visit"),
        ('month', "Once a month per shop"),
    ], required=True, default='month', help="How often a rep fills it in at the same shop.")
    question_ids = fields.One2many('beatpro.survey.question', 'survey_id', string="Questions", copy=True)
    photo_ids = fields.One2many('beatpro.survey.photo', 'survey_id', string="Photos Needed", copy=True)
    user_ids = fields.Many2many('res.users', 'beatpro_survey_user_rel', 'survey_id', 'user_id', string="Reps",
                                domain="[('share', '=', False)]")
    route_ids = fields.Many2many('beatpro.route', string="Routes",
                                 help="Asked at every shop of these routes, whoever visits them.")
    answer_count = fields.Integer(compute='_compute_answer_count')

    def _compute_answer_count(self):
        groups = self.env['beatpro.survey.answer']._read_group(
            [('survey_id', 'in', self.ids)], ['survey_id'], ['visit_id:count_distinct'])
        counts = {survey.id: n for survey, n in groups}
        for survey in self:
            survey.answer_count = counts.get(survey.id, 0)

    def action_view_answers(self):
        self.ensure_one()
        action = self.env['ir.actions.act_window']._for_xml_id('beatpro_field_sales.action_beatpro_survey_answer')
        action['domain'] = [('survey_id', '=', self.id)]
        return action

    @api.model
    def _beatpro_for(self, user, partners, routes):
        """Surveys due at each shop: ``{partner id: surveys}``."""
        surveys = self.sudo().search([('company_id', '=', self.env.company.id), '|',
                                      ('user_ids', 'in', user.ids), ('route_ids', 'in', routes.ids)])
        if not surveys:
            return {}
        first = fields.Date.context_today(self).replace(day=1)
        done = self.env['beatpro.survey.answer'].sudo()._read_group([
            ('survey_id', 'in', surveys.filtered(lambda s: s.frequency == 'month').ids),
            ('partner_id', 'in', partners.ids), ('date', '>=', first),
        ], ['survey_id', 'partner_id'])
        done = {(survey.id, partner.id) for survey, partner in done}
        result = {}
        for partner in partners:
            due = surveys.filtered(lambda s: (s.user_ids & user) or (s.route_ids & routes.filtered(
                lambda r: partner in r.line_ids.partner_id)))
            due = due.filtered(lambda s: (s.id, partner.id) not in done)
            if due:
                result[partner.id] = due
        return result

    def _beatpro_as_dict(self):
        return [{
            'id': survey.id,
            'name': survey.name,
            'frequency': survey.frequency,
            'questions': [{
                'id': q.id,
                'name': q.name,
                'kind': q.kind,
                'choices': [c.strip() for c in (q.choices or '').split(',') if c.strip()],
                'suffix': q.suffix or '',
                'required': q.required,
            } for q in survey.question_ids],
            'photos': [{'tag': p.tag, 'count': p.count} for p in survey.photo_ids],
        } for survey in self]

    @api.model
    def beatpro_surveys(self):
        """Surveys for the signed-in rep, and which are due at each shop on today's plan."""
        user = self.env.user
        weekday = str(fields.Date.context_today(self).weekday())
        routes = self.env['beatpro.route'].sudo().search([
            ('user_id', '=', user.id), '|', ('weekday', '=', weekday), ('weekday', '=', False)])
        due = self._beatpro_for(user, routes.line_ids.partner_id, routes)
        surveys = self.browse()
        for found in due.values():
            surveys |= found
        return {
            'surveys': surveys._beatpro_as_dict(),
            'due': {str(pid): found.ids for pid, found in due.items()},
            'photo_tags': PHOTO_TAGS,
        }


class BeatproSurveyQuestion(models.Model):
    _name = 'beatpro.survey.question'
    _description = "Shop Survey Question"
    _order = 'sequence, id'

    survey_id = fields.Many2one('beatpro.survey', required=True, ondelete='cascade', index=True)
    sequence = fields.Integer(default=10)
    name = fields.Char(string="Question", required=True, translate=True)
    kind = fields.Selection(QUESTION_KINDS, required=True, default='yes_no')
    choices = fields.Char(help="For \"One of a list\": the answers, separated by commas.")
    suffix = fields.Char(string="Unit", help="Shown after a number, e.g. \"facings\" or \"per piece\".")
    required = fields.Boolean(default=True)


class BeatproSurveyPhoto(models.Model):
    _name = 'beatpro.survey.photo'
    _description = "Shop Survey Photo Needed"

    survey_id = fields.Many2one('beatpro.survey', required=True, ondelete='cascade', index=True)
    tag = fields.Char(string="Photo Of", required=True, default="Main shelf")
    count = fields.Integer(string="How Many", default=1, required=True)


class BeatproVisitPhoto(models.Model):
    _name = 'beatpro.visit.photo'
    _description = "Visit Photo"
    _order = 'taken_at, id'

    visit_id = fields.Many2one('beatpro.visit', required=True, ondelete='cascade', index=True)
    partner_id = fields.Many2one(related='visit_id.partner_id', store=True)
    user_id = fields.Many2one(related='visit_id.user_id', store=True)
    mobile_uuid = fields.Char(index=True, copy=False)
    image = fields.Image(max_width=1600, max_height=1600, required=True)
    tag = fields.Char(string="Photo Of")
    taken_at = fields.Datetime(default=fields.Datetime.now)
    latitude = fields.Float(digits=(10, 7))
    longitude = fields.Float(digits=(10, 7))

    _mobile_uuid_unique = models.UniqueIndex('(mobile_uuid) WHERE mobile_uuid IS NOT NULL',
                                             "This photo was already received.")


class BeatproSurveyAnswer(models.Model):
    _name = 'beatpro.survey.answer'
    _description = "Shop Survey Answer"
    _order = 'date desc, visit_id, sequence'

    visit_id = fields.Many2one('beatpro.visit', required=True, ondelete='cascade', index=True)
    survey_id = fields.Many2one('beatpro.survey', required=True, index=True, ondelete='cascade')
    question_id = fields.Many2one('beatpro.survey.question', required=True, ondelete='cascade')
    sequence = fields.Integer(related='question_id.sequence', store=True)
    kind = fields.Selection(related='question_id.kind')
    partner_id = fields.Many2one(related='visit_id.partner_id', store=True, string="Shop")
    user_id = fields.Many2one(related='visit_id.user_id', store=True, string="Rep")
    date = fields.Date(compute='_compute_date', store=True)
    value = fields.Char(string="Answer")
    value_number = fields.Float(string="Number", help="The answer as a number, for numbers and prices.")

    @api.depends('visit_id.check_in', 'visit_id.create_date')
    def _compute_date(self):
        for answer in self:
            when = answer.visit_id.check_in or answer.visit_id.create_date or fields.Datetime.now()
            answer.date = fields.Date.context_today(answer, when)


class BeatproVisit(models.Model):
    _inherit = 'beatpro.visit'

    photo_ids = fields.One2many('beatpro.visit.photo', 'visit_id', string="Photos")
    answer_ids = fields.One2many('beatpro.survey.answer', 'visit_id', string="Survey Answers")
    photo_count = fields.Integer(compute='_compute_photo_count')

    def _compute_photo_count(self):
        groups = self.env['beatpro.visit.photo']._read_group([('visit_id', 'in', self.ids)], ['visit_id'], ['__count'])
        counts = {visit.id: n for visit, n in groups}
        for visit in self:
            visit.photo_count = counts.get(visit.id, 0)

    @api.model
    def beatpro_submit_extras(self, vals_list):
        """Photos and survey answers taken during visits, sent by the app.

        Each dict: ``visit_id``, ``photos`` (``mobile_uuid``, ``image`` base64, ``tag``,
        ``taken_at``, ``latitude``, ``longitude``) and ``answers`` (``survey_id``,
        ``question_id``, ``value``). Photos already received are skipped; a visit's
        answers to a survey replace earlier ones.

        :return: the mobile_uuids of the photos Odoo now has
        """
        received = []
        Photo = self.env['beatpro.visit.photo'].sudo()
        Answer = self.env['beatpro.survey.answer'].sudo()
        for vals in vals_list:
            visit = self.browse(vals['visit_id']).exists()
            if not visit:
                raise UserError(self.env._("This visit is not in Odoo."))
            visit.check_access('write')
            if visit.user_id != self.env.user and not self.env.user.has_group('beatpro_field_sales.group_beatpro_supervisor'):
                raise AccessError(self.env._("You can only add photos to your own visits."))
            photos = vals.get('photos') or []
            have = set(Photo.search([('mobile_uuid', 'in', [p['mobile_uuid'] for p in photos])]).mapped('mobile_uuid'))
            for p in photos:
                if p['mobile_uuid'] not in have:
                    Photo.create({
                        'visit_id': visit.id,
                        'mobile_uuid': p['mobile_uuid'],
                        'image': p['image'],
                        'tag': p.get('tag') or False,
                        'taken_at': p.get('taken_at') or fields.Datetime.now(),
                        'latitude': p.get('latitude') or 0.0,
                        'longitude': p.get('longitude') or 0.0,
                    })
                received.append(p['mobile_uuid'])
            answers = vals.get('answers') or []
            for survey_id in {a['survey_id'] for a in answers}:
                Answer.search([('visit_id', '=', visit.id), ('survey_id', '=', survey_id)]).unlink()
            for a in answers:
                question = self.env['beatpro.survey.question'].sudo().browse(a['question_id']).exists()
                if not question or question.survey_id.id != a['survey_id']:
                    continue
                value = a.get('value')
                number = 0.0
                if question.kind in ('number', 'price'):
                    try:
                        number = float(value)
                    except (TypeError, ValueError):
                        number = 0.0
                Answer.create({
                    'visit_id': visit.id,
                    'survey_id': question.survey_id.id,
                    'question_id': question.id,
                    'value': {True: self.env._("Yes"), False: self.env._("No")}.get(value, value) if question.kind == 'yes_no' else (
                        str(value) if value not in (None, False) else False),
                    'value_number': number,
                })
        return received
