import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Modules.Bar.Widgets
import qs.Modules.MainScreen
import qs.Services.UI
import qs.Widgets

// HeadroomPanelContent — a quiet, glanceable quota dashboard.
Item {
  id: root

  property var snapshot: ({})
  property bool healthy: false

  Rectangle {
    anchors.fill: parent
    z: -1
    radius: Style.radiusM
    color: Color.mSurface
    border.width: Style.borderS
    border.color: Color.mOutline
  }

  readonly property color dimColor: Color.mOnSurfaceVariant

  readonly property var attention: snapshot.attention || ({})
  readonly property string attentionLevel: attention.level || ""
  readonly property bool attentionIsWarning: attention.level === "warn"
                                             || attention.level === "critical"
  readonly property color statusColor: {
    if (!root.healthy || attentionLevel === "critical") return Color.mError;
    if (attentionLevel === "warn") return Color.mTertiary;
    return Color.mPrimary;
  }

  // Keep the dashboard glanceable: prefer the configured focus order and
  // show at most three providers with real quota readings.
  function activeProviders() {
    const active = (snapshot.providers || []).filter(function (p) {
      if (!p || p.enabled === false) return false;
      return ringLayersFor(p).length > 0;
    });
    const byId = {};
    active.forEach(function (p) { if (p.id) byId[p.id] = p; });
    const focused = (snapshot.focus || []).map(function (id) { return byId[id]; }).filter(Boolean);
    return (focused.length > 0 ? focused : active).slice(0, 3);
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
    }
    return dimColor;
  }

  function ringLayersFor(provider) {
    const pools = provider.pools || {};
    const ids = Object.keys(pools);
    ids.sort(function (a, b) {
      if (provider.id === "opencode") {
        const order = { "monthly": 0, "weekly": 1, "5h": 2 };
        const oa = order[a] !== undefined ? order[a] : 999;
        const ob = order[b] !== undefined ? order[b] : 999;
        if (oa !== ob) return oa - ob;
      }
      const ra = pools[a].rank !== undefined ? pools[a].rank : 999;
      const rb = pools[b].rank !== undefined ? pools[b].rank : 999;
      return ra - rb || (a < b ? -1 : 1);
    });
    const layerLimit = provider.id === "opencode" ? 3 : 2;
    const layers = [];
    for (let i = 0; i < ids.length && layers.length < layerLimit; ++i) {
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

  function providerSubtext(provider) {
    const headline = provider.headline;
    const headlinePool = headline ? (provider.pools || {})[headline] : null;
    const percent = headlinePool && headlinePool.pct !== null
                    && headlinePool.pct !== undefined
                    ? headlinePool.pct
                    : (ringLayersFor(provider)[0] || {}).percent;
    if (percent === null || percent === undefined) return "No reading";
    const left = Math.max(0, 100 - Math.round(percent));
    return left + "% left";
  }

  function statusLine() {
    if (!root.healthy) return "Host not answering";
    if (attentionIsWarning) return attention.summary || "Needs attention";
    const count = root.activeProviders().length;
    return count > 0 ? "All clear · " + count + " source" + (count > 1 ? "s" : "") : "No active sources";
  }

  function ago(updated) {
    if (!updated) return "";
    const then = Date.parse(updated);
    if (isNaN(then)) return "";
    const mins = Math.max(0, Math.round((Date.now() - then) / 60000));
    if (mins < 1) return "just now";
    if (mins < 60) return mins + "m ago";
    const hrs = Math.round(mins / 60);
    if (hrs < 24) return hrs + "h ago";
    return Math.round(hrs / 24) + "d ago";
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Style.marginXL
    spacing: Style.marginL

    // ----- header -----
    RowLayout {
      Layout.fillWidth: true
      spacing: 8
      NText {
        text: "Headroom"
        pointSize: Style.fontSizeXL
        font.weight: Style.fontWeightSemiBold
        Layout.fillWidth: true
      }
      Rectangle {
        width: 7
        height: width
        radius: width / 2
        color: root.statusColor
        Layout.alignment: Qt.AlignVCenter
      }
      NText {
        text: root.statusLine()
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeS
        Layout.alignment: Qt.AlignVCenter
      }
    }

    // ----- rings grid: equal columns keep labels and values aligned -----
    GridLayout {
      Layout.fillWidth: true
      columns: Math.min(3, Math.max(1, root.activeProviders().length))
      rowSpacing: Style.marginL
      columnSpacing: Style.marginM

      Repeater {
        model: root.activeProviders()
        delegate: ColumnLayout {
          Layout.fillWidth: true
          Layout.preferredWidth: 96
          spacing: Style.marginXS

          HeadroomRing {
            id: ring
            Layout.alignment: Qt.AlignHCenter
            diameter: Math.round(56 * Style.uiScaleRatio)
            layers: root.ringLayersFor(modelData)
            tint: root.tintFor(modelData)
            indicatorColor: Color.mOnSurface
            unavailable: ring.layers.length === 0
          }

          NText {
            text: modelData.title || modelData.id
            pointSize: Style.fontSizeM
            font.weight: Style.fontWeightMedium
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            Layout.fillWidth: true
          }

          NText {
            text: root.providerSubtext(modelData)
            color: Color.mOnSurfaceVariant
            pointSize: Style.fontSizeXS
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
          }
        }
      }
    }

    NText {
      visible: root.activeProviders().length === 0
      text: root.healthy ? "Waiting for quota readings" : "Check the Headroom host and try again"
      color: Color.mOnSurfaceVariant
      pointSize: Style.fontSizeM
      horizontalAlignment: Text.AlignHCenter
      Layout.fillWidth: true
      Layout.preferredHeight: Math.round(72 * Style.uiScaleRatio)
      verticalAlignment: Text.AlignVCenter
    }

    // ----- daily burn -----
    RowLayout {
      visible: (root.snapshot.byDay || []).length > 0
      Layout.fillWidth: true

      NText {
        text: "Daily burn"
        pointSize: Style.fontSizeS
        font.weight: Style.fontWeightMedium
        Layout.fillWidth: true
      }

      NText {
        text: (root.snapshot.byDay || []).length + " days"
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeXS
      }
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.round(64 * Style.uiScaleRatio)
      radius: Style.radiusXS
      color: Color.mSurfaceVariant
      visible: (root.snapshot.byDay || []).length > 0

      Canvas {
        id: burnCanvas
        anchors.fill: parent
        anchors.margins: Style.marginM

        onPaint: {
          const ctx = getContext("2d");
          ctx.reset();
          const days = root.snapshot.byDay || [];
          if (days.length === 0) return;
          const maxBurn = Math.max.apply(null, days.map(function (d) { return d.total || 0; }));
          if (maxBurn <= 0) return;

          const providers = root.snapshot.providers || [];
          const byId = {};
          providers.forEach(function (p) { if (p.id) byId[p.id] = p; });
          const focus = (root.snapshot.focus || []).filter(function (id) { return byId[id]; });

          const barW = Math.max(3, (width - (days.length - 1) * 3) / days.length);
          for (let d = 0; d < days.length; ++d) {
            const day = days[d];
            const x = d * (barW + 3);
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
        text: {
          const elapsed = root.ago(root.snapshot.updated);
          return elapsed ? "Updated " + elapsed : "Waiting for first update";
        }
        color: Color.mOnSurfaceVariant
        pointSize: Style.fontSizeXS
        Layout.fillWidth: true
      }
    }
  }
}
