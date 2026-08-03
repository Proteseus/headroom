import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Modules.Bar.Widgets
import qs.Modules.MainScreen
import qs.Services.UI
import qs.Widgets

// HeadroomPanel.qml — the popover the bar widget opens, ported from the
// macOS DashboardView / QuotaOverviewCard design language:
//   - header: "Headroom" + status line (attention level, host health)
//   - rings grid: one canonical ring glyph per provider, 2 bands
//     (week outside, session inside), pace dot, provider name + % used
//   - daily burn: the by_day bars, one per provider
//   - footer note when the snapshot is stale
Item {
  id: root

  property ShellScreen screen: null
  property var snapshot: ({})
  property bool healthy: false

  // The content owns the visual surface so the panel never renders as a
  // transparent floating block over the bar.
  Rectangle {
    anchors.fill: parent
    z: -1
    radius: 16
    color: Color.mSurface
  }

  // ----- palette (HeadroomPalette.swift) -----
  readonly property color dimColor: "#78746E"
  readonly property color statusGreen: "#5F9B73"
  readonly property color statusAmber: "#C39B55"
  readonly property color statusRed: "#AF6964"

  readonly property var attention: snapshot.attention || {}
  readonly property string attentionLevel: attention.level || ""
  readonly property bool attentionIsWarning: attention.level === "warn"
                                             || attention.level === "critical"
  readonly property color statusColor: {
    if (!root.healthy) return statusAmber;
    if (attentionLevel === "critical") return statusRed;
    if (attentionLevel === "warn") return statusAmber;
    return statusGreen;
  }

  function tintFor(provider) {
    // HeadroomPalette.providerComponents: accent hex ?? builtin ?? dim
    const accent = provider.accent;
    if (accent && /^#?[0-9a-fA-F]{6}$/.test(String(accent))) {
      return accent;
    }
    switch (provider.id) {
      case "claude": return "#D97757";
      case "codex": return "#10A37F";
      case "cursor": return "#789BC8";
    }
    return dimColor;
  }

  // Rings per provider: visiblePools sorted by rank, ring != false,
  // take the first 2 (longer window first). Matches QuotaPresentation.
  function ringLayersFor(provider) {
    const pools = provider.pools || {};
    const ids = Object.keys(pools);
    ids.sort((a, b) => {
      const ra = pools[a].rank !== undefined ? pools[a].rank : 999;
      const rb = pools[b].rank !== undefined ? pools[b].rank : 999;
      if (ra !== rb) return ra - rb;
      return a < b ? -1 : 1;
    });
    const layers = [];
    for (let i = 0; i < ids.length && layers.length < 2; ++i) {
      const pool = pools[ids[i]];
      if (pool.ring === false || pool.pct === null || pool.pct === undefined) continue;
      layers.push({
        "id": ids[i],
        "name": pool.title || ids[i],
        "percent": pool.pct,
        "pacePercent": pool.pacePct
      });
    }
    return layers;
  }

  function percentUsed(provider) {
    const layers = ringLayersFor(provider);
    return layers.length > 0 ? layers[0].percent : null;
  }

  function statusLine() {
    if (!root.healthy) return "Host not answering";
    if (attentionIsWarning) return attention.summary || "Needs attention";
    const providers = snapshot.providers || [];
    const enabled = providers.filter(p => p.enabled).length;
    return enabled > 0 ? `${enabled} quota source${enabled > 1 ? "s" : ""} — all clear` : "No quota sources enabled";
  }

  function ago(updated) {
    if (!updated) return "";
    const then = Date.parse(updated);
    if (isNaN(then)) return "";
    const mins = Math.max(0, Math.round((Date.now() - then) / 60000));
    if (mins < 1) return "just now";
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.round(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.round(hrs / 24)}d ago`;
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: 16
    spacing: 14

    // ----- header -----
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      NText {
        text: "Headroom"
        pointSize: 15
        font.weight: Font.DemiBold
        Layout.fillWidth: true
      }
      Rectangle {
        width: 8; height: 8; radius: 4
        color: root.statusColor
        Layout.alignment: Qt.AlignVCenter
      }
      NText {
        text: root.statusLine()
        color: Color.mOnSurfaceVariant
        pointSize: 10
        Layout.alignment: Qt.AlignVCenter
      }
    }

    // ----- rings grid -----
    GridLayout {
      Layout.fillWidth: true
      columns: Math.min(3, Math.max(1, (root.snapshot.providers || []).length))
      columnSpacing: 18
      rowSpacing: 18

      Repeater {
        model: root.snapshot.providers || []
        delegate: ColumnLayout {
          Layout.fillWidth: true
          spacing: 6

          HeadroomRing {
            id: ring
            Layout.alignment: Qt.AlignHCenter
            diameter: 56
            layers: root.ringLayersFor(modelData)
            tint: root.tintFor(modelData)
            unavailable: ring.layers.length === 0
          }

          NText {
            text: modelData.title || modelData.id
            pointSize: 10
            font.weight: Font.Medium
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
          }

          NText {
            text: {
              const pct = root.percentUsed(modelData);
              if (pct === null) return "—";
              return `${Math.round(pct)}% used`;
            }
            color: Color.mOnSurfaceVariant
            pointSize: 9
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
          }
        }
      }
    }

    // ----- daily burn -----
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: 64
      radius: 8
      color: Color.mSurfaceContainerHighest
      visible: (root.snapshot.byDay || []).length > 0

      Canvas {
        id: burnCanvas
        anchors.fill: parent
        anchors.margins: 8

        onPaint: {
          const ctx = getContext("2d");
          ctx.reset();
          const days = root.snapshot.byDay || [];
          if (days.length === 0) return;
          const maxBurn = Math.max.apply(null, days.map(d => d.total || 0));
          if (maxBurn <= 0) return;

          const providers = root.snapshot.providers || [];
          const byId = {};
          providers.forEach(p => { if (p.id) byId[p.id] = p; });
          const focus = (root.snapshot.focus || []).filter(id => byId[id]);

          const barW = Math.max(3, (width - (days.length - 1) * 3) / days.length);
          for (let d = 0; d < days.length; ++d) {
            const day = days[d];
            const x = d * (barW + 3);
            const h = Math.max(2, height * (day.total / maxBurn));
            // stack burns per focus provider, focus order on top
            let y = height;
            for (let i = focus.length - 1; i >= 0; --i) {
              const id = focus[i];
              const burn = (day.burns && day.burns[id]) || 0;
              if (burn <= 0) continue;
              const segH = height * (burn / maxBurn);
              ctx.fillStyle = root.tintFor(byId[id]);
              ctx.fillRect(x, y - segH, barW, segH);
              y -= segH;
            }
            if (y === height) {
              ctx.fillStyle = Qt.rgba(1, 1, 1, 0.12);
              ctx.fillRect(x, height - 2, barW, 2);
            }
          }
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        Connections {
          target: root
          function onSnapshotChanged() { burnCanvas.requestPaint(); }
        }
      }
    }

    // ----- footer -----
    RowLayout {
      Layout.fillWidth: true
      NText {
        text: root.ago(root.snapshot.updated)
        color: Color.mOnSurfaceVariant
        pointSize: 9
        Layout.fillWidth: true
      }
    }
  }
}
