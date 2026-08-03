import QtQuick
import qs.Commons
import qs.Modules.MainScreen
import qs.Widgets

// Lazy panel wrapper: overview content is instantiated only after click.
SmartPanel {
  id: root
  property var snapshot: ({})
  property bool healthy: false
  preferredWidth: Math.round(360 * Style.uiScaleRatio)
  preferredHeight: Math.round(420 * Style.uiScaleRatio)
  panelContent: Component {
    HeadroomPanelContent {
      snapshot: root.snapshot
      healthy: root.healthy
    }
  }
}
