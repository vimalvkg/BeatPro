import { Dialog } from "@web/core/dialog/dialog";
import { registry } from "@web/core/registry";

// User menu: no links to odoo.com.
const userMenu = registry.category("user_menuitems");
for (const key of ["documentation", "support", "odoo_account"]) {
    if (userMenu.contains(key)) {
        userMenu.remove(key);
    }
}

// Dialogs opened without a title.
Dialog.defaultProps = { ...Dialog.defaultProps, title: "BeatPro" };
