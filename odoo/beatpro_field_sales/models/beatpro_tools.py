from datetime import datetime, time, timedelta

import pytz


def day_bounds_utc(day, tz_name):
    """Start and end of ``day`` in the time zone ``tz_name``, as naive UTC datetimes."""
    tz = pytz.timezone(tz_name or 'UTC')
    start = tz.localize(datetime.combine(day, time.min)).astimezone(pytz.utc)
    end = tz.localize(datetime.combine(day, time.max)).astimezone(pytz.utc)
    return start.replace(tzinfo=None), end.replace(tzinfo=None)


def period_bounds_utc(today, period, tz_name):
    """Start and end of today, this week (from Monday) or this month, as naive UTC."""
    if period == 'week':
        first = today - timedelta(days=today.weekday())
    elif period == 'month':
        first = today.replace(day=1)
    else:
        first = today
    start, _ = day_bounds_utc(first, tz_name)
    _, end = day_bounds_utc(today, tz_name)
    return start, end


def money(env, amount):
    """An amount in the company currency, formatted for display."""
    return env.company.currency_id.format(amount or 0.0)


def initials(name):
    parts = [p for p in (name or '').split() if p]
    return ''.join(p[0] for p in parts[:2]).upper() or '?'
