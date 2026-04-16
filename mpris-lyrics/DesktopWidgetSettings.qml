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

  spacing: Style.marginM

  function tr(key, fallback, vars) {
    if (pluginApi && pluginApi.tr) {
      var translated = pluginApi.tr(key, vars || {});
      if (translated && translated.indexOf("!!") !== 0)
        return translated;
    }
    return fallback;
  }

  function settingValue(key, fallback) {
    var data = widgetSettings?.data || {};
    var defaults = widgetMeta || {};
    if (data[key] !== undefined)
      return data[key];
    if (defaults[key] !== undefined)
      return defaults[key];
    return fallback;
  }

  function readNumberSetting(key, fallback) {
    return Number(settingValue(key, fallback));
  }

  function readBoolSetting(key, fallback) {
    return !!settingValue(key, fallback);
  }

  function normalizeTextAlign(value) {
    return value === "left" ? "left" : "center";
  }

  function buildSettings() {
    var settings = Object.assign({}, widgetSettings?.data || {});
    settings.width = editWidth;
    settings.contextLines = editContextLines;
    settings.fontSize = editFontSize;
    settings.showTrackMeta = editShowTrackMeta;
    settings.hideWhenIdle = editHideWhenIdle;
    settings.showBackground = editShowBackground;
    settings.roundedCorners = editRoundedCorners;
    settings.textAlign = editTextAlign;
    settings.inactiveOpacity = Math.max(0.1, Math.min(0.95, editInactiveOpacityPercent / 100));
    settings.lineSpacing = editLineSpacing;
    return settings;
  }

  function saveSettings() {
    var settings = buildSettings();
    settingsChanged(settings);
    return settings;
  }

  property int editWidth: readNumberSetting("width", 520)
  property int editContextLines: readNumberSetting("contextLines", 1)
  property int editFontSize: readNumberSetting("fontSize", 22)
  property int editLineSpacing: readNumberSetting("lineSpacing", 8)
  property int editInactiveOpacityPercent: Math.round(readNumberSetting("inactiveOpacity", 0.56) * 100)
  property string editTextAlign: normalizeTextAlign(settingValue("textAlign", "center"))
  property bool editShowTrackMeta: readBoolSetting("showTrackMeta", true)
  property bool editHideWhenIdle: readBoolSetting("hideWhenIdle", false)
  property bool editShowBackground: readBoolSetting("showBackground", true)
  property bool editRoundedCorners: readBoolSetting("roundedCorners", true)

  NSpinBox {
    Layout.fillWidth: true
    label: tr("desktop.width-label", "Widget Width")
    description: tr("desktop.width-description", "Preferred card width in pixels.")
    from: 320
    to: 960
    stepSize: 10
    suffix: " px"
    value: editWidth
    onValueChanged: {
      root.editWidth = value;
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
    value: editContextLines
    onValueChanged: {
      root.editContextLines = value;
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
    value: editFontSize
    onValueChanged: {
      root.editFontSize = value;
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
    value: editLineSpacing
    onValueChanged: {
      root.editLineSpacing = value;
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
    value: editInactiveOpacityPercent
    onValueChanged: {
      root.editInactiveOpacityPercent = value;
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
    currentKey: editTextAlign
    onSelected: key => {
      root.editTextAlign = key;
      saveSettings();
    }
    defaultValue: widgetMeta.textAlign
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.meta-label", "Show Track Meta")
    description: tr("desktop.meta-description", "Display song title and artist above the lyric block.")
    checked: editShowTrackMeta
    onToggled: checked => {
      root.editShowTrackMeta = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.showTrackMeta
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.hide-label", "Hide When Idle")
    description: tr("desktop.hide-description", "Hide the desktop widget when no playable track is active.")
    checked: editHideWhenIdle
    onToggled: checked => {
      root.editHideWhenIdle = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.hideWhenIdle
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.background-label", "Show Background")
    description: tr("desktop.background-description", "Use Noctalia's desktop widget surface behind the lyrics.")
    checked: editShowBackground
    onToggled: checked => {
      root.editShowBackground = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.showBackground
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("desktop.corners-label", "Rounded Corners")
    description: tr("desktop.corners-description", "Apply rounded clipping to the desktop widget container.")
    checked: editRoundedCorners
    onToggled: checked => {
      root.editRoundedCorners = checked;
      saveSettings();
    }
    defaultValue: widgetMeta.roundedCorners
  }
}
