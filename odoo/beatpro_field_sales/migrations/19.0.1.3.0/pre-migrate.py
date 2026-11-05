"""Payment methods now come from the company's journals instead of a fixed cash,
cheque and UPI list: keep what reps already recorded."""


def _column_exists(cr, table, column):
    cr.execute("SELECT 1 FROM information_schema.columns WHERE table_name = %s AND column_name = %s", (table, column))
    return bool(cr.fetchone())


def migrate(cr, version):
    if _column_exists(cr, 'account_payment', 'beatpro_upi_reference') and \
            not _column_exists(cr, 'account_payment', 'beatpro_reference'):
        cr.execute("ALTER TABLE account_payment RENAME COLUMN beatpro_upi_reference TO beatpro_reference")
    if _column_exists(cr, 'account_payment', 'beatpro_method'):
        cr.execute("UPDATE account_payment SET beatpro_method = 'bank' WHERE beatpro_method = 'upi'")
    if _column_exists(cr, 'beatpro_day_close', 'upi_amount') and \
            not _column_exists(cr, 'beatpro_day_close', 'bank_amount'):
        cr.execute("ALTER TABLE beatpro_day_close RENAME COLUMN upi_amount TO bank_amount")
