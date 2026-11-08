import { Component, onWillStart, useState } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const MODEL = "beatpro.day.close";

/** The accountant counts the cash and cheques each rep hands in at day end. */
export class BeatproCashHandover extends Component {
    static template = "beatpro_field_sales.CashHandover";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.state = useState({ data: null, counted: {}, cheques: {}, busy: null });
        onWillStart(() => this.load());
    }

    async load() {
        const data = await this.orm.call(MODEL, "beatpro_handover_desk", []);
        for (const card of data.open) {
            if (!(card.id in this.state.counted)) {
                this.state.counted[card.id] = card.state === "to_approve" ? card.counted : card.cash;
                this.state.cheques[card.id] = Object.fromEntries(card.cheques.map((c) => [c.id, !c.missing]));
            }
        }
        this.state.data = data;
    }

    difference(card) {
        return Math.round((Number(this.state.counted[card.id] || 0) - card.cash) * 100) / 100;
    }

    missingCheques(card) {
        return card.cheques.filter((c) => !this.state.cheques[card.id][c.id]);
    }

    matches(card) {
        return this.difference(card) === 0 && !this.missingCheques(card).length;
    }

    async count(card) {
        this.state.busy = card.id;
        try {
            const received = card.cheques.filter((c) => this.state.cheques[card.id][c.id]).map((c) => c.id);
            await this.orm.call(MODEL, "action_count", [[card.id], Number(this.state.counted[card.id] || 0), received]);
            this.notification.add(this.matches(card) ? _t("%s's hand over is confirmed.", card.rep)
                : _t("%s's difference is sent to the supervisor.", card.rep), { type: this.matches(card) ? "success" : "warning" });
            await this.load();
        } finally {
            this.state.busy = null;
        }
    }

    async approve(card) {
        this.state.busy = card.id;
        try {
            await this.orm.call(MODEL, "action_approve_difference", [[card.id]]);
            this.notification.add(_t("Difference written off for %s.", card.rep), { type: "success" });
            await this.load();
        } finally {
            this.state.busy = null;
        }
    }

    open(card) {
        return this.action.doAction({ type: "ir.actions.act_window", res_model: MODEL, res_id: card.id,
            views: [[false, "form"]], target: "current" });
    }
}

registry.category("actions").add("beatpro.cash_handover", BeatproCashHandover);
