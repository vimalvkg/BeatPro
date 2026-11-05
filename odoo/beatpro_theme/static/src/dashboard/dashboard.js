import { Component, onWillStart, useState } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const CATEGORY_COLORS = ["#7B1C24", "#E0A12F", "#E79AA3", "#9DB4D6", "#B9A6A8"];

/** Van Sales Dashboard: sales, orders, shops and collections at a glance. */
export class BeatproSalesDashboard extends Component {
    static template = "beatpro_theme.SalesDashboard";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.periods = [
            { value: "week", label: _t("This week") },
            { value: "month", label: _t("Month") },
            { value: "quarter", label: _t("Quarter") },
            { value: "year", label: _t("Year") },
        ];
        this.colors = CATEGORY_COLORS;
        this.state = useState({ data: null, period: "week", routeId: false });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call("beatpro.theme", "get_sales_dashboard", [], {
            period: this.state.period,
            route_id: this.state.routeId,
        });
    }

    async setPeriod(period) {
        this.state.period = period;
        await this.load();
    }

    async setRoute(ev) {
        this.state.routeId = parseInt(ev.target.value) || false;
        await this.load();
    }

    spark(values) {
        const max = Math.max(...values, 1);
        const step = values.length > 1 ? 160 / (values.length - 1) : 160;
        const pts = values.map((v, i) => `${Math.round(i * step)},${Math.round(40 - (v / max) * 34)}`).join(" ");
        return { line: pts, area: `0,44 ${pts} 160,44` };
    }

    barHeight(amount) {
        return `height: ${Math.max(2, Math.round((amount / this.state.data.chart_max_amount) * 100))}%`;
    }

    get orderLine() {
        const chart = this.state.data.chart;
        const n = chart.length;
        return chart
            .map((c, i) => `${((i + 0.5) / n) * 100},${100 - (c.count / this.state.data.chart_max_count) * 85}`)
            .join(" ");
    }

    dots() {
        const chart = this.state.data.chart;
        const n = chart.length;
        return chart.map((c, i) => ({
            key: i,
            left: `${((i + 0.5) / n) * 100}%`,
            top: `${100 - (c.count / this.state.data.chart_max_count) * 85}%`,
            count: c.count,
        }));
    }

    get donut() {
        let at = 0;
        const parts = this.state.data.categories.map((c, i) => {
            const from = at;
            at += c.share;
            return `${this.colors[i % this.colors.length]} ${from}% ${at}%`;
        });
        return `background: conic-gradient(${parts.join(", ") || "#EADCDD 0 100%"})`;
    }

    get collectDonut() {
        const pct = this.state.data.collected_pct;
        return `background: conic-gradient(#2E8B57 0 ${pct}%, #E0A12F ${pct}% 100%)`;
    }

    open(xmlId, context = {}) {
        this.action.doAction(xmlId, { additionalContext: context });
    }

    openShop(id) {
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "res.partner",
            res_id: id,
            views: [[false, "form"]],
        });
    }
}

registry.category("actions").add("beatpro.sales_dashboard", BeatproSalesDashboard);
