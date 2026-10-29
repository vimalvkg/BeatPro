# BeatPro

Field sales for Odoo Community: reps plan their route, visit shops, take orders and collect
payments on their phone, offline, and everything syncs to Odoo.

| Folder | What it is |
| --- | --- |
| [`odoo/beatpro_field_sales`](odoo/beatpro_field_sales) | Odoo 19 Community module (server side) |
| `app/` | Flutter mobile app (coming on the `beatproapp` branch) |

## Run Odoo 19 with the module

```bash
docker compose up -d
```

Open http://localhost:8069, create a database, then install **BeatPro Field Sales** from Apps.
