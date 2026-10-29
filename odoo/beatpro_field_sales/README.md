# BeatPro Field Sales (Odoo 19 Community)

Server side of the BeatPro field sales app. Install it on Odoo 19 Community; it needs only
standard Community modules (`sale_stock`, `account`).

## What it adds

| Model | Purpose |
| --- | --- |
| `beatpro.route` | A beat plan: the customers one rep visits, in order, on a weekday |
| `beatpro.route.line` | One customer on a route |
| `beatpro.visit` | A shop visit: check-in and check-out with GPS, result, no-order reason, orders and payments taken |
| `beatpro.day.close` | A rep's end-of-day totals: visits, orders, cash, cheque and UPI collected |
| `beatpro.mobile.mixin` | Adds `mobile_uuid` and `beatpro_upsert()` so offline uploads never create duplicates |

Extended models:

- `res.users`: discount limit, routes, van warehouse
- `res.partner`, `sale.order`, `account.payment`: `mobile_uuid`
- `sale.order`: link to the visit; app orders above the rep's discount limit can't be confirmed by the rep
- `account.payment`: how it was collected (cash, cheque, UPI), cheque number and date, UPI reference

## Access groups

Under **Settings > Users > BeatPro Field Sales**:

- **Rep: Own Routes Only** sees only their own routes, visits and day-end closes.
- **Supervisor** manages routes, sees every rep's records, and can reopen a closed day.

## Calls the mobile app uses

The app talks to Odoo 19's JSON-2 API (`/json/2/<model>/<method>`) with a user API key.

| Call | Returns |
| --- | --- |
| `beatpro.route` / `beatpro_today_plan` | Today's customers for the signed-in rep, in visit order |
| `<model>` / `beatpro_upsert` with `vals_list` | `{mobile_uuid: id}`; records already received are not created again. Works on `res.partner`, `sale.order`, `account.payment`, `beatpro.visit`, `beatpro.day.close` |
| `beatpro.visit` / `action_check_in`, `action_check_out` | Live check-in and check-out when the phone is online |
| `beatpro.day.close` / `action_close` | Totals the day and locks it |

## Run the tests

```bash
odoo-bin -d beatpro_test -i beatpro_field_sales --test-tags /beatpro_field_sales --stop-after-init
```
