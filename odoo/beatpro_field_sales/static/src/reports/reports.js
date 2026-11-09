import { Component, onWillStart, useState } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const TABS = [
    ["overview", "Overview"], ["products", "Brands & products"], ["reps", "Routes & reps"],
    ["schemes", "Schemes"], ["lost", "Lost shops"], ["compliance", "Visit compliance"],
];

/** Sales, schemes, lost shops and visit compliance, for supervisors. */
export class BeatproSalesReports extends Component {
    static template = "beatpro_field_sales.SalesReports";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.tabs = TABS;
        this.state = useState({ data: null, tab: "overview", period: "this_month" });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call("beatpro.reports", "beatpro_sales_reports", [], { period: this.state.period });
    }

    async setPeriod(ev) {
        this.state.period = ev.target.value;
        await this.load();
    }

    barStyle(pct, good) {
        const color = good === undefined ? "#7B1C24" : good ? "#1F6B45" : "#B26A00";
        return `width: ${Math.max(0, Math.min(pct, 100))}%; background: ${color}`;
    }
}

registry.category("actions").add("beatpro.sales_reports", BeatproSalesReports);
