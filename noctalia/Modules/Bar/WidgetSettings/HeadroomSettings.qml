import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root
  spacing: Style.marginM

  property var widgetData: null
  property var widgetMetadata: null

  property string valueHostUrl: widgetData && widgetData.hostUrl !== undefined
                                   ? widgetData.hostUrl
                                   : (widgetMetadata && widgetMetadata.hostUrl !== undefined
                                      ? widgetMetadata.hostUrl
                                      : "http://localhost:8737")
  property int valuePollInterval: widgetData && widgetData.pollInterval !== undefined
                                    ? widgetData.pollInterval
                                    : (widgetMetadata && widgetMetadata.pollInterval !== undefined
                                       ? widgetMetadata.pollInterval
                                       : 30)

  function saveSettings() {
    const settings = Object.assign({}, widgetData || {});
    let url = hostUrlInput.text.trim();
    while (url.length > 0 && url.endsWith("/")) {
      url = url.slice(0, -1);
    }
    settings.hostUrl = url || "http://localhost:8737";
    settings.pollInterval = valuePollInterval;
    return settings;
  }

  NTextInput {
    id: hostUrlInput
    Layout.fillWidth: true
    label: "Host URL"
    description: "Base URL of the Headroom host. Do not include /usage."
    placeholderText: "http://localhost:8737"
    text: root.valueHostUrl
  }

  NSpinBox {
    label: "Poll interval"
    description: "Refresh interval when the widget is not hovered. Hovering refreshes every 5 seconds."
    value: root.valuePollInterval
    suffix: " s"
    from: 5
    to: 3600
    onValueChanged: root.valuePollInterval = value
  }
}
