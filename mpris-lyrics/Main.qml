import QtQuick
import qs.Services.Media
import "lib/LyricsHelpers.js" as LyricsHelpers

Item {
  id: root

  required property var pluginApi
  visible: false
  width: 0
  height: 0

  readonly property bool hasPlayer: MediaService.currentPlayer !== null
  readonly property string trackTitle: LyricsHelpers.cleanText(MediaService.trackTitle)
  readonly property string trackArtist: LyricsHelpers.cleanText(MediaService.trackArtist)
  readonly property string trackAlbum: LyricsHelpers.cleanText(MediaService.trackAlbum)
  readonly property int trackDurationSeconds: Math.max(0, Math.round(Number(MediaService.trackLength || 0)))
  readonly property var currentTrack: ({
      "title": trackTitle,
      "artist": trackArtist,
      "album": trackAlbum,
      "duration": trackDurationSeconds
    })
  readonly property bool hasActiveTrack: hasPlayer && (trackTitle !== "" || trackArtist !== "")
  readonly property string currentTrackKey: LyricsHelpers.buildTrackKey(currentTrack)
  readonly property int lyricAdvanceMs: pluginApi?.pluginSettings?.lyricAdvanceMs !== undefined ? Number(pluginApi.pluginSettings.lyricAdvanceMs) : 120
  readonly property int requestTimeoutMs: pluginApi?.pluginSettings?.requestTimeoutMs !== undefined ? Number(pluginApi.pluginSettings.requestTimeoutMs) : 5000
  readonly property string trackSummary: LyricsHelpers.formatTrack(currentTrack)

  property string fetchState: "idle"
  property string errorText: ""
  property string lyricsSource: tr("status.source", "LRCLIB")
  property var lyricsEntries: []
  property var plainLyricsLines: []
  property int currentLineIndex: -1
  property int lyricRevision: 0
  property var lyricsCache: ({})
  property int fetchToken: 0
  property bool pendingForceRefresh: false

  readonly property bool hasSyncedLyrics: fetchState === "ready" && lyricsEntries.length > 0
  readonly property bool hasPlainLyrics: fetchState === "plain" && plainLyricsLines.length > 0
  readonly property bool isLoading: fetchState === "loading"
  readonly property string currentLineText: currentLineIndex >= 0 && currentLineIndex < lyricsEntries.length ? lyricsEntries[currentLineIndex].text : ""
  readonly property string previousLineText: currentLineIndex > 0 && currentLineIndex - 1 < lyricsEntries.length ? lyricsEntries[currentLineIndex - 1].text : ""
  readonly property string nextLineText: currentLineIndex + 1 >= 0 && currentLineIndex + 1 < lyricsEntries.length ? lyricsEntries[currentLineIndex + 1].text : ""
  readonly property string plainExcerpt: plainLyricsLines.length > 0 ? plainLyricsLines[0] : ""
  readonly property string stateLabel: {
    switch (fetchState) {
    case "loading":
      return tr("status.loading", "Searching synced lyrics");
    case "ready":
      return tr("status.ready", "Synced lyrics");
    case "plain":
      return tr("status.plain", "Lyrics found, but not time-coded");
    case "empty":
      return tr("status.empty", "No lyrics found");
    case "error":
      return tr("status.error", "Lyrics unavailable");
    case "no-track":
      return tr("status.no-track", "Waiting for track metadata");
    default:
      return tr("status.idle", "No active player");
    }
  }
  readonly property string barText: {
    if (hasSyncedLyrics && currentLineText)
      return currentLineText;
    if (hasPlainLyrics && plainExcerpt)
      return plainExcerpt;
    if (fetchState === "loading")
      return stateLabel;
    if (trackSummary)
      return trackSummary;
    return stateLabel;
  }
  readonly property string tooltipText: {
    var parts = [];
    if (trackTitle)
      parts.push(trackTitle);
    if (trackArtist)
      parts.push(trackArtist);
    parts.push(tr("status.state-prefix", "State: {state}", {
                    "state": stateLabel
                  }));
    parts.push(tr("status.source-prefix", "Source: {source}", {
                    "source": lyricsSource
                  }));
    return parts.join("\n");
  }

  function tr(key, fallback, vars) {
    if (pluginApi && pluginApi.tr) {
      var translated = pluginApi.tr(key, vars || {});
      if (translated && translated.indexOf("!!") !== 0)
        return translated;
    }
    return fallback;
  }

  function resetState(newState) {
    fetchState = newState;
    errorText = "";
    lyricsEntries = [];
    plainLyricsLines = [];
    currentLineIndex = -1;
    lyricRevision++;
  }

  function applyResult(result, cacheKey) {
    var safeResult = result || {
      "state": "empty",
      "entries": [],
      "plainLines": [],
      "source": tr("status.source", "LRCLIB"),
      "error": ""
    };

    lyricsCache[cacheKey] = safeResult;

    fetchState = safeResult.state || "empty";
    errorText = LyricsHelpers.cleanText(safeResult.error);
    lyricsSource = LyricsHelpers.cleanText(safeResult.source || tr("status.source", "LRCLIB"));
    lyricsEntries = (safeResult.entries || []).slice();
    plainLyricsLines = (safeResult.plainLines || []).slice();

    updateCurrentLineIndex(true);
  }

  function scheduleLyricsRefresh(forceRefresh) {
    pendingForceRefresh = pendingForceRefresh || !!forceRefresh;
    fetchDebounce.restart();
  }

  function refetchLyrics(forceRefresh) {
    scheduleLyricsRefresh(forceRefresh === undefined ? true : forceRefresh);
  }

  function updateCurrentLineIndex(forceSignal) {
    if (!hasSyncedLyrics) {
      if (currentLineIndex !== -1 || forceSignal) {
        currentLineIndex = -1;
        lyricRevision++;
      }
      return;
    }

    var positionMs = Math.max(0, Math.round(Number(MediaService.currentPosition || 0) * 1000) + lyricAdvanceMs);
    var nextIndex = LyricsHelpers.findLineIndex(lyricsEntries, positionMs);

    if (nextIndex !== currentLineIndex || forceSignal) {
      currentLineIndex = nextIndex;
      lyricRevision++;
    }
  }

  function requestJson(url, token, callback) {
    var xhr = new XMLHttpRequest();
    var settled = false;

    function finish(success, status, data, error) {
      if (settled)
        return;
      settled = true;
      callback(success, status, data, error || "");
    }

    xhr.open("GET", url);
    xhr.setRequestHeader("Accept", "application/json");
    xhr.timeout = Math.max(1000, requestTimeoutMs);

    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE || token !== fetchToken)
        return;

      if (xhr.status >= 200 && xhr.status < 300) {
        try {
          finish(true, xhr.status, JSON.parse(xhr.responseText), "");
        } catch (error) {
          finish(false, xhr.status, null, String(error));
        }
        return;
      }

      finish(false, xhr.status, null, xhr.responseText || ("HTTP " + xhr.status));
    };

    xhr.onerror = function () {
      if (token !== fetchToken)
        return;
      finish(false, 0, null, "network error");
    };

    xhr.ontimeout = function () {
      if (token !== fetchToken)
        return;
      finish(false, 0, null, "timeout");
    };

    xhr.send();
  }

  function parseRecord(record) {
    var syncedLyrics = LyricsHelpers.parseLrc(record?.syncedLyrics || record?.synced_lyrics || "");
    if (syncedLyrics.length > 0) {
      return {
        "state": "ready",
        "entries": syncedLyrics,
        "plainLines": [],
        "source": tr("status.source", "LRCLIB"),
        "error": ""
      };
    }

    var plainLyrics = LyricsHelpers.parsePlainLyrics(record?.plainLyrics || record?.plain_lyrics || record?.lyrics || "");
    if (plainLyrics.length > 0) {
      return {
        "state": "plain",
        "entries": [],
        "plainLines": plainLyrics,
        "source": tr("status.source", "LRCLIB"),
        "error": ""
      };
    }

    return null;
  }

  function searchLyrics(cacheKey, token, fallbackResult) {
    var searchParams = {};

    if (trackTitle)
      searchParams.track_name = trackTitle;
    if (trackArtist)
      searchParams.artist_name = trackArtist;
    if (trackAlbum)
      searchParams.album_name = trackAlbum;

    var query = LyricsHelpers.buildQuery(searchParams);
    if (!query && trackSummary)
      query = LyricsHelpers.buildQuery({
                                      "q": trackSummary
                                    });

    if (!query) {
      applyResult(fallbackResult || {
                    "state": "empty",
                    "entries": [],
                    "plainLines": [],
                    "source": tr("status.source", "LRCLIB"),
                    "error": ""
                  }, cacheKey);
      return;
    }

    requestJson("https://lrclib.net/api/search?" + query, token, function (success, status, data, error) {
      if (token !== fetchToken || cacheKey !== currentTrackKey)
        return;

      if (success && Array.isArray(data)) {
        var candidate = LyricsHelpers.selectBestRecord(currentTrack, data);
        var parsedCandidate = parseRecord(candidate);
        if (parsedCandidate) {
          applyResult(parsedCandidate, cacheKey);
          return;
        }

        if (fallbackResult) {
          applyResult(fallbackResult, cacheKey);
          return;
        }

        applyResult({
                      "state": "empty",
                      "entries": [],
                      "plainLines": [],
                      "source": tr("status.source", "LRCLIB"),
                      "error": ""
                    }, cacheKey);
        return;
      }

      if (fallbackResult) {
        applyResult(fallbackResult, cacheKey);
        return;
      }

      applyResult({
                    "state": (status === 404) ? "empty" : "error",
                    "entries": [],
                    "plainLines": [],
                    "source": tr("status.source", "LRCLIB"),
                    "error": error
                  }, cacheKey);
    });
  }

  function loadLyrics(forceRefresh) {
    if (!hasActiveTrack) {
      resetState(hasPlayer ? "no-track" : "idle");
      return;
    }

    var cacheKey = currentTrackKey;
    if (!cacheKey) {
      resetState("no-track");
      return;
    }

    if (!forceRefresh && lyricsCache[cacheKey]) {
      applyResult(lyricsCache[cacheKey], cacheKey);
      return;
    }

    fetchToken++;
    fetchState = "loading";
    errorText = "";
    lyricsSource = tr("status.source", "LRCLIB");
    lyricsEntries = [];
    plainLyricsLines = [];
    currentLineIndex = -1;
    lyricRevision++;

    var exactParams = {
      "track_name": trackTitle,
      "artist_name": trackArtist
    };

    if (trackAlbum)
      exactParams.album_name = trackAlbum;
    if (trackDurationSeconds > 0)
      exactParams.duration = String(trackDurationSeconds);

    var exactUrl = "https://lrclib.net/api/get?" + LyricsHelpers.buildQuery(exactParams);
    var token = fetchToken;

    requestJson(exactUrl, token, function (success, status, data, error) {
      if (token !== fetchToken || cacheKey !== currentTrackKey)
        return;

      var parsed = success ? parseRecord(data) : null;
      if (parsed && parsed.state === "ready") {
        applyResult(parsed, cacheKey);
        return;
      }

      searchLyrics(cacheKey, token, parsed);
    });
  }

  Connections {
    target: MediaService

    function onCurrentPlayerChanged() {
      root.scheduleLyricsRefresh(false);
    }

    function onTrackTitleChanged() {
      root.scheduleLyricsRefresh(false);
    }

    function onTrackArtistChanged() {
      root.scheduleLyricsRefresh(false);
    }

    function onTrackAlbumChanged() {
      root.scheduleLyricsRefresh(false);
    }

    function onTrackLengthChanged() {
      root.scheduleLyricsRefresh(false);
    }

    function onCurrentPositionChanged() {
      root.updateCurrentLineIndex(false);
    }

    function onIsPlayingChanged() {
      root.updateCurrentLineIndex(false);
    }
  }

  Connections {
    target: pluginApi
    enabled: pluginApi !== null

    function onPluginSettingsChanged() {
      root.updateCurrentLineIndex(true);
    }
  }

  Timer {
    id: fetchDebounce
    interval: 250
    repeat: false
    onTriggered: {
      var forceRefresh = root.pendingForceRefresh;
      root.pendingForceRefresh = false;
      root.loadLyrics(forceRefresh);
    }
  }

  Timer {
    interval: 140
    repeat: true
    running: root.hasSyncedLyrics && MediaService.isPlaying
    onTriggered: root.updateCurrentLineIndex(false)
  }

  Component.onCompleted: scheduleLyricsRefresh(false)
}
