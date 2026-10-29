import { Component, useState } from "@odoo/owl";
import { _t } from "@web/core/l10n/translation";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardWidgetProps } from "@web/views/widgets/standard_widget_props";

/**
 * Check In / Check Out buttons for a visit that record the browser's GPS position,
 * so reps without the mobile app can still log where a visit took place.
 */
export class BeatproGpsButtons extends Component {
    static template = "beatpro_field_sales.GpsButtons";
    static props = { ...standardWidgetProps };

    setup() {
        this.orm = useService("orm");
        this.notification = useService("notification");
        this.state = useState({ busy: false });
    }

    get visitState() {
        return this.props.record.data.state;
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

    async onClick(method) {
        const record = this.props.record;
        this.state.busy = true;
        try {
            if (!(await record.save())) {
                return;
            }
            const position = await this.getPosition();
            if (!position) {
                this.notification.add(
                    _t("Your location isn't available, so the visit is saved without it."),
                    { type: "warning" }
                );
            }
            await this.orm.call(record.resModel, method, [[record.resId]], {
                latitude: position?.latitude || 0,
                longitude: position?.longitude || 0,
            });
            await record.load();
        } finally {
            this.state.busy = false;
        }
    }
}

export const beatproGpsButtons = {
    component: BeatproGpsButtons,
};

registry.category("view_widgets").add("beatpro_gps_buttons", beatproGpsButtons);
