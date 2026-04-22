import QtQuick
import Quickshell.Io
import qs.Commons
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
  readonly property var currentPlaybackSource: {
    var player = MediaService.currentPlayer;
    if (player && player._stateSource)
      return player._stateSource;
    return player || null;
  }
  readonly property string directMprisPlayerName: LyricsHelpers.playerctlNameFromDbusName(currentPlaybackSource ? (currentPlaybackSource.dbusName || "") : "")
  readonly property bool directMprisMonitorWanted: hasActiveTrack && directMprisPlayerName !== ""
  readonly property int lyricAdvanceMs: pluginApi?.pluginSettings?.lyricAdvanceMs !== undefined ? Number(pluginApi.pluginSettings.lyricAdvanceMs) : 300
  readonly property int requestTimeoutMs: pluginApi?.pluginSettings?.requestTimeoutMs !== undefined ? Number(pluginApi.pluginSettings.requestTimeoutMs) : 5000
  readonly property string primaryLyricsSource: pluginApi?.pluginSettings?.primaryLyricsSource || "lrclib"
  readonly property bool preferPlayerLyrics: pluginApi?.pluginSettings?.preferPlayerLyrics !== undefined ? !!pluginApi.pluginSettings.preferPlayerLyrics : true
  readonly property string trackSummary: LyricsHelpers.formatTrack(currentTrack)
  readonly property bool playbackIsPlaying: {
    var player = currentPlaybackSource;
    if (player && player.isPlaying !== undefined)
      return !!player.isPlaying;
    return !!MediaService.isPlaying;
  }

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
  property bool playheadReady: false
  property int playheadBasePositionMs: 0
  property double playheadCapturedAtMs: 0
  property real playheadRate: 1.0
  property bool playheadIsPlaying: false
  property string playheadTrackKey: ""
  property real directMprisPositionMs: NaN
  property double directMprisCapturedAtMs: NaN
  property string directMprisTrackKey: ""
  property string directMprisPollPlayerName: ""
  property string directMprisPollTrackKey: ""
  property string loggedLyricsTrackKey: ""
  property string loggedLyricsSource: ""

  readonly property bool hasSyncedLyrics: fetchState === "ready" && lyricsEntries.length > 0
  readonly property bool hasPlainLyrics: fetchState === "plain" && plainLyricsLines.length > 0
  readonly property bool isLoading: fetchState === "loading"
  readonly property int directMprisPollIntervalMs: playbackIsPlaying ? 250 : 500
  readonly property int directMprisFreshnessMs: Math.max(1000, directMprisPollIntervalMs * 4)
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
      var sourceName = sourceDisplayName(currentLyricsSource);
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

  function sourceDisplayName(sourceKey) {
    switch (sourceKey) {
    case "player":
      return tr("status.source-player", "Player");
    case "qqmusic":
      return tr("status.source-qqmusic", "QQ Music");
    case "lrclib":
      return tr("status.source-lrclib", "LRCLib");
    default:
      return LyricsHelpers.cleanText(sourceKey);
    }
  }

  function resetState(newState) {
    fetchState = newState;
    errorText = "";
    lyricsEntries = [];
    plainLyricsLines = [];
    currentLineIndex = -1;
    currentLyricsSource = "";
    loggedLyricsTrackKey = "";
    loggedLyricsSource = "";
    resetPlayhead();
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
    logLyricsSource(cacheKey, currentLyricsSource);

    updateCurrentLineIndex(true);
  }

  function logLyricsSource(trackKey, sourceKey) {
    var safeTrackKey = LyricsHelpers.cleanText(trackKey);
    var safeSourceKey = LyricsHelpers.cleanText(sourceKey);
    if (!safeTrackKey || !safeSourceKey)
      return;

    if (loggedLyricsTrackKey === safeTrackKey && loggedLyricsSource === safeSourceKey)
      return;

    Logger.i("MPRISLyrics", "[Title] " + LyricsHelpers.cleanText(trackTitle) + " [Source] " + sourceDisplayName(safeSourceKey));
    loggedLyricsTrackKey = safeTrackKey;
    loggedLyricsSource = safeSourceKey;
  }

  function scheduleLyricsRefresh(forceRefresh) {
    pendingForceRefresh = pendingForceRefresh || !!forceRefresh;
    fetchDebounce.restart();
  }

  function refetchLyrics(forceRefresh) {
    scheduleLyricsRefresh(forceRefresh === undefined ? true : forceRefresh);
  }

  function nowMs() {
    return Date.now();
  }

  function resetPlayhead() {
    playheadReady = false;
    playheadBasePositionMs = 0;
    playheadCapturedAtMs = 0;
    playheadRate = 1.0;
    playheadIsPlaying = false;
    playheadTrackKey = "";
  }

  function clearDirectMprisPosition() {
    directMprisPositionMs = NaN;
    directMprisCapturedAtMs = NaN;
    directMprisTrackKey = currentTrackKey || "";
  }

  function readPositionMs(source) {
    if (!source || source.position === undefined || source.position === null)
      return NaN;

    var seconds = Number(source.position);
    if (!isFinite(seconds) || seconds < 0)
      return NaN;

    return Math.round(seconds * 1000);
  }

  function directObservedPositionMs() {
    var positionMs = Number(directMprisPositionMs);
    if (!isFinite(positionMs) || positionMs < 0)
      return NaN;

    if (directMprisTrackKey && currentTrackKey && directMprisTrackKey !== currentTrackKey)
      return NaN;

    return Math.round(positionMs);
  }

  function applyDirectMprisPosition(positionMs, capturedAtMs) {
    if (!isFinite(positionMs) || positionMs < 0)
      return;

    directMprisPositionMs = Math.round(positionMs);
    directMprisCapturedAtMs = isFinite(capturedAtMs) ? Number(capturedAtMs) : nowMs();
    directMprisTrackKey = currentTrackKey || "";
  }

  function consumeDirectMprisPositionSample(playerName, trackKey, stdoutText) {
    if (!playerName || playerName !== directMprisPlayerName)
      return;

    if (trackKey && currentTrackKey && trackKey !== currentTrackKey)
      return;

    var positionMs = LyricsHelpers.parsePlayerctlPositionMs(stdoutText);
    if (!isFinite(positionMs))
      return;

    applyDirectMprisPosition(positionMs, nowMs());
    syncPlayheadBaseline(false, false);
    updateCurrentLineIndex(false);
  }

  function pollDirectMprisPosition() {
    if (!directMprisMonitorWanted || directMprisPositionProcess.running)
      return;

    directMprisPollPlayerName = directMprisPlayerName;
    directMprisPollTrackKey = currentTrackKey || "";
    directMprisPositionProcess.running = true;
  }

  function refreshDirectMprisMonitor(resetPosition) {
    if (resetPosition)
      clearDirectMprisPosition();

    if (!directMprisMonitorWanted) {
      directMprisPollPlayerName = "";
      directMprisPollTrackKey = "";
      return;
    }

    pollDirectMprisPosition();
  }

  function readObservedPositionMs(preferServicePosition, observedAtMs, observedRate) {
    var serviceSeconds = Number(MediaService.currentPosition || 0);

    return LyricsHelpers.chooseObservedPositionMs({
                                                    "directPositionMs": directObservedPositionMs(),
                                                    "directCapturedAtMs": directMprisCapturedAtMs,
                                                    "playerPositionMs": readPositionMs(currentPlaybackSource),
                                                    "servicePositionMs": isFinite(serviceSeconds) && serviceSeconds >= 0 ? Math.round(serviceSeconds * 1000) : NaN,
                                                    "preferServicePosition": !!preferServicePosition,
                                                    "nowMs": isFinite(observedAtMs) ? observedAtMs : nowMs(),
                                                    "isPlaying": playbackIsPlaying,
                                                    "rate": isFinite(observedRate) && observedRate > 0 ? observedRate : readObservedRate(),
                                                    "directMaxAgeMs": directMprisFreshnessMs
                                                  });
  }

  function readObservedRate() {
    var player = currentPlaybackSource;
    if (player && player.rate !== undefined && player.rate !== null) {
      var rate = Number(player.rate);
      if (isFinite(rate) && rate > 0)
        return rate;
    }
    return 1.0;
  }

  function setPlayheadBaseline(trackKey, positionMs, capturedAtMs, isPlaying, rate) {
    playheadTrackKey = trackKey || "";
    playheadBasePositionMs = Math.max(0, Math.round(Number(positionMs || 0)));
    playheadCapturedAtMs = Number(capturedAtMs || 0);
    playheadIsPlaying = !!isPlaying;
    playheadRate = Number(rate) > 0 ? Number(rate) : 1.0;
    playheadReady = !!playheadTrackKey;
  }

  function syncPlayheadBaseline(forceReset, preferServicePosition) {
    var trackKey = currentTrackKey;
    if (!trackKey) {
      resetPlayhead();
      return;
    }

    var capturedAtMs = nowMs();
    var observedPlaying = playbackIsPlaying;
    var observedRate = readObservedRate();
    var observedPositionMs = readObservedPositionMs(preferServicePosition, capturedAtMs, observedRate);

    if (forceReset || !playheadReady || playheadTrackKey !== trackKey) {
      setPlayheadBaseline(trackKey, observedPositionMs, capturedAtMs, observedPlaying, observedRate);
      return;
    }

    var estimatedPositionMs = LyricsHelpers.estimatePlaybackPositionMs({
                                                                   "positionMs": playheadBasePositionMs,
                                                                   "capturedAtMs": playheadCapturedAtMs,
                                                                   "isPlaying": playheadIsPlaying,
                                                                   "rate": playheadRate
                                                                 }, capturedAtMs);
    var driftMs = observedPositionMs - estimatedPositionMs;
    var stateChanged = observedPlaying !== playheadIsPlaying;
    var rateChanged = Math.abs(observedRate - playheadRate) > 0.001;
    var seeked = Math.abs(driftMs) > 450;

    if (!observedPlaying && playheadIsPlaying && Math.abs(driftMs) <= 1200)
      observedPositionMs = estimatedPositionMs;

    if (stateChanged || rateChanged || seeked)
      setPlayheadBaseline(trackKey, observedPositionMs, capturedAtMs, observedPlaying, observedRate);
  }

  function currentPlaybackPositionMs() {
    var trackKey = currentTrackKey;
    if (!trackKey)
      return 0;

    if (!playheadReady || playheadTrackKey !== trackKey)
      syncPlayheadBaseline(true);

    var estimatedPositionMs = LyricsHelpers.estimatePlaybackPositionMs({
                                                                   "positionMs": playheadBasePositionMs,
                                                                   "capturedAtMs": playheadCapturedAtMs,
                                                                   "isPlaying": playheadIsPlaying,
                                                                   "rate": playheadRate
                                                                 }, nowMs());

    if (trackDurationSeconds > 0)
      return Math.min(estimatedPositionMs, trackDurationSeconds * 1000);
    return estimatedPositionMs;
  }

  function updateCurrentLineIndex(forceSignal) {
    if (!hasSyncedLyrics) {
      if (currentLineIndex !== -1 || forceSignal) {
        currentLineIndex = -1;
        lyricRevision++;
      }
      return;
    }

    var positionMs = Math.max(0, currentPlaybackPositionMs() + lyricAdvanceMs);
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

  Process {
    id: directMprisPositionProcess
    running: false
    command: directMprisPollPlayerName !== "" ? ["playerctl", "-p", directMprisPollPlayerName, "position"] : []
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: exitCode => {
      var sampledPlayerName = root.directMprisPollPlayerName;
      var sampledTrackKey = root.directMprisPollTrackKey;
      var stdoutText = directMprisPositionProcess.stdout ? String(directMprisPositionProcess.stdout.text || "") : "";

      if (exitCode === 0)
        root.consumeDirectMprisPositionSample(sampledPlayerName, sampledTrackKey, stdoutText);
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

  function currentPlayerLyricsResult() {
    if (!preferPlayerLyrics)
      return null;

    var candidates = [];
    if (currentPlaybackSource)
      candidates.push(currentPlaybackSource);
    if (MediaService.currentPlayer && MediaService.currentPlayer !== currentPlaybackSource)
      candidates.push(MediaService.currentPlayer);

    for (var i = 0; i < candidates.length; i++) {
      var entries = LyricsHelpers.extractPlayerSyncedLyrics(candidates[i]);
      if (entries.length > 0) {
        return {
          "state": "ready",
          "entries": entries,
          "plainLines": [],
          "error": "",
          "source": "player"
        };
      }
    }

    return null;
  }

  function canUseCachedResult(cachedResult) {
    if (!cachedResult)
      return false;

    return preferPlayerLyrics || cachedResult.source !== "player";
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

      if (fallbackResult) {
        if (!fallbackResult.source)
          fallbackResult.source = "lrclib";
        applyResult(fallbackResult, cacheKey);
        return;
      }

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

    fetchToken++;
    var token = fetchToken;
    var playerResult = currentPlayerLyricsResult();
    var cachedResult = lyricsCache[cacheKey];

    if (playerResult) {
      applyResult(playerResult, cacheKey);
      return;
    }

    if (!forceRefresh && canUseCachedResult(cachedResult)) {
      applyResult(cachedResult, cacheKey);
      return;
    }

    fetchState = "loading";
    errorText = "";
    lyricsEntries = [];
    plainLyricsLines = [];
    currentLineIndex = -1;
    lyricRevision++;

    if (primaryLyricsSource === "qqmusic") {
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
      root.refreshDirectMprisMonitor(true);
      root.syncPlayheadBaseline(true, false);
      root.scheduleLyricsRefresh(false);
      root.updateCurrentLineIndex(true);
    }

    function onTrackTitleChanged() {
      root.refreshDirectMprisMonitor(true);
      root.syncPlayheadBaseline(true, false);
      root.scheduleLyricsRefresh(false);
    }

    function onTrackArtistChanged() {
      root.refreshDirectMprisMonitor(true);
      root.syncPlayheadBaseline(true, false);
      root.scheduleLyricsRefresh(false);
    }

    function onTrackAlbumChanged() {
      root.refreshDirectMprisMonitor(true);
      root.syncPlayheadBaseline(true, false);
      root.scheduleLyricsRefresh(false);
    }

    function onTrackLengthChanged() {
      root.refreshDirectMprisMonitor(true);
      root.syncPlayheadBaseline(true, false);
      root.scheduleLyricsRefresh(false);
    }

    function onCurrentPositionChanged() {
      root.syncPlayheadBaseline(false, true);
      root.updateCurrentLineIndex(false);
    }

    function onIsPlayingChanged() {
      root.pollDirectMprisPosition();
      root.syncPlayheadBaseline(false, false);
      root.updateCurrentLineIndex(false);
    }
  }

  Connections {
    target: root.currentPlaybackSource
    ignoreUnknownSignals: true

    function onPositionChanged() {
      root.syncPlayheadBaseline(false, false);
      root.updateCurrentLineIndex(false);
    }

    function onPlaybackStateChanged() {
      root.pollDirectMprisPosition();
      root.syncPlayheadBaseline(false, false);
      root.updateCurrentLineIndex(false);
    }

    function onIsPlayingChanged() {
      root.pollDirectMprisPosition();
      root.syncPlayheadBaseline(false, false);
      root.updateCurrentLineIndex(false);
    }

    function onRateChanged() {
      root.syncPlayheadBaseline(false, false);
      root.updateCurrentLineIndex(false);
    }

    function onMetadataChanged() {
      root.scheduleLyricsRefresh(false);
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
    running: root.hasSyncedLyrics
    onTriggered: {
      root.syncPlayheadBaseline(false, false);
      root.updateCurrentLineIndex(false);
    }
  }

  Timer {
    id: directMprisPollTimer
    interval: root.directMprisPollIntervalMs
    repeat: true
    running: root.directMprisMonitorWanted
    onTriggered: root.pollDirectMprisPosition()
  }

  onCurrentPlaybackSourceChanged: refreshDirectMprisMonitor(true)

  Component.onCompleted: {
    refreshDirectMprisMonitor(true);
    scheduleLyricsRefresh(false);
  }
}
