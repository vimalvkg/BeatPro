# BeatPro demo database (Odoo 19 Community)

`beatpro_demo_odoo19.zip` is an Odoo 19 Community backup (database and filestore) with the
BeatPro Field Sales module installed and sample data, for demos and testing. It is not for
production: the logins below are public.

## Restore it

**In the browser:** open `http://<your-odoo>/web/database/manager`, click **Restore Database**,
choose the zip, give it a name and pick **This database is a copy** so it gets its own identity.

**From the command line:**

```bash
odoo-bin db load beatpro_demo odoo/demo/beatpro_demo_odoo19.zip
```

The server needs this repository's `odoo` folder in its addons path (the `docker-compose.yml`
at the repository root does that).

## Logins

| Login | Password | Role |
| --- | --- | --- |
| `admin` | `admin` | Administrator (Payment Methods, settings) |
| `meena@beatpro.test` | `meena123` | BeatPro Supervisor: Overview, Routes, discount approvals |
| `ravi@beatpro.test` | `ravi123` | Rep, route Andheri East |
| `anil@beatpro.test` | `anil123` | Rep, route Powai |
| `farah@beatpro.test` | `farah123` | Rep, route Bandra West |
| `suresh@beatpro.test` | `suresh123` | Rep, route Ghatkopar |

To try the mobile app, sign in to Odoo as a rep, open the profile, **Security > New API Key**,
and use that key in the app with this server's address and database name.

## What's in it

- Company **Mumbai Distributors Pvt Ltd** (India, INR, Indian chart of accounts).
- 4 reps with one main route each, visited **every day**, so My Day always has shops; 6 more
  routes on Mondays and Wednesdays for the Routes board.
- 13 shops in Mumbai, 5 products with stock, an unpaid invoice for Sharma General Store.
- Payment methods for reps: **Cash**, **UPI** (asks for a transaction ID) and **Cheque**.
- A test-mode online payment provider, **Razorpay (test)**, so Pay online appears. It takes no
  real payments; set up a real provider before going live.
- Some activity dated the day the backup was made (5 Nov 2026): visits, orders, a discount waiting
  for approval and a closed day, so the supervisor's Overview has figures for "This month".
