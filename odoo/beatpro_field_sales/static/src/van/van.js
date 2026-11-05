import { Component, onWillStart, useState } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const MODEL = "beatpro.van.transfer";

function fmt(qty) {
    return Number.isInteger(qty) ? String(qty) : qty.toFixed(2).replace(/\.?0+$/, "");
}

function openRecord(action, resModel, id) {
    return action.doAction({
        type: "ir.actions.act_window",
        res_model: resModel,
        res_id: id,
        views: [[false, "form"]],
        target: "current",
    });
}

/** The rep's van: what is in it, what the main warehouse has, and load / unload. */
export class BeatproMyVan extends Component {
    static template = "beatpro_field_sales.MyVan";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.fmt = fmt;
        this.state = useState({ data: null, tab: "van", search: "" });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call(MODEL, "beatpro_van_stock", []);
    }

    get items() {
        const d = this.state.data;
        const list = this.state.tab === "van" ? d.van_items : d.main_items;
        const q = this.state.search.trim().toLowerCase();
        return q ? list.filter((i) => i.name.toLowerCase().includes(q)) : list;
    }

    tag(item) {
        return {
            ok: { label: _t("in van"), cls: "bp-done" },
            low: { label: _t("running low"), cls: "bp-live" },
            out: { label: _t("none left"), cls: "bp-due" },
        }[item.status];
    }

    async start(kind) {
        const action = await this.orm.call(MODEL, "action_beatpro_new", [], { kind });
        await this.action.doAction(action);
    }

    open(id) {
        return openRecord(this.action, MODEL, id);
    }
}

/** The storekeeper's page: load requests, unloads to receive, vans on the road. */
export class BeatproVanDesk extends Component {
    static template = "beatpro_field_sales.VanDesk";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.fmt = fmt;
        this.state = useState({ data: null, busy: null });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call(MODEL, "beatpro_desk_data", []);
    }

    async run(card, method, message) {
        this.state.busy = card.id;
        try {
            await this.orm.call(MODEL, method, [[card.id]]);
            this.notification.add(message, { type: "success" });
            await this.load();
        } finally {
            this.state.busy = null;
        }
    }

    loadVan(card) {
        return this.run(card, "action_load", _t("%s's van is loaded.", card.rep));
    }

    receive(card) {
        return this.run(card, "action_receive",
            card.differences.length ? _t("Received. The difference waits for a supervisor.") : _t("%s's van is received.", card.rep));
    }

    approve(card) {
        return this.run(card, "action_approve_difference", _t("Difference written off for %s.", card.rep));
    }

    open(card) {
        return openRecord(this.action, MODEL, card.id);
    }

    differenceText(diff) {
        const n = Math.abs(diff.difference);
        return diff.difference < 0 ? _t("%(product)s: %(n)s short", { product: diff.product, n: fmt(n) })
            : _t("%(product)s: %(n)s extra", { product: diff.product, n: fmt(n) });
    }
}

registry.category("actions").add("beatpro.my_van", BeatproMyVan);
registry.category("actions").add("beatpro.van_desk", BeatproVanDesk);
