import { Component, onWillStart, useState } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const TABS = [["today", "Today"], ["vans", "Vans"], ["warehouse", "Warehouse"], ["returns", "Returns & damage"], ["expiry", "Expiry"]];
const COLORS = { red: "#A3242B", amber: "#B26A00", green: "#1F6B45", grey: "#6E5A5C" };

/** Van stock, warehouse stock against the next 7 days, expiry and returns, for supervisors. */
export class BeatproInventory extends Component {
    static template = "beatpro_field_sales.Inventory";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.tabs = TABS;
        this.state = useState({ data: null, tab: "today", van: null });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call("beatpro.inventory", "beatpro_inventory_dashboard", []);
    }

    async openVan(id) {
        this.state.van = await this.orm.call("beatpro.inventory", "beatpro_inventory_van", [id]);
    }

    closeVan() {
        this.state.van = null;
    }

    color(state) {
        return COLORS[state] || COLORS.grey;
    }

    barStyle(pct, state) {
        return `width: ${Math.max(0, Math.min(pct, 100))}%; background: ${this.color(state || "brand")}`;
    }

    unloadStyle(u) {
        const height = Math.max(6, Math.min(44, Math.abs(u.value) / 10));
        return `height: ${height}px; background: ${this.color(u.state)}`;
    }

    statusClass(status) {
        return { out: "red", expiring: "amber", low: "amber", not_moving: "grey", selling: "green" }[status] || "grey";
    }

    async makePurchaseOrders(productIds) {
        const ids = productIds || this.state.data.low.filter((r) => r.vendor).map((r) => r.product_id);
        const result = await this.orm.call("beatpro.inventory", "beatpro_make_purchase_orders", [ids]);
        if (result.skipped.length) {
            this.notification.add(`No vendor set for ${result.skipped.join(", ")}. Add one on the product to order it.`, { type: "warning" });
        }
        if (result.action) {
            await this.action.doAction(result.action);
        }
    }

    async alertAction(alert) {
        if (alert.action === "purchase" && alert.product_id) {
            return this.makePurchaseOrders([alert.product_id]);
        }
        if (alert.action === "van" && alert.van_id) {
            return this.openVan(alert.van_id);
        }
        if (alert.action === "transfer" && alert.res_id) {
            return this.action.doAction({ type: "ir.actions.act_window", res_model: "beatpro.van.transfer", res_id: alert.res_id, views: [[false, "form"]] });
        }
        if (alert.action === "desk") {
            return this.action.doAction("beatpro_field_sales.action_beatpro_van_desk");
        }
        if (alert.action === "expiry") {
            this.state.tab = "expiry";
        }
    }

    alertLabel(alert) {
        return { purchase: "Make purchase order", van: "Open the van", transfer: "See the count", desk: "Open Vans desk", expiry: "See expiring stock" }[alert.action];
    }

    openDesk() {
        return this.action.doAction("beatpro_field_sales.action_beatpro_van_desk");
    }
}

registry.category("actions").add("beatpro.inventory", BeatproInventory);
