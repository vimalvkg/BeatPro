import { Component, onWillStart, useState } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

/** The supervisor's overview of the field team. */
export class BeatproDashboard extends Component {
    static template = "beatpro_field_sales.Dashboard";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.periods = [
            { value: "today", label: _t("Today") },
            { value: "week", label: _t("This week") },
            { value: "month", label: _t("This month") },
        ];
        this.state = useState({ data: null, period: "today", approving: null });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call("beatpro.dashboard", "get_data", [], { period: this.state.period });
    }

    get greeting() {
        const hour = new Date().getHours();
        const part = hour < 12 ? _t("Good morning") : hour < 17 ? _t("Good afternoon") : _t("Good evening");
        return `${part}, ${this.state.data.greeting_name}`;
    }

    async setPeriod(period) {
        this.state.period = period;
        await this.load();
    }

    async approve(approval) {
        this.state.approving = approval.id;
        try {
            await this.orm.call("sale.order", "action_beatpro_approve", [[approval.id]]);
            this.notification.add(_t("Discount approved and order confirmed for %s.", approval.shop), { type: "success" });
            await this.load();
        } finally {
            this.state.approving = null;
        }
    }

    open(xmlId) {
        this.action.doAction(xmlId);
    }

    openOrder(id) {
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "sale.order",
            res_id: id,
            views: [[false, "form"]],
            target: "current",
        });
    }
}

registry.category("actions").add("beatpro.dashboard", BeatproDashboard);
