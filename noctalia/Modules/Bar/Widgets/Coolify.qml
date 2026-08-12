import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Services.UI
import qs.Widgets

/*
  THESIS: A deployment signal should read like a live rail, not another quota
  meter; work appears, advances, and clears while failures stay planted.
  OWN-WORLD: Noctalia's flat capsule, system type, semantic colors, one cloud
  glyph and a short rail of deployment-state markers.
  STORY: See whether each current Coolify deployment is building, waiting, or
  failed directly in the bar; hover for application and commit detail.
  FIRST VIEWPORT: Cloud glyph left/top followed by up to four state markers and
  a compact overflow count. Idle keeps the same compact footprint.
  FORM: Operational status capsule extending the established bar language;
  live motion belongs only to in-progress work.
*/
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
                                               : (widgetMetadata.pollInterval || 15)) || 15)
  readonly property bool isVertical: Settings.data.bar.position === "left"
                                     || Settings.data.bar.position === "right"
  readonly property var coolify: snapshot.coolify || ({})
  readonly property var activeDeployments: Array.isArray(coolify.active) ? coolify.active : []
  readonly property var failedDeployments: Array.isArray(coolify.failures) ? coolify.failures : []
  readonly property int activeCount: Number(coolify.active_count) || activeDeployments.length
  readonly property int failureCount: Number(coolify.failure_count) || failedDeployments.length
  readonly property int runningCount: activeDeployments.filter(function (deployment) {
    return deployment.status === "in_progress";
  }).length
  readonly property int queuedCount: activeDeployments.filter(function (deployment) {
    return deployment.status === "queued";
  }).length
  readonly property var visibleStates: activeDeployments.concat(failedDeployments).slice(0, 4)
  readonly property int hiddenStateCount: Math.max(
                                           0,
                                           activeCount + failureCount - visibleStates.length)
  readonly property bool sourceLive: healthy && coolify.ok === true && coolify.stale !== true
  readonly property color stateColor: {
    if (!healthy || coolify.auth_required || coolify.ok === false) return Color.mError;
    if (failureCount > 0) return Color.mError;
    if (runningCount > 0) return Color.mPrimary;
    if (queuedCount > 0) return Color.mTertiary;
    return Color.mOnSurfaceVariant;
  }

  property var snapshot: ({})
  property bool healthy: false
  property bool requestPending: false
  property bool hovering: false

  implicitWidth: isVertical
                 ? Style.capsuleHeight
                 : Math.round(content.implicitWidth + Style.marginS * 2)
  implicitHeight: isVertical
                  ? Math.round(content.implicitHeight + Style.marginS * 2)
                  : Style.capsuleHeight
  radius: Style.radiusXS
  color: hovering ? Color.mHover : Style.capsuleColor
  border.width: Style.borderS
  border.color: hovering ? Color.mHover : Color.transparent

  Accessible.role: Accessible.Button
  Accessible.name: accessibleLabel()
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

  function accessibleLabel() {
    if (!healthy) return "Coolify deployments — Headroom host not answering";
    if (coolify.auth_required || !coolify.configured) return "Coolify deployments — not connected";
    if (coolify.stale) return "Coolify deployments — cached data, refresh failed";
    if (failureCount > 0) return "Coolify deployments — " + failureCount + " recent failure" + (failureCount === 1 ? "" : "s");
    if (activeCount > 0) return "Coolify deployments — " + activeCount + " active";
    return "Coolify deployments — idle";
  }

  function deploymentSummary(deployment) {
    const name = deployment.application_name || "Application";
    const state = deployment.status_label || deployment.status || "Unknown";
    const age = deployment.ago ? " · " + deployment.ago : "";
    return name + " — " + state + age;
  }

  function markerColor(deployment) {
    if (deployment.status === "failed") return Color.mError;
    if (deployment.status === "queued") return Color.mTertiary;
    return Color.mPrimary;
  }

  function makeTooltip() {
    if (!healthy) return "Coolify — Headroom host not answering";
    if (coolify.auth_required) return "Coolify — API token rejected or missing";
    if (!coolify.configured) return "Coolify — not connected";
    const lines = [];
    activeDeployments.slice(0, 3).forEach(function (deployment) {
      lines.push(deploymentSummary(deployment));
    });
    failedDeployments.slice(0, Math.max(0, 3 - lines.length)).forEach(function (deployment) {
      lines.push(deploymentSummary(deployment));
    });
    const prefix = coolify.stale ? "Coolify — cached; refresh failed\n" : "Coolify\n";
    return lines.length > 0 ? prefix + lines.join("\n") : (
      coolify.error ? "Coolify — " + coolify.error : "Coolify — no active deployments");
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
          healthy = true;
        } catch (error) {
          healthy = false;
          Logger.w("Bar:Coolify", "Invalid /usage response:", error);
        }
      } else {
        healthy = false;
      }
    };
    request.open("GET", hostUrl + "/usage", true);
    request.send();
  }

  GridLayout {
    id: content
    anchors.centerIn: parent
    flow: root.isVertical ? GridLayout.TopToBottom : GridLayout.LeftToRight
    rows: root.isVertical ? -1 : 1
    columns: root.isVertical ? 1 : -1
    rowSpacing: Style.marginXXS
    columnSpacing: Style.marginXS

    NIcon {
      icon: "cloud-upload"
      pointSize: Style.fontSizeL
      color: root.hovering ? Color.mOnHover : Color.mOnSurface
      Layout.alignment: Qt.AlignCenter
    }

    Repeater {
      model: root.visibleStates

      delegate: Rectangle {
        required property var modelData

        width: Math.max(7, Math.round(7 * Style.uiScaleRatio))
        height: width
        radius: width / 2
        color: root.markerColor(modelData)
        opacity: 1
        Layout.alignment: Qt.AlignCenter

        SequentialAnimation on opacity {
          running: modelData.status === "in_progress" && root.sourceLive
          loops: Animation.Infinite
          NumberAnimation {
            to: 0.35
            duration: 700
            easing.type: Easing.OutQuad
          }
          NumberAnimation {
            to: 1
            duration: 1100
            easing.type: Easing.OutExpo
          }
        }
      }
    }

    NText {
      visible: root.hiddenStateCount > 0
      text: "+" + root.hiddenStateCount
      pointSize: Style.fontSizeXS
      font.weight: Style.fontWeightSemiBold
      color: root.hovering ? Color.mOnHover : Color.mOnSurfaceVariant
      Layout.alignment: Qt.AlignCenter
    }

    Rectangle {
      visible: root.visibleStates.length === 0
      width: Math.max(6, Math.round(6 * Style.uiScaleRatio))
      height: width
      radius: width / 2
      color: root.stateColor
      Layout.alignment: Qt.AlignCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
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
    onClicked: function (mouse) {
      TooltipService.hide();
      if (mouse.button === Qt.RightButton) {
        BarService.openWidgetSettings(
          root.screen, root.section, root.sectionWidgetIndex,
          root.widgetId, root.widgetSettings);
        return;
      }
      root.poll();
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
