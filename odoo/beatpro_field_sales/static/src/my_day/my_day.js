import { Component, onWillStart, useState } from "@odoo/owl";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const RING = 2 * Math.PI * 30;

/** A rep's day: progress, the next shop and today's route. */
export class BeatproMyDay extends Component {
    static template = "beatpro_field_sales.MyDay";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.state = useState({ data: null, opening: false });
        onWillStart(() => this.load());
    }

    async load() {
        this.state.data = await this.orm.call("beatpro.route.line", "beatpro_my_day_data", []);
    }

    get ring() {
        const { done, planned } = this.state.data;
        const filled = planned ? (done / planned) * RING : 0;
        return `${filled} ${RING}`;
    }

    stopClass(stop) {
        return { visited: "bp-ok", in_progress: "bp-solid" }[stop.status] || "";
    }

    stopPill(stop) {
        const next = this.state.data.next;
        if (stop.status === "visited") {
            return { cls: "bp-done", label: "Visited" };
        }
        if (stop.status === "in_progress") {
            return { cls: "bp-live", label: "In progress" };
        }
        if (next && next.line_id === stop.line_id) {
            return { cls: "bp-next", label: "Next" };
        }
        return { cls: "", label: "To visit" };
    }

    directionsUrl(stop) {
        return `https://www.google.com/maps/dir/?api=1&destination=${stop.latitude},${stop.longitude}`;
    }

    async openStop(stop) {
        if (this.state.opening) {
            return;
        }
        this.state.opening = true;
        try {
            const action = await this.orm.call("beatpro.route.line", "action_start_visit", [[stop.line_id]]);
            await this.action.doAction(action);
        } finally {
            this.state.opening = false;
        }
    }

    async closeDay() {
        const action = await this.orm.call("beatpro.day.close", "action_open_today", []);
        await this.action.doAction(action);
    }
}

registry.category("actions").add("beatpro.my_day", BeatproMyDay);
