import QtQuick
import Quickshell
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Services.UI
import qs.Widgets

// Compact closed state. The full rings dashboard is lazy-loaded by the
// headroomPanel only after this button is clicked.
NIconButton {
  id: root

  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  property var widgetMetadata: BarWidgetRegistry.widgetMetadata[widgetId]
  property var widgetSettings: {
    if (section && sectionWidgetIndex >= 0) {
      const widgets = Settings.data.bar.widgets[section];
      if (widgets && sectionWidgetIndex < widgets.length) {
        return widgets[sectionWidgetIndex];
      }
    }
    return {};
  }

  readonly property string hostUrl: normalizedHostUrl(
                                      widgetSettings.hostUrl !== undefined
                                      ? widgetSettings.hostUrl
                                      : (widgetMetadata.hostUrl || "http://localhost:8737"))
  readonly property int pollInterval: Math.max(
                                        5,
                                        Number(widgetSettings.pollInterval !== undefined
                                               ? widgetSettings.pollInterval
                                               : (widgetMetadata.pollInterval || 30)) || 30)
  property var snapshot: ({})
  property var attention: ({})
  property bool healthy: false
  property bool requestPending: false

  readonly property string attentionLevel: attention.level || ""
  readonly property bool attentionIsWarning: attention.level === "warn"
                                             || attention.level === "critical"
  readonly property color statusColor: {
    if (!healthy) return "#C39B55";
    if (attentionLevel === "critical") return "#AF6964";
    if (attentionLevel === "warn") return "#C39B55";
    return "#5F9B73";
  }

  icon: widgetSettings.icon || widgetMetadata.icon || "chart-donut"
  tooltipText: makeTooltip()
  tooltipDirection: BarService.getTooltipDirection()
  baseSize: Style.capsuleHeight
  applyUiScale: false
  density: Settings.data.bar.density
  colorBg: Color.transparent
  colorFg: statusColor
  colorBgHover: Color.mHover
  colorFgHover: Color.mOnHover
  colorBorder: Color.transparent
  colorBorderHover: Color.transparent

  function normalizedHostUrl(value) {
    let url = String(value || "http://localhost:8737").trim();
    while (url.length > 0 && url.endsWith("/")) url = url.slice(0, -1);
    return url;
  }

  function focusProviders() {
    const providers = Array.isArray(snapshot.providers) ? snapshot.providers : [];
    const byId = {};
    providers.forEach(p => { if (p.id) byId[p.id] = p; });
    const focus = (snapshot.focus || []).map(id => byId[id]).filter(Boolean);
    return focus.length > 0 ? focus.slice(0, 3) : providers.filter(p => p.enabled !== false).slice(0, 3);
  }

  function primaryPercent(provider) {
    const pools = provider.pools || {};
    const ids = Object.keys(pools).sort((a, b) => {
      const ra = pools[a].rank !== undefined ? pools[a].rank : 999;
      const rb = pools[b].rank !== undefined ? pools[b].rank : 999;
      return ra - rb || (a < b ? -1 : 1);
    });
    for (let i = 0; i < ids.length; ++i) {
      const pool = pools[ids[i]];
      if (pool.ring !== false && pool.pct !== null && pool.pct !== undefined) return pool.pct;
    }
    return null;
  }

  function makeTooltip() {
    if (!healthy) return "Headroom — host not answering";
    const providers = focusProviders();
    if (providers.length === 0) return "Headroom — no quota sources enabled";
    const parts = providers.map(p => {
      const used = primaryPercent(p);
      return used === null ? (p.title || p.id) + " —" : (p.title || p.id) + " " + Math.round(100 - used) + "% left";
    });
    return "Headroom — " + parts.join(", ");
  }

  function poll() {
    if (requestPending) return;
    requestPending = true;
    const request = new XMLHttpRequest();
    request.onreadystatechange = function () {
      if (request.readyState !== XMLHttpRequest.DONE) return;
      requestPending = false;
      if (request.status >= 200 && request.status < 300) {
        try {
          snapshot = JSON.parse(request.responseText);
          attention = snapshot.attention || {};
          healthy = true;
        } catch (error) {
          Logger.w("Bar:Headroom", "Invalid /usage response:", error);
        }
      } else {
        healthy = false;
      }
    };
    request.open("GET", hostUrl + "/usage", true);
    request.send();
  }

  Timer {
    id: pollTimer
    interval: root.hovering ? 5000 : root.pollInterval * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  onClicked: {
    const panel = PanelService.getPanel("headroomPanel", root.screen);
    if (panel) {
      panel.snapshot = root.snapshot;
      panel.healthy = root.healthy;
      panel.toggle(root, "headroom");
    }
  }
  onEntered: {
    pollTimer.restart();
    root.poll();
    TooltipService.updateText(root.makeTooltip());
  }
}
