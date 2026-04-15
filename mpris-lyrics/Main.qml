import QtQuick
import Quickshell.Io
import qs.Services.Media
import "lib/LyricsHelpers.js" as LyricsHelpers
import "lib/QQMusicCurl.js" as QQMusicCurl

Item {
  id: root

  required property var pluginApi
  visible: false
  width: 0
  height: 0

  readonly property string playerFilterMode: {
    var mode = pluginApi?.pluginSettings?.playerFilterMode;
    return mode === "blacklist" || mode === "whitelist" ? mode : "off";
  }
  readonly property var playerFilterList: {
    var rules = pluginApi?.pluginSettings?.playerFilterList;
    if (!Array.isArray(rules))
      return [];

    var normalized = [];
    var seen = {};
    for (var i = 0; i < rules.length; i++) {
      var rule = String(rules[i] || "").trim();
      var key = rule.toLowerCase();
      if (!rule || seen[key])
        continue;
      seen[key] = true;
      normalized.push(rule);
    }

    return normalized;
  }
  readonly property string currentPlayerIdentity: LyricsHelpers.cleanText(MediaService.currentPlayer ? (MediaService.currentPlayer.identity || "") : "")
  readonly property string currentPlayerDesktopEntry: LyricsHelpers.cleanText(MediaService.currentPlayer ? (MediaService.currentPlayer.desktopEntry || "") : "")
  readonly property bool hasPlayer: isCurrentPlayerAllowed()
  readonly property string trackTitle: hasPlayer ? LyricsHelpers.cleanText(MediaService.trackTitle) : ""
  readonly property string trackArtist: hasPlayer ? LyricsHelpers.cleanText(MediaService.trackArtist) : ""
  readonly property string trackAlbum: hasPlayer ? LyricsHelpers.cleanText(MediaService.trackAlbum) : ""
  readonly property int trackDurationSeconds: hasPlayer ? Math.max(0, Math.round(Number(MediaService.trackLength || 0))) : 0
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
  readonly property string primaryLyricsSource: pluginApi?.pluginSettings?.primaryLyricsSource || "lrclib"
  readonly property bool enableQQMusic: pluginApi?.pluginSettings?.enableQQMusic !== undefined ? pluginApi.pluginSettings.enableQQMusic : true
  readonly property string trackSummary: LyricsHelpers.formatTrack(currentTrack)

  property string fetchState: "idle"
  property string errorText: ""
  property var lyricsEntries: []
  property var plainLyricsLines: []
  property int currentLineIndex: -1
  property int lyricRevision: 0
  property var lyricsCache: ({})
  property int fetchToken: 0
  property bool pendingForceRefresh: false
  property string currentLyricsSource: ""

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
    if (currentLyricsSource) {
      var sourceName = currentLyricsSource === "qqmusic" ? "QQ Music" : "LRCLib";
      parts.push(tr("status.source-prefix", "Source: {source}", {
                      "source": sourceName
                    }));
    }
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

  function playerFilterValue(value) {
    if (value === undefined || value === null)
      return "";
    return String(value).trim().toLowerCase();
  }

  function currentPlayerMatchesRule(rule) {
    var matchText = playerFilterValue(rule);
    if (!matchText)
      return false;

    var identity = playerFilterValue(currentPlayerIdentity);
    if (identity && identity.indexOf(matchText) >= 0)
      return true;

    var desktopEntry = playerFilterValue(currentPlayerDesktopEntry);
    if (desktopEntry && desktopEntry.indexOf(matchText) >= 0)
      return true;

    return false;
  }

  function isCurrentPlayerAllowed() {
    if (!MediaService.currentPlayer)
      return false;

    if (playerFilterMode === "off")
      return true;

    var hasMatch = false;
    for (var i = 0; i < playerFilterList.length; i++) {
      if (currentPlayerMatchesRule(playerFilterList[i])) {
        hasMatch = true;
        break;
      }
    }

    if (playerFilterMode === "blacklist")
      return !hasMatch;
    if (playerFilterMode === "whitelist")
      return hasMatch;

    return true;
  }

  function resetState(newState) {
    fetchState = newState;
    errorText = "";
    lyricsEntries = [];
    plainLyricsLines = [];
    currentLineIndex = -1;
    currentLyricsSource = "";
    lyricRevision++;
  }

  function applyResult(result, cacheKey) {
    var safeResult = result || {
      "state": "empty",
      "entries": [],
      "plainLines": [],
      "error": "",
      "source": ""
    };

    lyricsCache[cacheKey] = safeResult;

    fetchState = safeResult.state || "empty";
    errorText = LyricsHelpers.cleanText(safeResult.error);
    lyricsEntries = (safeResult.entries || []).slice();
    plainLyricsLines = (safeResult.plainLines || []).slice();
    currentLyricsSource = (fetchState === "ready" || fetchState === "plain") ? (safeResult.source || "") : "";

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

  Component {
    id: qqMusicCurlProcessComponent

    Process {
      running: false
      stdout: StdioCollector {}
      stderr: StdioCollector {}
    }
  }

  function parseRecord(record) {
    var syncedLyrics = LyricsHelpers.parseLrc(record?.syncedLyrics || record?.synced_lyrics || "");
    if (syncedLyrics.length > 0) {
      return {
        "state": "ready",
        "entries": syncedLyrics,
        "plainLines": [],
        "error": ""
      };
    }

    var plainLyrics = LyricsHelpers.parsePlainLyrics(record?.plainLyrics || record?.plain_lyrics || record?.lyrics || "");
    if (plainLyrics.length > 0) {
      return {
        "state": "plain",
        "entries": [],
        "plainLines": plainLyrics,
        "error": ""
      };
    }

    return null;
  }

  function runQQMusicCurl(command, cacheKey, token, parseResponse, callback) {
    var process = qqMusicCurlProcessComponent.createObject(root, {
      "command": command
    });

    if (!process) {
      callback(false, 0, null, "failed to create process");
      return;
    }

    process.exited.connect(function (exitCode) {
      var stdoutText = process.stdout ? String(process.stdout.text || "") : "";
      var stderrText = process.stderr ? String(process.stderr.text || "") : "";

      if (token !== fetchToken || cacheKey !== currentTrackKey) {
        process.destroy();
        callback(false, exitCode, null, "stale");
        return;
      }

      if (exitCode !== 0) {
        process.destroy();
        callback(false, exitCode, null, stderrText || ("curl exit " + exitCode));
        return;
      }

      var parsed = parseResponse(stdoutText);
      process.destroy();
      callback(parsed.ok, 200, parsed.data, parsed.error);
    });

    process.running = true;
  }

  function searchQQMusic(keyword, cacheKey, token, callback) {
    runQQMusicCurl(QQMusicCurl.buildSearchCommand(keyword, requestTimeoutMs), cacheKey, token, QQMusicCurl.parseSearchResponseText, callback);
  }

  function getQQMusicLyric(mid, cacheKey, token, callback) {
    runQQMusicCurl(QQMusicCurl.buildLyricCommand(mid, requestTimeoutMs), cacheKey, token, QQMusicCurl.parseLyricResponseText, callback);
  }

  function findBestQQMusicMatch(songs) {
    if (!songs || songs.length === 0)
      return null;

    var bestScore = -1;
    var bestMatch = null;

    for (var i = 0; i < songs.length; i++) {
      var song = songs[i];
      var title = LyricsHelpers.normalizeText(song.songname || song.name || song.title || "");
      var album = LyricsHelpers.normalizeText(song.albumname || song.album?.name || song.album?.title || "");
      var artists = [];

      if (song.singer && Array.isArray(song.singer)) {
        for (var j = 0; j < song.singer.length; j++) {
          artists.push(LyricsHelpers.normalizeText(song.singer[j].name || ""));
        }
      }

      var trackTitle = LyricsHelpers.normalizeText(currentTrack.title);
      var trackArtist = LyricsHelpers.normalizeText(currentTrack.artist);
      var trackAlbum = LyricsHelpers.normalizeText(currentTrack.album);

      var score = 0;
      score += LyricsHelpers.scoreTextMatch(trackTitle, title, 100, 55);

      var bestArtistScore = 0;
      for (var k = 0; k < artists.length; k++) {
        var artistScore = LyricsHelpers.scoreTextMatch(trackArtist, artists[k], 70, 35);
        if (artistScore > bestArtistScore)
          bestArtistScore = artistScore;
      }
      score += bestArtistScore;

      score += LyricsHelpers.scoreTextMatch(trackAlbum, album, 20, 10);

      var durationMs = song.interval ? song.interval * 1000 : 0;
      if (trackDurationSeconds > 0 && durationMs > 0) {
        var trackDurationMs = trackDurationSeconds * 1000;
        var diff = Math.abs(trackDurationMs - durationMs);
        if (diff < 5000)
          score += 35;
      }

      if (score > bestScore) {
        bestScore = score;
        bestMatch = {
          "mid": song.mid || "",
          "score": score
        };
      }
    }

    return bestMatch;
  }

  function fetchQQMusicLyrics(cacheKey, token, callback) {
    var keyword = trackArtist && trackTitle ? (trackArtist + " " + trackTitle) : (trackTitle || trackArtist);

    if (!keyword) {
      callback(null);
      return;
    }

    searchQQMusic(keyword, cacheKey, token, function (success, status, data, error) {
      if (token !== fetchToken || cacheKey !== currentTrackKey) {
        callback(null);
        return;
      }

      if (!success || !data) {
        callback(null);
        return;
      }

      var songs = data?.req?.data?.body?.item_song;
      if (!songs || !Array.isArray(songs) || songs.length === 0) {
        callback(null);
        return;
      }

      var bestMatch = findBestQQMusicMatch(songs);
      if (!bestMatch || !bestMatch.mid || bestMatch.score < 100) {
        callback(null);
        return;
      }

      getQQMusicLyric(bestMatch.mid, cacheKey, token, function (success, status, data, error) {
        if (token !== fetchToken || cacheKey !== currentTrackKey) {
          callback(null);
          return;
        }

        if (!success || !data || !data.lyric) {
          callback(null);
          return;
        }

        var lrcText = data.lyric;
        var parsed = LyricsHelpers.parseLrc(lrcText);

        if (parsed.length > 0) {
          callback({
            "state": "ready",
            "entries": parsed,
            "plainLines": [],
            "error": ""
          });
        } else {
          callback(null);
        }
      });
    });
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
                    "error": "",
                    "source": ""
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
          parsedCandidate.source = "lrclib";
          applyResult(parsedCandidate, cacheKey);
          return;
        }

        if (fallbackResult) {
          if (!fallbackResult.source)
            fallbackResult.source = "lrclib";
          applyResult(fallbackResult, cacheKey);
          return;
        }

        if (enableQQMusic) {
          fetchQQMusicLyrics(cacheKey, token, function (result) {
            if (token !== fetchToken || cacheKey !== currentTrackKey)
              return;
            if (result) {
              result.source = "qqmusic";
              applyResult(result, cacheKey);
            } else {
              applyResult({
                            "state": "empty",
                            "entries": [],
                            "plainLines": [],
                            "error": "",
                            "source": ""
                          }, cacheKey);
            }
          });
          return;
        }

        applyResult({
                      "state": "empty",
                      "entries": [],
                      "plainLines": [],
                      "error": "",
                      "source": ""
                    }, cacheKey);
        return;
      }

      if (fallbackResult) {
        if (!fallbackResult.source)
          fallbackResult.source = "lrclib";
        applyResult(fallbackResult, cacheKey);
        return;
      }

      if (enableQQMusic) {
        fetchQQMusicLyrics(cacheKey, token, function (result) {
          if (token !== fetchToken || cacheKey !== currentTrackKey)
            return;
          if (result) {
            result.source = "qqmusic";
            applyResult(result, cacheKey);
          } else {
            applyResult({
                          "state": (status === 404) ? "empty" : "error",
                          "entries": [],
                          "plainLines": [],
                          "error": error,
                          "source": ""
                        }, cacheKey);
          }
        });
        return;
      }

      applyResult({
                    "state": (status === 404) ? "empty" : "error",
                    "entries": [],
                    "plainLines": [],
                    "error": error,
                    "source": ""
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
    lyricsEntries = [];
    plainLyricsLines = [];
    currentLineIndex = -1;
    lyricRevision++;

    var token = fetchToken;

    if (primaryLyricsSource === "qqmusic" && enableQQMusic) {
      fetchQQMusicLyrics(cacheKey, token, function (result) {
        if (token !== fetchToken || cacheKey !== currentTrackKey)
          return;

        if (result) {
          result.source = "qqmusic";
          applyResult(result, cacheKey);
          return;
        }

        var exactParams = {
          "track_name": trackTitle,
          "artist_name": trackArtist
        };

        if (trackAlbum)
          exactParams.album_name = trackAlbum;
        if (trackDurationSeconds > 0)
          exactParams.duration = String(trackDurationSeconds);

        var exactUrl = "https://lrclib.net/api/get?" + LyricsHelpers.buildQuery(exactParams);

        requestJson(exactUrl, token, function (success, status, data, error) {
          if (token !== fetchToken || cacheKey !== currentTrackKey)
            return;

          var parsed = success ? parseRecord(data) : null;
          if (parsed && parsed.state === "ready") {
            parsed.source = "lrclib";
            applyResult(parsed, cacheKey);
            return;
          }

          searchLyrics(cacheKey, token, parsed);
        });
      });
      return;
    }

    var exactParams = {
      "track_name": trackTitle,
      "artist_name": trackArtist
    };

    if (trackAlbum)
      exactParams.album_name = trackAlbum;
    if (trackDurationSeconds > 0)
      exactParams.duration = String(trackDurationSeconds);

    var exactUrl = "https://lrclib.net/api/get?" + LyricsHelpers.buildQuery(exactParams);

    requestJson(exactUrl, token, function (success, status, data, error) {
      if (token !== fetchToken || cacheKey !== currentTrackKey)
        return;

      var parsed = success ? parseRecord(data) : null;
      if (parsed && parsed.state === "ready") {
        parsed.source = "lrclib";
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
      root.scheduleLyricsRefresh(true);
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

  Component.onCompleted: {
    scheduleLyricsRefresh(false);
  }
}
