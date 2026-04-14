import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Modules.DesktopWidgets
import qs.Services.UI
import qs.Widgets

DraggableDesktopWidget {
  id: root

  required property var pluginApi

  defaultX: 120
  defaultY: 180

  readonly property var service: pluginApi?.mainInstance || null
  readonly property var widgetMeta: pluginApi?.manifest?.metadata || {}

  readonly property int widgetWidth: widgetData?.width !== undefined ? Number(widgetData.width) : Number(widgetMeta.width || 520)
  readonly property int contextLines: widgetData?.contextLines !== undefined ? Number(widgetData.contextLines) : Number(widgetMeta.contextLines || 1)
  readonly property int currentFontSize: widgetData?.fontSize !== undefined ? Number(widgetData.fontSize) : Number(widgetMeta.fontSize || 22)
  readonly property bool showTrackMeta: widgetData?.showTrackMeta !== undefined ? !!widgetData.showTrackMeta : !!widgetMeta.showTrackMeta
  readonly property bool hideWhenIdle: widgetData?.hideWhenIdle !== undefined ? !!widgetData.hideWhenIdle : !!widgetMeta.hideWhenIdle
  readonly property string textAlign: widgetData?.textAlign !== undefined ? String(widgetData.textAlign) : String(widgetMeta.textAlign || "center")
  readonly property real inactiveOpacity: widgetData?.inactiveOpacity !== undefined ? Number(widgetData.inactiveOpacity) : Number(widgetMeta.inactiveOpacity || 0.56)
  readonly property int lineSpacing: widgetData?.lineSpacing !== undefined ? Number(widgetData.lineSpacing) : Number(widgetMeta.lineSpacing || 8)
  readonly property bool isHidden: hideWhenIdle && !(service?.hasActiveTrack || false) && !DesktopWidgetRegistry.editMode
  readonly property var displayRows: buildDisplayRows()
  readonly property int visibleRowCount: Math.max(1, displayRows.length)

  function statusText() {
    return service?.stateLabel || "";
  }

  function buildDisplayRows() {
    if (!service)
      return [];

    if (service.hasSyncedLyrics) {
      var rows = [];
      var start;
      var end;

      if (service.currentLineIndex >= 0) {
        start = Math.max(0, service.currentLineIndex - contextLines);
        end = Math.min(service.lyricsEntries.length - 1, service.currentLineIndex + contextLines);
        for (var i = start; i <= end; i++) {
          rows.push({
                      "text": service.lyricsEntries[i].text,
                      "role": i === service.currentLineIndex ? "current" : "context"
                    });
        }
        return rows;
      }

      end = Math.min(service.lyricsEntries.length - 1, contextLines * 2);
      for (var j = 0; j <= end; j++) {
        rows.push({
                    "text": service.lyricsEntries[j].text,
                    "role": j === 0 ? "upcoming" : "context"
                  });
      }
      return rows;
    }

    if (service.hasPlainLyrics) {
      var plainRows = [];
      var maxRows = Math.max(1, contextLines * 2 + 1);
      for (var k = 0; k < Math.min(maxRows, service.plainLyricsLines.length); k++) {
        plainRows.push({
                        "text": service.plainLyricsLines[k],
                        "role": "plain"
                      });
      }
      return plainRows;
    }

    return [
      {
        "text": statusText(),
        "role": "status"
      }
    ];
  }

  function rowColor(role) {
    switch (role) {
    case "current":
      return Color.mPrimary;
    case "upcoming":
      return Color.mSecondary;
    case "status":
      return Color.mOnSurfaceVariant;
    default:
      return Color.mOnSurface;
    }
  }

  function rowOpacity(role) {
    switch (role) {
    case "current":
      return 1;
    case "upcoming":
      return 0.82;
    case "plain":
      return 0.88;
    case "status":
      return 0.72;
    default:
      return inactiveOpacity;
    }
  }

  function rowWeight(role) {
    return role === "current" ? Style.fontWeightBold : Style.fontWeightMedium;
  }

  function rowPointSize(role) {
    if (role === "current")
      return currentFontSize;
    if (role === "status")
      return Math.max(14, currentFontSize * 0.72);
    return Math.max(13, currentFontSize * 0.72);
  }

  function labelAlignment() {
    return textAlign === "left" ? Text.AlignLeft : Text.AlignHCenter;
  }

  implicitWidth: Math.round(widgetWidth * widgetScale)
  implicitHeight: Math.round(((showTrackMeta ? 70 : 26) + visibleRowCount * (currentFontSize * 1.8) + Math.max(0, visibleRowCount - 1) * lineSpacing + 46) * widgetScale)
  width: implicitWidth
  height: implicitHeight
  opacity: isHidden ? 0 : 1
  visible: !isHidden || opacity > 0

  Behavior on opacity {
    NumberAnimation {
      duration: Style.animationNormal
      easing.type: Easing.InOutCubic
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: roundedCorners ? Math.min(Math.round(Style.radiusL * widgetScale), width / 2, height / 2) : 0
    gradient: Gradient {
      GradientStop {
        position: 0
        color: Qt.rgba(Color.mPrimary.r, Color.mPrimary.g, Color.mPrimary.b, 0.11)
      }

      GradientStop {
        position: 0.55
        color: "transparent"
      }

      GradientStop {
        position: 1
        color: Qt.rgba(Color.mSecondary.r, Color.mSecondary.g, Color.mSecondary.b, 0.08)
      }
    }
    visible: root.showBackground
    z: 0
  }

  SequentialAnimation {
    id: lyricPulse
    running: false

    NumberAnimation {
      target: lyricColumn
      property: "opacity"
      to: 0.72
      duration: 80
      easing.type: Easing.OutCubic
    }

    NumberAnimation {
      target: lyricColumn
      property: "opacity"
      to: 1
      duration: 200
      easing.type: Easing.OutCubic
    }
  }

  Connections {
    target: service
    enabled: service !== null

    function onLyricRevisionChanged() {
      lyricPulse.restart();
    }
  }

  ColumnLayout {
    anchors.fill: parent
    anchors.margins: Math.round(Style.marginL * widgetScale)
    spacing: Math.round(Style.marginM * widgetScale)
    z: 1

    ColumnLayout {
      visible: showTrackMeta
      Layout.fillWidth: true
      spacing: Math.round(Style.marginXXS * widgetScale)

      NText {
        Layout.fillWidth: true
        text: service?.trackTitle || statusText()
        pointSize: Math.max(14, currentFontSize * 0.68)
        font.weight: Style.fontWeightBold
        color: Color.mOnSurface
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        horizontalAlignment: root.labelAlignment()
      }

      NText {
        Layout.fillWidth: true
        text: service?.trackArtist || ""
        visible: text !== ""
        pointSize: Math.max(12, currentFontSize * 0.48)
        color: Color.mOnSurfaceVariant
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        horizontalAlignment: root.labelAlignment()
      }
    }

    ColumnLayout {
      id: lyricColumn
      Layout.fillWidth: true
      Layout.fillHeight: true
      spacing: Math.round(lineSpacing * widgetScale)

      Repeater {
        model: root.displayRows

        delegate: Text {
          required property var modelData

          Layout.fillWidth: true
          text: modelData.text
          color: root.rowColor(modelData.role)
          opacity: root.rowOpacity(modelData.role)
          font.family: Settings.data.ui.fontDefault
          font.pointSize: Math.max(1, root.rowPointSize(modelData.role) * Style.uiScaleRatio * Settings.data.ui.fontDefaultScale)
          font.weight: root.rowWeight(modelData.role)
          wrapMode: Text.WordWrap
          horizontalAlignment: root.labelAlignment()
          verticalAlignment: Text.AlignVCenter
          maximumLineCount: modelData.role === "status" ? 2 : 3
          elide: Text.ElideRight
        }
      }
    }

    Rectangle {
      Layout.alignment: textAlign === "left" ? Qt.AlignLeft : Qt.AlignHCenter
      Layout.topMargin: Math.round(Style.marginXS * widgetScale)
      radius: Style.radiusS
      color: Qt.alpha(root.rowColor(service?.fetchState === "ready" ? "current" : "status"), 0.12)
      border.width: 1
      border.color: Qt.alpha(root.rowColor(service?.fetchState === "ready" ? "current" : "status"), 0.20)
      implicitHeight: Math.round(24 * widgetScale)
      implicitWidth: stateText.implicitWidth + Math.round(Style.marginM * widgetScale) * 2

      NText {
        id: stateText
        anchors.centerIn: parent
        text: statusText()
        pointSize: Math.max(11, currentFontSize * 0.42)
        color: root.rowColor(service?.fetchState === "ready" ? "current" : "status")
      }
    }
  }
}
