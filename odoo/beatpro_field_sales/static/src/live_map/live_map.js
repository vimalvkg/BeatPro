import { Component, onMounted, onWillStart, onWillUnmount, useRef, useState } from "@odoo/owl";
import { loadCSS, loadJS } from "@web/core/assets";
import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { standardActionServiceProps } from "@web/webclient/actions/action_service";

const LIB = "/beatpro_field_sales/static/lib/leaflet/";
const COLORS = { visited: "#1F6B45", next: "#B26A00", missed: "#A3242B", later: "#9A8A8C" };
const DUBAI = [25.2048, 55.2708];

/** Where each rep is, their trail today and how their route is going. */
export class BeatproLiveMap extends Component {
    static template = "beatpro_field_sales.LiveMap";
    static props = { ...standardActionServiceProps };

    setup() {
        this.orm = useService("orm");
        this.mapRef = useRef("map");
        this.state = useState({ data: null, focus: null });
        onWillStart(async () => {
            await Promise.all([loadJS(LIB + "leaflet.js"), loadCSS(LIB + "leaflet.css"), this.load()]);
        });
        onMounted(() => {
            this.map = window.L.map(this.mapRef.el, { zoomControl: true }).setView(DUBAI, 11);
            window.L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
                maxZoom: 19,
                attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
            }).addTo(this.map);
            this.layer = window.L.layerGroup().addTo(this.map);
            this.draw(true);
            this.timer = setInterval(() => this.refresh(), 60000);
        });
        onWillUnmount(() => {
            clearInterval(this.timer);
            this.map?.remove();
        });
    }

    async load() {
        this.state.data = await this.orm.call("beatpro.location", "beatpro_live_map", []);
    }

    async refresh() {
        await this.load();
        this.draw(false);
    }

    draw(fit) {
        const L = window.L;
        this.layer.clearLayers();
        const bounds = [];
        for (const rep of this.state.data.reps) {
            if (this.state.focus && this.state.focus !== rep.user_id) {
                continue;
            }
            if (rep.trail.length > 1) {
                L.polyline(rep.trail, { color: "#7B1C24", weight: 4, dashArray: "2 8", lineCap: "round" }).addTo(this.layer);
            }
            for (const stop of rep.stops) {
                if (!stop.lat) {
                    continue;
                }
                L.circleMarker([stop.lat, stop.lng], {
                    radius: 8, color: "#fff", weight: 3, fillColor: COLORS[stop.status], fillOpacity: 1,
                }).bindTooltip(`${stop.name} · ${stop.status}`).addTo(this.layer);
                bounds.push([stop.lat, stop.lng]);
            }
            if (rep.last) {
                L.marker([rep.last.lat, rep.last.lng], {
                    icon: L.divIcon({ className: "bp-map-rep", html: `<span>${rep.initials}</span>`, iconSize: [34, 34] }),
                    title: rep.name,
                }).bindTooltip(`${rep.name} · ${rep.where}`).addTo(this.layer);
                bounds.push([rep.last.lat, rep.last.lng]);
            }
        }
        if (fit && bounds.length) {
            this.map.fitBounds(bounds, { padding: [40, 40], maxZoom: 15 });
        }
    }

    focus(rep) {
        this.state.focus = this.state.focus === rep.user_id ? null : rep.user_id;
        this.draw(true);
    }
}

registry.category("actions").add("beatpro.live_map", BeatproLiveMap);
