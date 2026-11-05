import { Component, onWillStart, useState } from "@odoo/owl";
import { browser } from "@web/core/browser/browser";
import { useBus, useService } from "@web/core/utils/hooks";
import { WebClient } from "@web/webclient/webclient";

const COLLAPSED_KEY = "beatpro.sidebar.collapsed";

/** The left side menu: the screens a van sales team opens every day. */
export class BeatproSidebar extends Component {
    static template = "beatpro_theme.Sidebar";
    static props = {};

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.menu = useService("menu");
        this.ui = useState(useService("ui"));
        let collapsed = false;
        try {
            collapsed = browser.localStorage.getItem(COLLAPSED_KEY) === "1";
        } catch {
            // Storage blocked: start expanded.
        }
        this.state = useState({ data: null, active: null, collapsed });
        onWillStart(async () => {
            this.state.data = await this.orm.call("beatpro.theme", "beatpro_sidebar", []);
        });
        useBus(this.env.bus, "ACTION_MANAGER:UI-UPDATED", () => this.syncActive());
    }

    syncActive() {
        const id = this.action.currentController?.action?.id;
        const item = this.state.data?.items.find((i) => i.action_id === id);
        if (item) {
            this.state.active = item.key;
        }
    }

    async open(item) {
        this.state.active = item.key;
        // Open through its Odoo menu when there is one, so the top bar shows that app's sections.
        const menu = this.menu.getAll().find((m) => m.actionID === item.action_id);
        if (menu) {
            await this.menu.selectMenu(menu);
        } else {
            await this.action.doAction(item.action_id, { clearBreadcrumbs: true });
        }
    }

    toggle() {
        this.state.collapsed = !this.state.collapsed;
        try {
            browser.localStorage.setItem(COLLAPSED_KEY, this.state.collapsed ? "1" : "0");
        } catch {
            // Remembering is only a convenience.
        }
    }
}

WebClient.components = { ...WebClient.components, BeatproSidebar };
