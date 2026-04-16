import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Services.Media
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  required property var pluginApi

  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var service: pluginApi?.mainInstance || null
  readonly property string screenName: screen ? screen.name : ""
  readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
  readonly property real maxWidth: pluginApi?.pluginSettings?.barMaxWidth !== undefined ? Number(pluginApi.pluginSettings.barMaxWidth) : 180
  readonly property string barWidthMode: {
    var mode = pluginApi?.pluginSettings?.barWidthMode;
    return mode === "fixed" ? "fixed" : "adaptive";
  }
  readonly property bool hideWhenIdle: pluginApi?.pluginSettings?.barHideWhenIdle !== undefined ? !!pluginApi.pluginSettings.barHideWhenIdle : true
  readonly property bool showStatusDot: pluginApi?.pluginSettings?.showBarStatusDot !== undefined ? !!pluginApi.pluginSettings.showBarStatusDot : true
  readonly property bool shouldHide: hideWhenIdle && !(service?.hasActiveTrack || false)
  readonly property string displayText: service?.barText || ""
  readonly property real dotSize: Math.max(6, Math.round(capsuleHeight * 0.16))
  readonly property real textPointSize: Math.max(Style.fontSizeXS, capsuleHeight * 0.24)
  readonly property real textLimit: Math.max(140, maxWidth - Style.marginL * 3 - (showStatusDot ? dotSize + Style.marginS : 0))
  readonly property real textContentWidth: Math.max(0, textMeasure.contentWidth)
  readonly property bool textOverflow: textContentWidth > textLimit + 1
  readonly property real contentWidth: {
    var total = textContentWidth + Style.marginL * 2;
    if (showStatusDot)
      total += dotSize + Style.marginS;
    return Math.min(maxWidth, Math.max(total, showStatusDot ? 72 : 56));
  }
  readonly property real targetWidth: barWidthMode === "fixed" ? maxWidth : contentWidth

  function statusColor() {
    if (!service)
      return Color.mOutline;
    switch (service.fetchState) {
    case "ready":
      return Color.mPrimary;
    case "plain":
      return Color.mSecondary;
    case "loading":
      return Color.mTertiary;
    case "error":
      return Color.mError;
    default:
      return Color.mOutline;
    }
  }

  function textColor() {
    if (!service)
      return Color.mOnSurfaceVariant;
    switch (service.fetchState) {
    case "ready":
      return Color.mOnSurface;
    case "plain":
      return Color.mOnSurface;
    case "loading":
      return Color.mOnSurfaceVariant;
    case "error":
      return Color.mOnSurfaceVariant;
    default:
      return Color.mOnSurfaceVariant;
    }
  }

  implicitWidth: shouldHide ? 0 : targetWidth
  implicitHeight: capsuleHeight
  opacity: shouldHide ? 0 : 1
  visible: !shouldHide || opacity > 0

  Behavior on implicitWidth {
    NumberAnimation {
      duration: Style.animationNormal
      easing.type: Easing.InOutCubic
    }
  }

  Behavior on opacity {
    NumberAnimation {
      duration: Style.animationNormal
      easing.type: Easing.InOutCubic
    }
  }

  NText {
    id: textMeasure
    visible: false
    text: displayText
    pointSize: textPointSize
    elide: Text.ElideNone
    wrapMode: Text.NoWrap
  }

  NPopupContextMenu {
    id: contextMenu
    model: [
      {
        "label": pluginApi?.tr("actions.refresh") || "Refresh Lyrics",
        "action": "refresh",
        "icon": "disc",
        "enabled": service?.hasActiveTrack || false
      },
      {
        "label": I18n.tr("actions.widget-settings"),
        "action": "widget-settings",
        "icon": "settings"
      }
    ]

    onTriggered: action => {
      contextMenu.close();
      PanelService.closeContextMenu(screen);

      if (action === "refresh")
        service?.refetchLyrics(true);
      else if (action === "widget-settings")
        BarService.openPluginSettings(screen, pluginApi.manifest);
    }
  }

  Rectangle {
    id: capsule
    anchors.centerIn: parent
    width: root.width
    height: capsuleHeight
    radius: Style.radiusM
    color: Style.capsuleColor
    border.width: Style.capsuleBorderWidth
    border.color: Style.capsuleBorderColor
    antialiasing: true
    transformOrigin: Item.Center

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.marginM
      anchors.rightMargin: Style.marginM
      spacing: Style.marginS

      Rectangle {
        visible: showStatusDot
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredWidth: visible ? dotSize : 0
        Layout.preferredHeight: visible ? dotSize : 0
        radius: dotSize / 2
        color: root.statusColor()
        opacity: service?.fetchState === "loading" ? 0.65 : 1

        SequentialAnimation on opacity {
          running: visible && service?.fetchState === "loading"
          loops: Animation.Infinite

          NumberAnimation {
            to: 0.2
            duration: 700
            easing.type: Easing.InOutSine
          }

          NumberAnimation {
            to: 1
            duration: 700
            easing.type: Easing.InOutSine
          }
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        Layout.preferredHeight: capsuleHeight

        Item {
          anchors.fill: parent
          visible: !root.textOverflow || !mouseArea.containsMouse
          clip: true

          NText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: displayText
            pointSize: textPointSize
            color: root.textColor()
            elide: Text.ElideNone
          }

          Rectangle {
            visible: root.textOverflow
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: Math.max(18, parent.width * 0.14)
            color: "transparent"
            topRightRadius: Style.radiusM
            bottomRightRadius: Style.radiusM
            gradient: Gradient {
              orientation: Gradient.Horizontal

              GradientStop {
                position: 0.0
                color: Qt.rgba(capsule.color.r, capsule.color.g, capsule.color.b, 0)
              }

              GradientStop {
                position: 1.0
                color: capsule.color
              }
            }
          }
        }

        NScrollText {
          anchors.fill: parent
          visible: root.textOverflow && mouseArea.containsMouse
          text: displayText
          maxWidth: textLimit
          scrollMode: NScrollText.ScrollMode.Hover
          forcedHover: mouseArea.containsMouse
          fadeExtent: 0.08
          fadeCornerRadius: Style.radiusM
          fadeRoundLeftCorners: showStatusDot

          NText {
            pointSize: textPointSize
            color: root.textColor()
          }
        }
      }

    }

    MouseArea {
      id: mouseArea
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onClicked: mouse => {
        if (mouse.button === Qt.RightButton) {
          PanelService.showContextMenu(contextMenu, root, screen);
          return;
        }

        BarService.openPluginSettings(screen, pluginApi.manifest);
      }

      onEntered: {
        if (service?.tooltipText)
          TooltipService.show(root, service.tooltipText, BarService.getTooltipDirection(screen?.name));
      }

      onExited: TooltipService.hide()
    }
  }
}
