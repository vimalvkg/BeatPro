# BeatPro Theme (Odoo 19 Community)

The BeatPro Van Sales look for every Odoo screen. Install it after `beatpro_field_sales`.

- **Colours**: maroon BeatPro colours on every backend screen: buttons, status bars, list
  headers, tabs, badges, links. Forms and lists keep Odoo's layout and behaviour.
- **Side menu** on the left with the screens a van sales team opens every day: Dashboard,
  Sales Orders, Customers, Routes, Vans, Products, Returns, Invoices, Reports, Settings. Each
  user sees only what they can open: reps get My Day and My Van, supervisors the Van Sales
  Dashboard and the storekeeper's Vans page, accountants Invoices, admins Settings. The menu
  folds to icons (the arrow at the bottom) and is hidden on phones, where Odoo's own menu is used.
- **Van Sales Dashboard** (BeatPro > Van Sales Dashboard): total sales, orders, active shops and
  collections against the previous period, sales and orders by day, week or month, sales by
  product category, top shops, sales by route, collected against still due, and recent
  activity. Filter by period and route.
- **Sign-in page** in BeatPro colours. The company's logo is shown; companies without one get
  the BeatPro logo.
- **Odoo's name removed** from the browser tab and icon, the installed app name, the sign-in
  page, the user menu (Documentation, Support, odoo.com account), dialogs, the portal and the
  footer of emails.

The van drawing is BeatPro's own artwork (`static/img/van.svg`). The Manrope typeface comes from
`beatpro_field_sales` (SIL Open Font License).

## Change the name or colours

- Colours: `static/src/scss/primary_variables.scss` (Odoo's own colour settings) and the
  `$bp-*` values at the top of `static/src/scss/theme.scss`.
- Name and logo: `static/img/` (logo, favicon, van) and the `brand` returned by
  `beatpro.theme.beatpro_sidebar` in `models/beatpro_theme.py`; the app name is the
  `web.web_app_name` system parameter.

## Run the tests

    odoo-bin -d <db> -i beatpro_theme --test-tags /beatpro_theme --stop-after-init
