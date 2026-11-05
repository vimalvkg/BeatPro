import { Component, onMounted, onWillStart, onWillUnmount, onWillUpdateProps, useState } from "@odoo/owl";
import { Dialog } from "@web/core/dialog/dialog";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardWidgetProps } from "@web/views/widgets/standard_widget_props";

function parseUtc(value) {
    return value ? new Date(value.replace(" ", "T") + "Z") : null;
}

function pad(n) {
    return String(n).padStart(2, "0");
}

/** Asks how the visit went before checking out. */
export class BeatproCheckOutDialog extends Component {
    static template = "beatpro_field_sales.CheckOutDialog";
    static components = { Dialog };
    static props = {
        close: Function,
        hasOrder: Boolean,
        reasons: Array,
        onConfirm: Function,
    };

    setup() {
        this.results = [
            { value: "order", label: _t("Order taken") },
            { value: "no_order", label: _t("No order") },
            { value: "closed", label: _t("Shop closed") },
        ];
        this.state = useState({ result: this.props.hasOrder ? "order" : "no_order", reason: null, note: "", busy: false });
    }

    get canConfirm() {
        return !this.state.busy && (this.state.result !== "no_order" || this.state.reason);
    }

    async confirm() {
        this.state.busy = true;
        try {
            await this.props.onConfirm(
                this.state.result,
                this.state.result === "no_order" ? this.state.reason : false,
                this.state.note.trim() || false
            );
            this.props.close();
        } finally {
            this.state.busy = false;
        }
    }
}

/**
 * The top of a visit: check in and out with the browser's GPS position, a live
 * timer, quick actions for orders and payments, the customer at a glance and
 * everything done during the visit.
 */
export class BeatproVisitPanel extends Component {
    static template = "beatpro_field_sales.VisitPanel";
    static props = { ...standardWidgetProps };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.dialog = useService("dialog");
        this.notification = useService("notification");
        this.state = useState({ data: null, busy: false, now: Date.now() });
        onWillStart(() => this.load(this.props.record.resId));
        onWillUpdateProps((next) => {
            if (next.record.resId !== this.props.record.resId || next.record.data.state !== this.props.record.data.state) {
                return this.load(next.record.resId);
            }
        });
        onMounted(() => {
            this.ticker = setInterval(() => (this.state.now = Date.now()), 1000);
        });
        onWillUnmount(() => clearInterval(this.ticker));
    }

    async load(resId) {
        this.state.data = resId
            ? await this.orm.call("beatpro.visit", "beatpro_panel_data", [[resId]])
            : null;
    }

    get record() {
        return this.props.record;
    }

    get timer() {
        const start = parseUtc(this.state.data && this.state.data.check_in);
        if (!start) {
            return "0:00";
        }
        const end = parseUtc(this.state.data.check_out);
        const seconds = Math.max(0, Math.floor(((end ? end.getTime() : this.state.now) - start.getTime()) / 1000));
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor((seconds % 3600) / 60);
        return hours ? `${hours}:${pad(minutes)}:${pad(seconds % 60)}` : `${minutes}:${pad(seconds % 60)}`;
    }

    get checkInTime() {
        const start = parseUtc(this.state.data && this.state.data.check_in);
        return start ? start.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : "";
    }

    getPosition() {
        return new Promise((resolve) => {
            if (!navigator.geolocation) {
                resolve(null);
                return;
            }
            navigator.geolocation.getCurrentPosition(
                ({ coords }) => resolve({ latitude: coords.latitude, longitude: coords.longitude }),
                () => resolve(null),
                { enableHighAccuracy: true, timeout: 10000, maximumAge: 60000 }
            );
        });
    }

    async refresh() {
        await this.record.load();
        await this.load(this.record.resId);
    }

    async run(method, kwargs = {}) {
        this.state.busy = true;
        try {
            if (!(await this.record.save())) {
                return;
            }
            await this.orm.call("beatpro.visit", method, [[this.record.resId]], kwargs);
            await this.refresh();
        } finally {
            this.state.busy = false;
        }
    }

    async checkIn() {
        const position = await this.getPosition();
        if (!position) {
            this.notification.add(_t("Your location isn't available, so the visit is saved without it."), {
                type: "warning",
            });
        }
        await this.run("action_check_in", {
            latitude: position ? position.latitude : 0,
            longitude: position ? position.longitude : 0,
        });
    }

    checkOut() {
        this.dialog.add(BeatproCheckOutDialog, {
            hasOrder: this.state.data.has_order,
            reasons: this.state.data.reasons,
            onConfirm: async (result, reason, note) => {
                const position = await this.getPosition();
                await this.run("action_check_out", {
                    result,
                    no_order_reason: reason,
                    note,
                    latitude: position ? position.latitude : 0,
                    longitude: position ? position.longitude : 0,
                });
            },
        });
    }

    async openAction(method) {
        if (!(await this.record.save())) {
            return;
        }
        const action = await this.orm.call("beatpro.visit", method, [[this.record.resId]]);
        await this.action.doAction(action, { onClose: () => this.refresh() });
    }

    openItem(item) {
        if (!item.res_model) {
            return;
        }
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: item.res_model,
            res_id: item.res_id,
            views: [[false, "form"]],
            target: "current",
        });
    }
}

registry.category("view_widgets").add("beatpro_visit_panel", { component: BeatproVisitPanel });
