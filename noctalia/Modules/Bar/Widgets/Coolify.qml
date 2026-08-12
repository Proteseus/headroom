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
  STORY: Glance at the deployment rail, then expand it in place to identify
  each application, its state, and how recently that state changed.
  FIRST VIEWPORT: Cloud glyph followed by up to four state markers. A click
  opens those markers into a labelled deployment strip without leaving the bar.
  FORM: Expandable operational rail extending Noctalia's capsule language;
  horizontal expansion is the authored moment and live motion stays purposeful.
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
  readonly property bool effectiveExpanded: expanded && !isVertical
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
  readonly property var detailDeployments: activeDeployments.concat(failedDeployments).slice(0, 3)
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
  property bool expanded: false

  implicitWidth: isVertical
                 ? Style.capsuleHeight
                 : Math.round(content.implicitWidth + Style.marginS * 2)
  implicitHeight: isVertical
                  ? Math.round(content.implicitHeight + Style.marginS * 2)
                  : Style.capsuleHeight
  clip: true
  radius: Style.radiusXS
  color: hovering ? Color.mHover : Style.capsuleColor
  border.width: Style.borderS
  border.color: hovering ? Color.mHover : Color.transparent

  Accessible.role: Accessible.Button
  Accessible.name: accessibleLabel()
  Accessible.description: makeTooltip()
  Accessible.onPressAction: root.activate()
  activeFocusOnTab: true

  Keys.onReturnPressed: root.activate()
  Keys.onEnterPressed: root.activate()
  Keys.onSpacePressed: root.activate()

  onIsVerticalChanged: {
    if (isVertical) expanded = false;
  }

  Behavior on color {
    ColorAnimation {
      duration: Style.animationFast
      easing.type: Easing.InOutQuad
    }
  }

  Behavior on implicitWidth {
    NumberAnimation {
      duration: Style.animationNormal
      easing.type: Easing.OutExpo
    }
  }

  function normalizedHostUrl(value) {
    let url = String(value || "http://localhost:8737").trim();
    while (url.length > 0 && url.endsWith("/")) url = url.slice(0, -1);
    return url;
  }

  function accessibleLabel() {
    const disclosure = effectiveExpanded ? "expanded" : "collapsed";
    if (!healthy) return "Coolify deployments — Headroom host not answering, " + disclosure;
    if (coolify.auth_required || !coolify.configured) return "Coolify deployments — not connected, " + disclosure;
    if (coolify.stale) return "Coolify deployments — cached data, refresh failed, " + disclosure;
    if (failureCount > 0) return "Coolify deployments — " + failureCount + " recent failure" + (failureCount === 1 ? "" : "s") + ", " + disclosure;
    if (activeCount > 0) return "Coolify deployments — " + activeCount + " active, " + disclosure;
    return "Coolify deployments — idle, " + disclosure;
  }

  function compactName(value) {
    const name = String(value || "Application");
    return name.length > 18 ? name.slice(0, 17) + "…" : name;
  }

  function emptyDetailText() {
    if (!healthy) return "Host unavailable";
    if (coolify.auth_required) return "Coolify token rejected";
    if (!coolify.configured) return "Coolify not connected";
    if (coolify.stale) return "Cached · refresh failed";
    if (coolify.ok === false) return coolify.error || "Coolify unavailable";
    return "No active deployments";
  }

  function activate() {
    TooltipService.hide();
    if (!isVertical) expanded = !expanded;
    poll();
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
    const action = isVertical ? "Refresh" : (effectiveExpanded ? "Click to collapse" : "Click to expand");
    const prefix = coolify.stale ? "Coolify — cached; refresh failed\n" : "Coolify\n";
    return lines.length > 0 ? prefix + lines.join("\n") + "\n\n" + action : (
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

    Item {
      id: disclosureViewport

      Layout.preferredWidth: root.effectiveExpanded
                             ? expandedContent.implicitWidth
                             : compactContent.implicitWidth
      Layout.preferredHeight: Math.max(compactContent.implicitHeight,
                                       expandedContent.implicitHeight)
      Layout.alignment: Qt.AlignCenter
      clip: true

      Behavior on Layout.preferredWidth {
        NumberAnimation {
          duration: Style.animationNormal
          easing.type: Easing.OutExpo
        }
      }

      RowLayout {
        id: compactContent
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.marginXS
        opacity: root.effectiveExpanded ? 0 : 1
        visible: opacity > 0

        Behavior on opacity {
          NumberAnimation {
            duration: Style.animationFast
            easing.type: Easing.OutQuad
          }
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

      RowLayout {
        id: expandedContent
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.marginS
        opacity: root.effectiveExpanded ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
          NumberAnimation {
            duration: Style.animationFast
            easing.type: Easing.OutQuad
          }
        }

        Repeater {
          model: root.detailDeployments

          delegate: RowLayout {
            required property var modelData
            required property int index

            spacing: Style.marginXS

            Rectangle {
              width: Math.max(7, Math.round(7 * Style.uiScaleRatio))
              height: width
              radius: width / 2
              color: root.markerColor(modelData)
              Layout.alignment: Qt.AlignCenter
            }

            NText {
              text: root.compactName(modelData.application_name)
              pointSize: Style.fontSizeS
              font.weight: Style.fontWeightSemiBold
              color: root.hovering ? Color.mOnHover : Color.mOnSurface
              Layout.alignment: Qt.AlignCenter
            }

            NText {
              text: modelData.status_label || modelData.status || "Unknown"
              pointSize: Style.fontSizeXS
              color: root.hovering ? Color.mOnHover : root.markerColor(modelData)
              Layout.alignment: Qt.AlignCenter
            }

            NText {
              visible: Boolean(modelData.ago)
              text: modelData.ago || ""
              pointSize: Style.fontSizeXS
              color: root.hovering ? Color.mOnHover : Color.mOnSurfaceVariant
              Layout.alignment: Qt.AlignCenter
            }

            Rectangle {
              visible: index < root.detailDeployments.length - 1
              width: Style.borderS
              height: Math.round(Style.capsuleHeight * 0.42)
              color: root.hovering ? Color.mOnHover : Color.mOutline
              opacity: 0.55
              Layout.alignment: Qt.AlignCenter
            }
          }
        }

        NText {
          visible: root.activeCount + root.failureCount > root.detailDeployments.length
          text: "+" + (root.activeCount + root.failureCount - root.detailDeployments.length)
          pointSize: Style.fontSizeXS
          font.weight: Style.fontWeightSemiBold
          color: root.hovering ? Color.mOnHover : Color.mOnSurfaceVariant
          Layout.alignment: Qt.AlignCenter
        }

        NText {
          visible: root.detailDeployments.length === 0
          text: root.emptyDetailText()
          pointSize: Style.fontSizeS
          color: root.hovering ? Color.mOnHover : Color.mOnSurfaceVariant
          Layout.alignment: Qt.AlignCenter
        }
      }
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
      root.activate();
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
