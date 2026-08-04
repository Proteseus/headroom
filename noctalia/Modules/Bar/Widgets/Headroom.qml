import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Services.UI
import qs.Widgets

// Compact quota overview. The expanded dashboard remains lazy-loaded by the
// headroomPanel and is only instantiated after this control is clicked.
Rectangle {
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
  readonly property bool isVertical: Settings.data.bar.position === "left"
                                     || Settings.data.bar.position === "right"
  readonly property real ringDiameter: Math.max(16, Math.round(Style.capsuleHeight * 0.72))
  readonly property var visibleProviders: focusProviders()

  property var snapshot: ({})
  property var attention: ({})
  property bool healthy: false
  property bool requestPending: false
  property bool hovering: false

  readonly property string attentionLevel: attention.level || ""
  readonly property color statusColor: {
    if (!healthy) return Color.mTertiary;
    if (attentionLevel === "critical") return Color.mError;
    if (attentionLevel === "warn") return Color.mTertiary;
    return Color.mPrimary;
  }

  implicitWidth: isVertical
                 ? Style.capsuleHeight
                 : Math.round(quotaLayout.implicitWidth + Style.marginS * 2)
  implicitHeight: isVertical
                  ? Math.round(quotaLayout.implicitHeight + Style.marginS * 2)
                  : Style.capsuleHeight
  radius: Style.radiusXS
  color: hovering ? Color.mHover : Style.capsuleColor
  border.width: Style.borderS
  border.color: hovering ? Color.mHover : Color.transparent

  Accessible.role: Accessible.Button
  Accessible.name: "Headroom quota overview"
  Accessible.description: makeTooltip()

  Behavior on color {
    ColorAnimation {
      duration: Style.animationFast
      easing.type: Easing.InOutQuad
    }
  }

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
    return (focus.length > 0 ? focus : providers.filter(p => p.enabled !== false)).slice(0, 3);
  }

  function ringLayersFor(provider) {
    const pools = provider.pools || {};
    const ids = Object.keys(pools).sort((a, b) => {
      const ra = pools[a].rank !== undefined ? pools[a].rank : 999;
      const rb = pools[b].rank !== undefined ? pools[b].rank : 999;
      return ra - rb || (a < b ? -1 : 1);
    });
    return ids.filter(id => pools[id].ring !== false
                       && pools[id].pct !== null
                       && pools[id].pct !== undefined)
              .slice(0, 2)
              .map(id => ({
                "id": id,
                "name": pools[id].title || id,
                "percent": pools[id].pct,
                "pacePercent": pools[id].pacePct
              }));
  }

  function tintFor(provider) {
    const accent = provider.accent;
    if (accent && /^#?[0-9a-fA-F]{6}$/.test(String(accent))) {
      return String(accent).startsWith("#") ? accent : "#" + accent;
    }
    switch (provider.id) {
      case "claude": return "#D97757";
      case "codex": return "#10A37F";
      case "cursor": return "#789BC8";
      default: return Color.mPrimary;
    }
  }

  function primaryPercent(provider) {
    const layers = ringLayersFor(provider);
    return layers.length > 0 ? layers[0].percent : null;
  }

  function makeTooltip() {
    if (!healthy) return "Headroom — host not answering";
    const providers = focusProviders();
    if (providers.length === 0) return "Headroom — no quota sources enabled";
    const parts = providers.map(p => {
      const used = primaryPercent(p);
      return used === null
        ? (p.title || p.id) + " — no reading"
        : (p.title || p.id) + " " + Math.round(100 - used) + "% left";
    });
    return "Headroom — " + parts.join(" · ");
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
          healthy = false;
          Logger.w("Bar:Headroom", "Invalid /usage response:", error);
        }
      } else {
        healthy = false;
      }
    };
    request.open("GET", hostUrl + "/usage", true);
    request.send();
  }

  GridLayout {
    id: quotaLayout
    anchors.centerIn: parent
    flow: root.isVertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
    rows: root.isVertical ? -1 : 1
    columns: root.isVertical ? 1 : -1
    rowSpacing: Style.marginXS
    columnSpacing: Style.marginXS

    Repeater {
      model: root.visibleProviders

      delegate: HeadroomRing {
        required property var modelData

        diameter: root.ringDiameter
        layers: root.ringLayersFor(modelData)
        tint: root.tintFor(modelData)
        indicatorColor: root.hovering ? Color.mOnHover : Color.mOnSurface
        unavailable: layers.length === 0
        Layout.alignment: Qt.AlignCenter
      }
    }

    NIcon {
      visible: root.visibleProviders.length === 0
      icon: root.widgetSettings.icon || root.widgetMetadata.icon || "chart-donut"
      pointSize: Math.max(Style.fontSizeM, root.ringDiameter * 0.7)
      color: root.hovering ? Color.mOnHover : Color.mOnSurfaceVariant
      Layout.alignment: Qt.AlignCenter
    }

    Rectangle {
      width: Math.max(5, Math.round(5 * Style.uiScaleRatio))
      height: width
      radius: width / 2
      color: root.statusColor
      Layout.alignment: Qt.AlignCenter

      Behavior on color {
        ColorAnimation {
          duration: Style.animationFast
          easing.type: Easing.InOutQuad
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onEntered: {
      root.hovering = true;
      pollTimer.restart();
      root.poll();
      TooltipService.show(root, root.makeTooltip(), BarService.getTooltipDirection());
    }
    onExited: {
      root.hovering = false;
      TooltipService.hide();
    }
    onClicked: {
      TooltipService.hide();
      const panel = PanelService.getPanel("headroomPanel", root.screen);
      if (panel) {
        panel.snapshot = root.snapshot;
        panel.healthy = root.healthy;
        panel.toggle(root, "headroom");
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.hovering ? 5000 : root.pollInterval * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }
}
