import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  required property var pluginApi

  property int preferredWidth: 720
  property var draftSettings: ({
      "lyricAdvanceMs": pluginApi?.pluginSettings?.lyricAdvanceMs !== undefined ? Number(pluginApi.pluginSettings.lyricAdvanceMs) : 120,
      "requestTimeoutMs": pluginApi?.pluginSettings?.requestTimeoutMs !== undefined ? Number(pluginApi.pluginSettings.requestTimeoutMs) : 5000,
      "barMaxWidth": pluginApi?.pluginSettings?.barMaxWidth !== undefined ? Number(pluginApi.pluginSettings.barMaxWidth) : 180,
      "barWidthMode": pluginApi?.pluginSettings?.barWidthMode === "fixed" ? "fixed" : "adaptive",
      "barHideWhenIdle": pluginApi?.pluginSettings?.barHideWhenIdle !== undefined ? !!pluginApi.pluginSettings.barHideWhenIdle : true,
      "showBarStatusDot": pluginApi?.pluginSettings?.showBarStatusDot !== undefined ? !!pluginApi.pluginSettings.showBarStatusDot : true,
      "primaryLyricsSource": pluginApi?.pluginSettings?.primaryLyricsSource || "lrclib",
      "enableQQMusic": pluginApi?.pluginSettings?.enableQQMusic !== undefined ? !!pluginApi.pluginSettings.enableQQMusic : true,
      "playerFilterMode": (function () {
          var mode = pluginApi?.pluginSettings?.playerFilterMode;
          return mode === "blacklist" || mode === "whitelist" ? mode : "off";
        })(),
      "playerFilterList": (function () {
          var list = pluginApi?.pluginSettings?.playerFilterList;
          if (!Array.isArray(list))
            return [];

          var normalized = [];
          var seen = {};
          for (var i = 0; i < list.length; i++) {
            var rule = String(list[i] || "").trim();
            var key = rule.toLowerCase();
            if (!rule || seen[key])
              continue;
            seen[key] = true;
            normalized.push(rule);
          }

          return normalized;
        })()
    })

  spacing: Style.marginL

  function tr(key, fallback, vars) {
    if (pluginApi && pluginApi.tr) {
      var translated = pluginApi.tr(key, vars || {});
      if (translated && translated.indexOf("!!") !== 0)
        return translated;
    }
    return fallback;
  }

  function cloneDraft() {
    return {
      "lyricAdvanceMs": draftSettings.lyricAdvanceMs,
      "requestTimeoutMs": draftSettings.requestTimeoutMs,
      "barMaxWidth": draftSettings.barMaxWidth,
      "barWidthMode": draftSettings.barWidthMode,
      "barHideWhenIdle": draftSettings.barHideWhenIdle,
      "showBarStatusDot": draftSettings.showBarStatusDot,
      "primaryLyricsSource": draftSettings.primaryLyricsSource,
      "enableQQMusic": draftSettings.enableQQMusic,
      "playerFilterMode": draftSettings.playerFilterMode,
      "playerFilterList": (draftSettings.playerFilterList || []).slice()
    };
  }

  function replaceDraftSettings(patch) {
    draftSettings = Object.assign({}, draftSettings, patch || {});
  }

  function normalizePlayerFilterRule(value) {
    return String(value || "").trim();
  }

  function addPlayerFilterRule(value) {
    var rule = normalizePlayerFilterRule(value);
    if (!rule)
      return false;

    var existing = draftSettings.playerFilterList || [];
    for (var i = 0; i < existing.length; i++) {
      if (String(existing[i] || "").toLowerCase() === rule.toLowerCase())
        return false;
    }

    replaceDraftSettings({
                           "playerFilterList": existing.concat([rule])
                         });
    return true;
  }

  function removePlayerFilterRule(rule) {
    var existing = draftSettings.playerFilterList || [];
    var nextList = [];
    for (var i = 0; i < existing.length; i++) {
      if (existing[i] !== rule)
        nextList.push(existing[i]);
    }
    replaceDraftSettings({
                           "playerFilterList": nextList
                         });
  }

  function saveSettings() {
    pluginApi.pluginSettings = cloneDraft();
    pluginApi.saveSettings();
  }

  Rectangle {
    Layout.fillWidth: true
    radius: Style.radiusM
    color: Qt.alpha(Color.mPrimary, 0.08)
    border.width: 1
    border.color: Qt.alpha(Color.mPrimary, 0.18)
    implicitHeight: introColumn.implicitHeight + Style.marginL * 2

    ColumnLayout {
      id: introColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginS

      NText {
        text: tr("settings.overview", "Displays synced lyrics in the bar and desktop widget, following the active media player.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }
    }
  }

  Rectangle {
    Layout.fillWidth: true
    radius: Style.radiusM
    color: Qt.alpha(Color.mPrimary, 0.08)
    border.width: 1
    border.color: Qt.alpha(Color.mPrimary, 0.18)
    implicitHeight: filterColumn.implicitHeight + Style.marginL * 2

    ColumnLayout {
      id: filterColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginS

      NText {
        text: tr("settings.player-filter-header", "Player Filter")
        color: Color.mPrimary
        font.weight: Style.fontWeightBold
      }

      NText {
        text: tr("settings.player-filter-description", "Limit which media players this plugin is allowed to handle.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }
    }
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
    currentKey: draftSettings.playerFilterMode
    onSelected: key => replaceDraftSettings({
                                              "playerFilterMode": key
                                            })
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
        model: draftSettings.playerFilterList || []

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

  NSpinBox {
    Layout.fillWidth: true
    label: tr("settings.advance-label", "Lyric Offset")
    description: tr("settings.advance-description", "Shift lyrics forward or backward to match your player latency.")
    from: -1500
    to: 1500
    stepSize: 20
    suffix: " ms"
    value: draftSettings.lyricAdvanceMs
    onValueChanged: draftSettings.lyricAdvanceMs = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.lyricAdvanceMs
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("settings.timeout-label", "Request Timeout")
    description: tr("settings.timeout-description", "Abort a lyrics request after this many milliseconds.")
    from: 1000
    to: 12000
    stepSize: 250
    suffix: " ms"
    value: draftSettings.requestTimeoutMs
    onValueChanged: draftSettings.requestTimeoutMs = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.requestTimeoutMs
  }

  NSpinBox {
    Layout.fillWidth: true
    label: tr("settings.bar-width-label", "Bar Max Width")
    description: tr("settings.bar-width-description", "In adaptive mode this is the maximum width. In fixed mode this becomes the locked width.")
    from: 180
    to: 640
    stepSize: 10
    suffix: " px"
    value: draftSettings.barMaxWidth
    onValueChanged: draftSettings.barMaxWidth = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barMaxWidth
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
    currentKey: draftSettings.barWidthMode
    onSelected: key => replaceDraftSettings({
                                              "barWidthMode": key
                                            })
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barWidthMode
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("settings.bar-hide-label", "Hide Bar When Idle")
    description: tr("settings.bar-hide-description", "Collapse the bar widget when there is no active track.")
    checked: draftSettings.barHideWhenIdle
    onToggled: checked => draftSettings.barHideWhenIdle = checked
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barHideWhenIdle
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("settings.bar-dot-label", "Show Status Dot")
    description: tr("settings.bar-dot-description", "Display the animated state indicator at the start of the bar widget.")
    checked: draftSettings.showBarStatusDot
    onToggled: checked => draftSettings.showBarStatusDot = checked
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.showBarStatusDot
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.topMargin: Style.marginM
    radius: Style.radiusM
    color: Qt.alpha(Color.mPrimary, 0.08)
    border.width: 1
    border.color: Qt.alpha(Color.mPrimary, 0.18)
    implicitHeight: sourcesColumn.implicitHeight + Style.marginL * 2

    ColumnLayout {
      id: sourcesColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginS

      NText {
        text: tr("settings.lyrics-sources-header", "Lyrics Sources")
        color: Color.mPrimary
        font.weight: Style.fontWeightBold
      }

      NText {
        text: tr("settings.lyrics-sources-description", "Configure which lyrics sources to use and their priority order.")
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }
    }
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
    currentKey: draftSettings.primaryLyricsSource === "qqmusic" ? "qqmusic" : "lrclib"
    onSelected: key => draftSettings.primaryLyricsSource = key
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.primaryLyricsSource
  }

  NToggle {
    Layout.fillWidth: true
    label: tr("settings.enable-qqmusic-label", "Enable QQ Music")
    description: tr("settings.enable-qqmusic-description", "Enable QQ Music lyrics source.")
    checked: draftSettings.enableQQMusic
    onToggled: checked => draftSettings.enableQQMusic = checked
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.enableQQMusic
  }
}
