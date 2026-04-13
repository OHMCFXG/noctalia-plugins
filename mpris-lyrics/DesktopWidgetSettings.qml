import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  required property var pluginApi
  required property var widgetSettings

  signal settingsChanged(var settings)

  readonly property var widgetMeta: widgetSettings?.metadata || pluginApi?.manifest?.metadata || {}
  property var draft: ({
      "width": widgetSettings?.data?.width !== undefined ? Number(widgetSettings.data.width) : Number(widgetMeta.width || 520),
      "contextLines": widgetSettings?.data?.contextLines !== undefined ? Number(widgetSettings.data.contextLines) : Number(widgetMeta.contextLines || 1),
      "fontSize": widgetSettings?.data?.fontSize !== undefined ? Number(widgetSettings.data.fontSize) : Number(widgetMeta.fontSize || 22),
      "showTrackMeta": widgetSettings?.data?.showTrackMeta !== undefined ? !!widgetSettings.data.showTrackMeta : !!widgetMeta.showTrackMeta,
      "hideWhenIdle": widgetSettings?.data?.hideWhenIdle !== undefined ? !!widgetSettings.data.hideWhenIdle : !!widgetMeta.hideWhenIdle,
      "showBackground": widgetSettings?.data?.showBackground !== undefined ? !!widgetSettings.data.showBackground : !!widgetMeta.showBackground,
      "roundedCorners": widgetSettings?.data?.roundedCorners !== undefined ? !!widgetSettings.data.roundedCorners : !!widgetMeta.roundedCorners,
      "textAlign": widgetSettings?.data?.textAlign !== undefined ? String(widgetSettings.data.textAlign) : String(widgetMeta.textAlign || "center"),
      "inactiveOpacity": widgetSettings?.data?.inactiveOpacity !== undefined ? Math.round(Number(widgetSettings.data.inactiveOpacity) * 100) : Math.round(Number(widgetMeta.inactiveOpacity || 0.56) * 100),
      "lineSpacing": widgetSettings?.data?.lineSpacing !== undefined ? Number(widgetSettings.data.lineSpacing) : Number(widgetMeta.lineSpacing || 8)
    })

  spacing: Style.marginM

  function tr(key, fallback, vars) {
    if (pluginApi && pluginApi.tr) {
      var translated = pluginApi.tr(key, vars || {});
      if (translated && translated.indexOf("!!") !== 0)
        return translated;
    }
    return fallback;
  }

  function buildSettings() {
    var settings = Object.assign({}, widgetSettings?.data || {});
    settings.width = draft.width;
    settings.contextLines = draft.contextLines;
    settings.fontSize = draft.fontSize;
    settings.showTrackMeta = draft.showTrackMeta;
    settings.hideWhenIdle = draft.hideWhenIdle;
    settings.showBackground = draft.showBackground;
    settings.roundedCorners = draft.roundedCorners;
    settings.textAlign = draft.textAlign;
    settings.inactiveOpacity = Math.max(0.1, Math.min(0.95, draft.inactiveOpacity / 100));
    settings.lineSpacing = draft.lineSpacing;
    return settings;
  }

  function saveSettings() {
    var settings = buildSettings();
    settingsChanged(settings);
    return settings;
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("desktop.width-label", "Widget Width")
    description: tr("desktop.width-description", "Preferred card width in pixels.")
    from: 320
    to: 960
    stepSize: 10
    suffix: " px"
    value: draft.width
    onValueChanged: {
      draft.width = value;
      saveSettings();
    }
    defaultValue: widgetMeta.width
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("desktop.context-label", "Context Lines")
    description: tr("desktop.context-description", "How many lines before and after the current lyric are visible.")
    from: 0
    to: 3
    stepSize: 1
    value: draft.contextLines
    onValueChanged: {
      draft.contextLines = value;
      saveSettings();
    }
    defaultValue: widgetMeta.contextLines
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("desktop.font-size-label", "Current Line Size")
    description: tr("desktop.font-size-description", "Base font size for the highlighted lyric line.")
    from: 14
    to: 40
    stepSize: 1
    suffix: " pt"
    value: draft.fontSize
    onValueChanged: {
      draft.fontSize = value;
      saveSettings();
    }
    defaultValue: widgetMeta.fontSize
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("desktop.line-spacing-label", "Line Spacing")
    description: tr("desktop.line-spacing-description", "Extra spacing between lyric rows.")
    from: 0
    to: 20
    stepSize: 1
    suffix: " px"
    value: draft.lineSpacing
    onValueChanged: {
      draft.lineSpacing = value;
      saveSettings();
    }
    defaultValue: widgetMeta.lineSpacing
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("desktop.opacity-label", "Context Opacity")
    description: tr("desktop.opacity-description", "Opacity used by non-highlighted lyric lines.")
    from: 20
    to: 95
    stepSize: 1
    suffix: "%"
    value: draft.inactiveOpacity
    onValueChanged: {
      draft.inactiveOpacity = value;
      saveSettings();
    }
    defaultValue: Math.round(Number(widgetMeta.inactiveOpacity || 0.56) * 100)
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("desktop.align-label", "Text Alignment")
    description: tr("desktop.align-description", "Choose how lyrics are aligned inside the widget.")
    model: [
      {
        "key": "center",
        "name": tr("desktop.align-center", "Center")
      },
      {
        "key": "left",
        "name": tr("desktop.align-left", "Left")
      }
    ]
    currentKey: draft.textAlign
    onSelected: key => {
      draft.textAlign = key;
      saveSettings();
    }
    defaultValue: widgetMeta.textAlign
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.meta-label", "Show Track Meta")
    description: tr("desktop.meta-description", "Display song title and artist above the lyric block.")
    checked: draft.showTrackMeta
    onToggled: checked => {
      draft.showTrackMeta = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.showTrackMeta
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.hide-label", "Hide When Idle")
    description: tr("desktop.hide-description", "Hide the desktop widget when no playable track is active.")
    checked: draft.hideWhenIdle
    onToggled: checked => {
      draft.hideWhenIdle = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.hideWhenIdle
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.background-label", "Show Background")
    description: tr("desktop.background-description", "Use Noctalia's desktop widget surface behind the lyrics.")
    checked: draft.showBackground
    onToggled: checked => {
      draft.showBackground = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.showBackground
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.corners-label", "Rounded Corners")
    description: tr("desktop.corners-description", "Apply rounded clipping to the desktop widget container.")
    checked: draft.roundedCorners
    onToggled: checked => {
      draft.roundedCorners = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.roundedCorners
  }
}
