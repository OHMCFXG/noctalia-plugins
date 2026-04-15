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
      "barMaxWidth": pluginApi?.pluginSettings?.barMaxWidth !== undefined ? Number(pluginApi.pluginSettings.barMaxWidth) : 340,
      "barHideWhenIdle": pluginApi?.pluginSettings?.barHideWhenIdle !== undefined ? !!pluginApi.pluginSettings.barHideWhenIdle : true,
      "showBarStatusDot": pluginApi?.pluginSettings?.showBarStatusDot !== undefined ? !!pluginApi.pluginSettings.showBarStatusDot : true,
      "primaryLyricsSource": pluginApi?.pluginSettings?.primaryLyricsSource || "lrclib",
      "enableQQMusic": pluginApi?.pluginSettings?.enableQQMusic !== undefined ? !!pluginApi.pluginSettings.enableQQMusic : true
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
      "barHideWhenIdle": draftSettings.barHideWhenIdle,
      "showBarStatusDot": draftSettings.showBarStatusDot,
      "primaryLyricsSource": draftSettings.primaryLyricsSource,
      "enableQQMusic": draftSettings.enableQQMusic
    };
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
    color: Color.mSurfaceVariant
    border.width: 1
    border.color: Qt.alpha(Color.mOutline, 0.16)
    implicitHeight: statusColumn.implicitHeight + Style.marginL * 2

    ColumnLayout {
      id: statusColumn
      anchors.fill: parent
      anchors.margins: Style.marginL
      spacing: Style.marginS

      NText {
        text: tr("settings.current-track-label", "Current Track")
        color: Color.mPrimary
        font.weight: Style.fontWeightBold
      }

      NText {
        Layout.fillWidth: true
        text: pluginApi?.mainInstance?.trackSummary || tr("status.idle", "No active player")
        wrapMode: Text.WordWrap
      }

      NText {
        text: tr("settings.current-state-label", "Lyrics State")
        color: Color.mPrimary
        font.weight: Style.fontWeightBold
        Layout.topMargin: Style.marginS
      }

      NText {
        Layout.fillWidth: true
        text: pluginApi?.mainInstance?.stateLabel || tr("status.idle", "No active player")
        wrapMode: Text.WordWrap
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
    description: tr("settings.bar-width-description", "Maximum width used by the bar widget before the lyric starts scrolling.")
    from: 180
    to: 640
    stepSize: 10
    suffix: " px"
    value: draftSettings.barMaxWidth
    onValueChanged: draftSettings.barMaxWidth = value
    defaultValue: pluginApi?.manifest?.metadata?.defaultSettings?.barMaxWidth
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
