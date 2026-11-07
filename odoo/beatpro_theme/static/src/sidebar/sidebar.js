import { Component, onMounted, onWillStart, onWillUnmount, useState } from "@odoo/owl";
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

        // Odoo's top bar fits its menu to its width only when the window is resized.
        // The side menu changes that width too (opening, closing, first load), and the
        // font can arrive late: tell the top bar to measure again, so the menu moves
        // into "More" instead of running under the icons on the right.
        onMounted(() => {
            const navbar = document.querySelector(".o_main_navbar");
            if (navbar && window.ResizeObserver) {
                let width = navbar.offsetWidth;
                this.observer = new ResizeObserver(() => {
                    if (navbar.offsetWidth !== width) {
                        width = navbar.offsetWidth;
                        this.remeasureNavbar();
                    }
                });
                this.observer.observe(navbar);
            }
            document.fonts?.ready.then(() => this.remeasureNavbar());
            this.remeasureNavbar();
        });
        onWillUnmount(() => this.observer?.disconnect());
    }

    remeasureNavbar() {
        browser.dispatchEvent(new Event("resize"));
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
