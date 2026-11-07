import { Component, onWillStart, useState } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const MODEL = "beatpro.target";

/** The supervisor's Targets board: each rep's month, and the incentive to approve. */
export class BeatproTargetsBoard extends Component {
    static template = "beatpro_field_sales.TargetsBoard";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.state = useState({ data: null, month: null, busy: null });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call(MODEL, "beatpro_targets_board", [], { month: this.state.month });
        this.state.month = this.state.data.month;
    }

    shift(months) {
        const [y, m] = this.state.month.split("-").map(Number);
        const d = new Date(Date.UTC(y, m - 1 + months, 1));
        this.state.month = d.toISOString().slice(0, 10);
        return this.load();
    }

    barStyle(row) {
        const pct = Math.max(0, Math.min(row.progress || 0, 100));
        return `width: ${pct}%; background: ${pct >= 80 ? "var(--bp-green, #1F6B45)" : "var(--bp-brand, #7B1C24)"}`;
    }

    async approve(row) {
        this.state.busy = row.user_id;
        try {
            await this.orm.call(MODEL, "action_approve", [[row.target_id]]);
            this.notification.add(_t("%s's incentive is approved.", row.name), { type: "success" });
            await this.load();
        } finally {
            this.state.busy = null;
        }
    }

    open(row) {
        if (row.target_id) {
            return this.action.doAction({
                type: "ir.actions.act_window", res_model: MODEL, res_id: row.target_id,
                views: [[false, "form"]], target: "current",
            });
        }
        return this.action.doAction({
            type: "ir.actions.act_window", res_model: "res.users", res_id: row.user_id,
            views: [[false, "form"]], target: "current",
        });
    }

    setTargets() {
        return this.action.doAction("beatpro_field_sales.action_beatpro_target", {
            additionalContext: { search_default_month: this.state.month, default_month: this.state.month },
        });
    }
}

registry.category("actions").add("beatpro.targets_board", BeatproTargetsBoard);
