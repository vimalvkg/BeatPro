# BeatPro Field Sales (Odoo 19 Community)

Field sales for Odoo 19 Community. Reps can work in either of two ways, and both write to the
same records:

- **In the Odoo web client** (desktop or a phone browser), with no app needed.
- **In the BeatPro mobile app**, which works offline and syncs through Odoo's JSON-2 API.

Only standard Community modules are needed (`sale_stock`, `account`).

## Working in the Odoo web client

Menu **BeatPro**:

| Menu | Who | What it does |
| --- | --- | --- |
| Overview | Supervisors | Today's, this week's or this month's visits, order value, collections by method, every rep's progress, discounts to approve in one click and why shops didn't order |
| My Day | Reps | Progress ring with the day's orders and collections, the next shop with Start visit, directions and call, and the route with each shop's status |
| Visits | Reps | The visit panel: **Check in** and **Check out** record the browser's GPS position and show the distance from the shop pin; a live timer; **Take order** and **Collect payment** tiles; the customer's amount due, last and usual order; everything done during the visit. Check-out asks for the result, the no-order reason and a note. |
| Orders | Reps | Orders taken during visits or sent from the app |
| Day-End Closes | Reps | The cash and cheques to hand in, UPI already in the bank, visits and orders, and a list of the day's visits; closing locks the day |
| Routes | Supervisors (reps read only) | A board of routes by weekday, with each route's rep, shops and how often its visits end with an order |
| Supervisor > Discount Approvals | Supervisors | Orders whose discount is above the rep's limit |
| Supervisor > Visit Analysis | Supervisors | Visits by rep and result |
| Supervisor > Settings | Admins | Cash and bank journals for field collections |

A rep whose discount is above their limit can't confirm the order; they click **Request
Approval** and a supervisor clicks **Approve Discount**.

Customers get a **Field Sales** tab (routes, last visit, GPS position) and a Visits button.

The BeatPro screens use the Manrope typeface (SIL Open Font License, `static/src/fonts/OFL.txt`).

## Access groups

Under **Settings > Users > BeatPro Field Sales**:

- **Rep: Own Routes Only** sees only their own routes, visits, day-end closes and collections.
  Reps can add customers and record collections without accounting rights.
- **Supervisor** manages routes, sees every rep's records, approves discounts and reopens closed days.

Set each rep's discount limit and van warehouse on the **BeatPro** tab of their user.

## Field collections

Cash goes to the cash journal and cheque or UPI to the bank journal set in BeatPro settings.
If none is set, the first journal of that type is used. When a company has no cash journal
(Odoo 19's Indian chart, for example), a **Field Cash** journal is created on the first cash collection.
Payments are posted and matched with the invoices the rep selected.

## Mobile app API

The app signs in with the rep's login and an API key (user profile > Security > New API Key)
and calls `POST /json/2/<model>/<method>` with `Authorization: bearer <key>`.

| Model / method | Returns |
| --- | --- |
| `res.users` / `beatpro_app_context` | Rep, company, currency, discount limit, warehouse |
| `beatpro.route` / `beatpro_today_plan` | Today's customers in visit order |
| `product.pricelist` / `beatpro_prices(pricelist_ids, product_ids)` | `{pricelist: {product: unit price}}` for offline pricing |
| `res.partner` / `beatpro_open_invoices(partner_ids)` | Unpaid invoices to collect against |
| `<model>` / `beatpro_upsert(vals_list)` | `{mobile_uuid: id}`; records already received aren't created again (`res.partner`, `beatpro.visit`, `beatpro.day.close`) |
| `sale.order` / `beatpro_submit_orders(vals_list)` | Creates and confirms orders, or leaves them waiting for discount approval |
| `account.payment` / `beatpro_register_payment(vals_list)` | Records, posts and matches collections |
| `beatpro.day.close` / `action_close` | Totals and locks the day |

Standard `search_read` is used to download customers, products and stock.

## Run the tests

```bash
odoo-bin -d beatpro_test -i beatpro_field_sales --test-tags /beatpro_field_sales --stop-after-init
```
