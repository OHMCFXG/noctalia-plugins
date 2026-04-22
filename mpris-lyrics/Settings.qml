import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  required property var pluginApi

  property int preferredWidth: 720

  readonly property var defaultSettings: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  spacing: Style.marginL

  function tr(key, fallback, vars) {
    if (pluginApi && pluginApi.tr) {
      var translated = pluginApi.tr(key, vars || {});
      if (translated && translated.indexOf("!!") !== 0)
        return translated;
    }
    return fallback;
  }

  function settingValue(key, fallback) {
    var settings = pluginApi?.pluginSettings || {};
    var defaults = defaultSettings || {};
    if (settings[key] !== undefined)
      return settings[key];
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

  function normalizePlayerFilterMode(value) {
    return value === "blacklist" || value === "whitelist" ? value : "off";
  }

  function normalizeBarWidthMode(value) {
    return value === "fixed" ? "fixed" : "adaptive";
  }

  function normalizePrimaryLyricsSource(value) {
    return value === "qqmusic" ? "qqmusic" : "lrclib";
  }

  function normalizePlayerFilterRule(value) {
    return String(value || "").trim();
  }

  function normalizePlayerFilterList(value) {
    if (!Array.isArray(value))
      return [];

    var normalized = [];
    var seen = {};
    for (var i = 0; i < value.length; i++) {
      var rule = normalizePlayerFilterRule(value[i]);
      var key = rule.toLowerCase();
      if (!rule || seen[key])
        continue;
      seen[key] = true;
      normalized.push(rule);
    }
    return normalized;
  }

  function clonePlayerFilterList() {
    return (editPlayerFilterList || []).slice();
  }

  function buildSettings() {
    return {
      "lyricAdvanceMs": editLyricAdvanceMs,
      "requestTimeoutMs": editRequestTimeoutMs,
      "preferPlayerLyrics": editPreferPlayerLyrics,
      "barMaxWidth": editBarMaxWidth,
      "barWidthMode": editBarWidthMode,
      "barHideWhenIdle": editBarHideWhenIdle,
      "showBarStatusDot": editShowBarStatusDot,
      "primaryLyricsSource": editPrimaryLyricsSource,
      "playerFilterMode": editPlayerFilterMode,
      "playerFilterList": clonePlayerFilterList()
    };
  }

  function addPlayerFilterRule(value) {
    var rule = normalizePlayerFilterRule(value);
    if (!rule)
      return false;

    var existing = editPlayerFilterList || [];
    for (var i = 0; i < existing.length; i++) {
      if (String(existing[i] || "").toLowerCase() === rule.toLowerCase())
        return false;
    }

    editPlayerFilterList = existing.concat([rule]);
    return true;
  }

  function removePlayerFilterRule(rule) {
    var existing = editPlayerFilterList || [];
    var nextList = [];
    for (var i = 0; i < existing.length; i++) {
      if (existing[i] !== rule)
        nextList.push(existing[i]);
    }
    editPlayerFilterList = nextList;
  }

  function saveSettings() {
    var nextSettings = Object.assign({}, pluginApi?.pluginSettings || {}, buildSettings());
    delete nextSettings.enableQQMusic;
    pluginApi.pluginSettings = nextSettings;
    pluginApi.saveSettings();
  }

  property int editLyricAdvanceMs: readNumberSetting("lyricAdvanceMs", 300)
  property int editRequestTimeoutMs: readNumberSetting("requestTimeoutMs", 5000)
  property int editBarMaxWidth: readNumberSetting("barMaxWidth", 180)
  property string editBarWidthMode: normalizeBarWidthMode(settingValue("barWidthMode", "adaptive"))
  property bool editBarHideWhenIdle: readBoolSetting("barHideWhenIdle", true)
  property bool editShowBarStatusDot: readBoolSetting("showBarStatusDot", true)
  property string editPrimaryLyricsSource: normalizePrimaryLyricsSource(settingValue("primaryLyricsSource", "lrclib"))
  property bool editPreferPlayerLyrics: readBoolSetting("preferPlayerLyrics", true)
  property string editPlayerFilterMode: normalizePlayerFilterMode(settingValue("playerFilterMode", "off"))
  property var editPlayerFilterList: normalizePlayerFilterList(settingValue("playerFilterList", []))

  NText {
    Layout.fillWidth: true
    text: tr("settings.overview", "Displays synced lyrics in the bar and desktop widget, following the active media player.")
    wrapMode: Text.WordWrap
  }

  NText {
    Layout.fillWidth: true
    text: tr("settings.section-player-filter", "Player Filter")
    color: Color.mPrimary
    font.weight: Style.fontWeightBold
    Layout.topMargin: Style.marginS
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.player-filter-mode-label", "Player Filter Mode")
    description: tr("settings.player-filter-mode-description", "Choose whether this plugin ignores or only allows matching players.")
    model: [
      {
        "key": "off",
        "name": tr("settings.player-filter-mode-off", "Off")
      },
      {
        "key": "blacklist",
        "name": tr("settings.player-filter-mode-blacklist", "Blacklist")
      },
      {
        "key": "whitelist",
        "name": tr("settings.player-filter-mode-whitelist", "Whitelist")
      }
    ]
    currentKey: editPlayerFilterMode
    onSelected: key => root.editPlayerFilterMode = key
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.playerFilterMode
  }

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.marginS

    NTextInputButton {
      id: playerFilterRuleInput
      Layout.fillWidth: true
      label: tr("settings.player-filter-list-label", "Player Filter Rules")
      description: tr("settings.player-filter-list-description", "Add case-insensitive substring rules matched against player identity and desktop entry.")
      placeholderText: tr("settings.player-filter-list-placeholder", "firefox")
      buttonIcon: "add"
      onButtonClicked: {
        if (addPlayerFilterRule(playerFilterRuleInput.text))
          playerFilterRuleInput.text = "";
      }
    }

    Flow {
      Layout.fillWidth: true
      Layout.leftMargin: Style.marginS
      spacing: Style.marginS

      Repeater {
        model: editPlayerFilterList || []

        delegate: Rectangle {
          required property string modelData

          property real pad: Style.marginS
          color: Qt.alpha(Color.mOnSurface, 0.125)
          border.color: Qt.alpha(Color.mOnSurface, Style.opacityLight)
          border.width: Style.borderS
          radius: Style.radiusM
          implicitWidth: chipRow.implicitWidth + pad * 2
          implicitHeight: Math.max(chipRow.implicitHeight + pad * 2, Style.baseWidgetSize * 0.8)

          RowLayout {
            id: chipRow
            anchors.fill: parent
            anchors.margins: pad
            spacing: Style.marginXS

            NText {
              text: modelData
              color: Color.mOnSurface
              pointSize: Style.fontSizeS
              Layout.alignment: Qt.AlignVCenter
              Layout.leftMargin: Style.marginS
            }

            NIconButton {
              icon: "close"
              baseSize: Style.baseWidgetSize * 0.8
              Layout.alignment: Qt.AlignVCenter
              Layout.rightMargin: Style.marginXS
              onClicked: removePlayerFilterRule(modelData)
            }
          }
        }
      }
    }
  }

  NText {
    Layout.fillWidth: true
    text: tr("settings.section-lyrics-fetch", "Lyrics Fetch")
    color: Color.mPrimary
    font.weight: Style.fontWeightBold
    Layout.topMargin: Style.marginS
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.primary-source-label", "Primary Lyrics Source")
    description: tr("settings.primary-source-description", "The lyrics source to try first when searching for lyrics.")
    model: [
      {
        "key": "lrclib",
        "name": "LRCLib"
      },
      {
        "key": "qqmusic",
        "name": "QQ Music"
      }
    ]
    currentKey: editPrimaryLyricsSource
    onSelected: key => root.editPrimaryLyricsSource = key
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.primaryLyricsSource
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("settings.prefer-player-lyrics-label", "Prefer Player Lyrics")
    description: tr("settings.prefer-player-lyrics-description", "When the current player exposes time-coded LRC lyrics over MPRIS, use them before any network source.")
    checked: editPreferPlayerLyrics
    onToggled: checked => root.editPreferPlayerLyrics = checked
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.preferPlayerLyrics
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("settings.timeout-label", "Request Timeout")
    description: tr("settings.timeout-description", "Abort a lyrics request after this many milliseconds.")
    from: 1000
    to: 12000
    stepSize: 250
    suffix: " ms"
    value: editRequestTimeoutMs
    onValueChanged: root.editRequestTimeoutMs = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.requestTimeoutMs
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("settings.advance-label", "Lyric Advance")
    description: tr("settings.advance-description", "Positive values show lyrics earlier. Negative values show them later.")
    from: -1500
    to: 1500
    stepSize: 20
    suffix: " ms"
    value: editLyricAdvanceMs
    onValueChanged: root.editLyricAdvanceMs = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.lyricAdvanceMs
  }

  NText {
    Layout.fillWidth: true
    text: tr("settings.section-bar-display", "Bar Display")
    color: Color.mPrimary
    font.weight: Style.fontWeightBold
    Layout.topMargin: Style.marginS
  }

  NComboBox {
    Layout.fillWidth: true
    label: tr("settings.bar-width-mode-label", "Bar Width Mode")
    description: tr("settings.bar-width-mode-description", "Choose whether the bar width follows the current lyric or stays fixed.")
    model: [
      {
        "key": "adaptive",
        "name": tr("settings.bar-width-mode-adaptive", "Adaptive")
      },
      {
        "key": "fixed",
        "name": tr("settings.bar-width-mode-fixed", "Fixed")
      }
    ]
    currentKey: editBarWidthMode
    onSelected: key => root.editBarWidthMode = key
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barWidthMode
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("settings.bar-width-label", "Bar Max Width")
    description: tr("settings.bar-width-description", "In adaptive mode this is the maximum width. In fixed mode this becomes the locked width.")
    from: 180
    to: 640
    stepSize: 10
    suffix: " px"
    value: editBarMaxWidth
    onValueChanged: root.editBarMaxWidth = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barMaxWidth
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("settings.bar-hide-label", "Hide Bar Widget When No Track Is Active")
    description: tr("settings.bar-hide-description", "Hide the lyrics widget in the bar when no track is active.")
    checked: editBarHideWhenIdle
    onToggled: checked => root.editBarHideWhenIdle = checked
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barHideWhenIdle
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("settings.bar-dot-label", "Show Status Dot")
    description: tr("settings.bar-dot-description", "Display the animated state indicator at the start of the bar widget.")
    checked: editShowBarStatusDot
    onToggled: checked => root.editShowBarStatusDot = checked
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.showBarStatusDot
  }
}
