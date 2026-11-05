# BeatPro Field Sales (Odoo 19 Community)

Field sales for Odoo 19 Community. Reps can work in either of two ways, and both write to the
same records:

- **In the Odoo web client** (desktop or a phone browser), with no app needed.
- **In the BeatPro mobile app**, which works offline and syncs through Odoo's JSON-2 API.

Only standard Community modules are needed (`sale_stock`, `account`, `account_payment`).

## Working in the Odoo web client

Menu **BeatPro**:

| Menu | Who | What it does |
| --- | --- | --- |
| Overview | Supervisors | Today's, this week's or this month's visits, order value, collections by method, every rep's progress, discounts to approve in one click and why shops didn't order |
| My Day | Reps | Progress ring with the day's orders and collections, the next shop with Start visit, directions and call, and the route with each shop's status |
| My Van | Reps with a van | What is in the van now (loaded, delivered, taken back, left), the main warehouse's stock, **Load the van** (today's suggestion from the route's last orders) and **Unload the van** (count what is left) |
| Visits | Reps | The visit panel: **Check in** and **Check out** record the browser's GPS position and show the distance from the shop pin; a live timer; **Take order** and **Collect payment** tiles; the customer's amount due, last and usual order; everything done during the visit. Check-out asks for the result, the no-order reason and a note. |
| Orders | Reps | Orders taken during visits or sent from the app. Reps with a van choose the **Delivery**: from the van now, the van now and the rest from the main warehouse, or all from the main warehouse. The order is the rep's sale every way. |
| Goods Taken Back | Reps | Goods a shop returns, with a reason: resellable goods go back into the van, damaged and expired goods to the damaged stock area, and the shop gets a draft credit note |
| Day-End Closes | Reps | The cash and cheques to hand in, UPI already in the bank, visits and orders, and a list of the day's visits; closing locks the day |
| Routes | Supervisors (reps read only) | A board of routes by weekday, with each route's rep, shops and how often its visits end with an order |
| Supervisor > Vans | Supervisors | The storekeeper's Vans page, plus approving stock differences |
| Supervisor > Van Loads and Unloads, Return Reasons, Van Setup | Supervisors | History, why shops return goods, and the van warehouses |
| Supervisor > Discount Approvals | Supervisors | Orders whose discount is above the rep's limit |
| Supervisor > Visit Analysis | Supervisors | Visits by rep and result |
| Supervisor > Payment Methods | Accounting managers | Which payment methods reps see, their names and what reps enter |
| Supervisor > Settings | Admins | Links to payment methods and online payment providers |

**Inventory > Operations > Vans** is the storekeeper's page (Inventory / User): load requests to
load, unloads to receive (or recount), stock differences waiting for a supervisor, and vans on the road.

A rep whose discount is above their limit can't confirm the order; they click **Request
Approval** and a supervisor clicks **Approve Discount**.

Customers get a **Field Sales** tab (routes, last visit, GPS position) and a Visits button.

The BeatPro screens use the Manrope typeface (SIL Open Font License, `static/src/fonts/OFL.txt`).

## Access groups

Under **Settings > Users > BeatPro Field Sales**:

- **Rep: Own Routes Only** sees only their own routes, visits, day-end closes and collections.
  Reps can add customers and record collections without accounting rights.
- **Supervisor** manages routes, sees every rep's records, approves discounts and reopens closed days.

Storekeepers need **Inventory / User**.

Set each rep's discount limit, van warehouse and *Loads Own Van* on the **BeatPro** tab of their user.

## Van sales

1. Set up a van: **BeatPro > Supervisor > Van Setup** (a small warehouse marked *Sales Van*, with
   its vehicle number), then pick it as the **Van Warehouse** on the rep's user.
2. **Morning load.** The rep sends a load request. The storekeeper checks it, loads the van and
   clicks **Load van**: stock moves from the main warehouse into the van. Reps marked **Loads Own
   Van** on their user skip the storekeeper.
3. **Orders.** Delivered from the van, the delivery is done at once. A split order is one order
   with two deliveries. A main-warehouse order is a normal delivery from the main warehouse.
4. **Goods taken back** go into the van (sellable) or the damaged stock area, with a draft credit note.
5. **Day-end unload.** The rep counts what is left; a difference needs a note. The storekeeper
   receives the counted stock into the main warehouse. A difference waits for a supervisor to
   **Approve Write-off**, which empties the van.

## Field collections

**Money received in hand.** Reps choose from the incoming payment methods of your cash and bank
journals that are turned on under **BeatPro > Supervisor > Payment Methods** (or on each
journal's Payment Methods tab). For each one you set:

- **Show to BeatPro Reps**: whether it appears on the Collect Payment screen.
- **Name for Reps**: e.g. "UPI", "Bank transfer". Cash journals show as "Cash".
- **Reps Enter**: nothing, an optional transaction reference (UPI ID) or cheque number and date.

The payment is posted to that journal and matched with the invoices the rep selected. The
day-end close counts cash journals and cheque methods as money to hand in, and other bank
methods as already in the bank. When a company has no cash journal (Odoo 19's Indian chart, for
example), a **Field Cash** journal is created.

**Online payment.** When an online payment provider (Razorpay, Stripe, PayPal and others) is
enabled under Accounting > Configuration > Payment Providers, reps get **Pay online**: a QR code
and link for one invoice. The customer pays on Odoo's invoice page and the provider marks the
invoice paid. Online payments need the server's portal payments setting turned on.

## Mobile app API

The app signs in with the rep's login and an API key (user profile > Security > New API Key)
and calls `POST /json/2/<model>/<method>` with `Authorization: bearer <key>`.

| Model / method | Returns |
| --- | --- |
| `res.users` / `beatpro_app_context` | Rep, company, currency, discount limit, warehouse, payment methods for reps, enabled online providers |
| `beatpro.route` / `beatpro_today_plan` | Today's customers in visit order |
| `product.pricelist` / `beatpro_prices(pricelist_ids, product_ids)` | `{pricelist: {product: unit price}}` for offline pricing |
| `res.partner` / `beatpro_open_invoices(partner_ids)` | Unpaid invoices to collect against |
| `<model>` / `beatpro_upsert(vals_list)` | `{mobile_uuid: id}`; records already received aren't created again (`res.partner`, `beatpro.visit`, `beatpro.day.close`) |
| `sale.order` / `beatpro_submit_orders(vals_list)` | Creates and confirms orders, or leaves them waiting for discount approval |
| `account.payment` / `beatpro_register_payment(vals_list)` | Records, posts and matches collections on a `payment_method_line_id` from the app context |
| `account.payment` / `beatpro_payment_link(invoice_id, amount)` | Link for the customer to pay an invoice online |
| `account.payment` / `beatpro_invoice_status(invoice_ids)` | Whether invoices are paid, to follow an online payment |
| `beatpro.day.close` / `action_close` | Totals and locks the day |
| `beatpro.van.transfer` / `beatpro_load_suggestion` | Today's suggested van load |
| `beatpro.van.transfer` / `beatpro_van_stock` | The van and main warehouse stock screen |
| `beatpro.van.transfer` / `beatpro_submit_transfers(vals_list)` | Sends loads and day-end unloads (`kind`, `line_ids`, `note`) |
| `beatpro.shop.return` / `beatpro_return_candidates(partner_id)` | What the shop bought lately, with price |
| `beatpro.shop.return` / `beatpro_submit_returns(vals_list)` | Takes goods back and makes the credit note |

Standard `search_read` is used to download customers, products and stock.

## Run the tests

```bash
odoo-bin -d beatpro_test -i beatpro_field_sales --test-tags /beatpro_field_sales --stop-after-init
```
