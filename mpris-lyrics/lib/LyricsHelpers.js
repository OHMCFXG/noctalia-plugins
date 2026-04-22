.pragma library

function stringValue(value) {
  if (value === undefined || value === null)
    return "";
  return String(value);
}

function cleanText(value) {
  return stringValue(value).replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim();
}

function normalizeText(value) {
  var text = cleanText(value).toLowerCase();
  text = text.replace(/\([^)]*\)|\[[^\]]*\]|\{[^}]*\}/g, " ");
  text = text.replace(/\b(feat|ft|with|vs)\.?\b/g, " ");
  text = text.replace(/[^a-z0-9\u4e00-\u9fff]+/g, " ");
  return text.replace(/\s+/g, " ").trim();
}

function secondsValue(value) {
  var number = Number(value);
  if (!isFinite(number) || number < 0)
    return 0;
  return Math.round(number);
}

function formatTrack(track) {
  var title = cleanText(track && track.title);
  var artist = cleanText(track && track.artist);
  if (title && artist)
    return artist + " - " + title;
  return title || artist || "";
}

function buildTrackKey(track) {
  return [
    normalizeText(track && track.title),
    normalizeText(track && track.artist),
    normalizeText(track && track.album),
    secondsValue(track && track.duration)
  ].join("::");
}

function parseFraction(raw) {
  if (!raw)
    return 0;
  var digits = String(raw).replace(/[^0-9]/g, "");
  if (digits.length === 0)
    return 0;
  if (digits.length === 1)
    return parseInt(digits, 10) * 100;
  if (digits.length === 2)
    return parseInt(digits, 10) * 10;
  return parseInt(digits.slice(0, 3), 10);
}

function parseTimestamp(token) {
  var raw = cleanText(token);
  if (!raw)
    return null;

  var parts = raw.split(":");
  if (parts.length < 2 || parts.length > 3)
    return null;

  var hours = 0;
  var minutes = 0;
  var secondChunk = "";

  if (parts.length === 3) {
    hours = parseInt(parts[0], 10);
    minutes = parseInt(parts[1], 10);
    secondChunk = parts[2];
  } else {
    minutes = parseInt(parts[0], 10);
    secondChunk = parts[1];
  }

  if (!isFinite(hours) || !isFinite(minutes))
    return null;

  var secondParts = secondChunk.split(/[.,]/);
  var seconds = parseInt(secondParts[0], 10);
  if (!isFinite(seconds))
    return null;

  var millis = parseFraction(secondParts.length > 1 ? secondParts[1] : "");
  return (((hours * 60) + minutes) * 60 + seconds) * 1000 + millis;
}

function parseOffsetTag(token) {
  var raw = stringValue(token);
  var match = raw.match(/^\s*offset\s*:\s*(-?\d+)\s*$/i);
  if (!match)
    return null;

  var offsetMs = parseInt(match[1], 10);
  if (!isFinite(offsetMs))
    return null;

  return offsetMs;
}

function parseLrc(text) {
  var raw = stringValue(text);
  if (!raw.trim())
    return [];

  var result = [];
  var lines = raw.replace(/\r/g, "").split("\n");
  var tagPattern = /\[([^\]]+)\]/g;
  var globalOffsetMs = 0;

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var matches = [];
    var match;
    tagPattern.lastIndex = 0;

    while ((match = tagPattern.exec(line)) !== null) {
      var offsetMs = parseOffsetTag(match[1]);
      if (offsetMs !== null) {
        globalOffsetMs = offsetMs;
        continue;
      }

      var timestamp = parseTimestamp(match[1]);
      if (timestamp !== null)
        matches.push(Math.max(0, timestamp + globalOffsetMs));
    }

    if (matches.length === 0)
      continue;

    var lyric = cleanText(line.replace(tagPattern, " "));
    if (!lyric)
      continue;

    for (var j = 0; j < matches.length; j++) {
      result.push({
        timeMs: matches[j],
        text: lyric
      });
    }
  }

  result.sort(function (a, b) {
    if (a.timeMs === b.timeMs)
      return a.text.localeCompare(b.text);
    return a.timeMs - b.timeMs;
  });

  var deduped = [];
  for (var k = 0; k < result.length; k++) {
    var item = result[k];
    var previous = deduped.length > 0 ? deduped[deduped.length - 1] : null;
    if (!previous || previous.timeMs !== item.timeMs || previous.text !== item.text)
      deduped.push(item);
  }

  return deduped;
}

function estimatePlaybackPositionMs(snapshot, nowMs) {
  var basePositionMs = Number(snapshot && snapshot.positionMs);
  if (!isFinite(basePositionMs) || basePositionMs < 0)
    basePositionMs = 0;

  if (!(snapshot && snapshot.isPlaying))
    return Math.round(basePositionMs);

  var capturedAtMs = Number(snapshot && snapshot.capturedAtMs);
  var currentAtMs = Number(nowMs);
  if (!isFinite(capturedAtMs) || !isFinite(currentAtMs))
    return Math.round(basePositionMs);

  var rate = Number(snapshot && snapshot.rate);
  if (!isFinite(rate) || rate <= 0)
    rate = 1.0;

  var deltaMs = (currentAtMs - capturedAtMs) * rate;
  if (!isFinite(deltaMs) || deltaMs <= 0)
    return Math.round(basePositionMs);

  return Math.max(0, Math.round(basePositionMs + deltaMs));
}

function chooseObservedPositionMs(options) {
  var directPositionMs = Number(options && options.directPositionMs);
  var directCapturedAtMs = Number(options && options.directCapturedAtMs);
  var playerPositionMs = Number(options && options.playerPositionMs);
  var servicePositionMs = Number(options && options.servicePositionMs);
  var preferServicePosition = !!(options && options.preferServicePosition);
  var nowMs = Number(options && options.nowMs);
  var isPlaying = !!(options && options.isPlaying);
  var rate = Number(options && options.rate);
  var directMaxAgeMs = Number(options && options.directMaxAgeMs);

  if (!isFinite(rate) || rate <= 0)
    rate = 1.0;

  if (!isFinite(directMaxAgeMs) || directMaxAgeMs < 0)
    directMaxAgeMs = 1250;

  if (isFinite(directPositionMs) && directPositionMs >= 0) {
    if (isPlaying && isFinite(directCapturedAtMs) && directCapturedAtMs >= 0 && isFinite(nowMs)) {
      var sampleAgeMs = nowMs - directCapturedAtMs;
      if (isFinite(sampleAgeMs) && sampleAgeMs >= 0 && sampleAgeMs <= directMaxAgeMs) {
        return estimatePlaybackPositionMs({
                                            "positionMs": directPositionMs,
                                            "capturedAtMs": directCapturedAtMs,
                                            "isPlaying": true,
                                            "rate": rate
                                          }, nowMs);
      }

      if (!isFinite(sampleAgeMs) || sampleAgeMs <= directMaxAgeMs)
        return Math.round(directPositionMs);
    } else {
      return Math.round(directPositionMs);
    }
  }

  if (preferServicePosition && isFinite(servicePositionMs) && servicePositionMs >= 0)
    return Math.round(servicePositionMs);

  if (isFinite(playerPositionMs) && playerPositionMs >= 0)
    return Math.round(playerPositionMs);

  if (isFinite(servicePositionMs) && servicePositionMs >= 0)
    return Math.round(servicePositionMs);

  return 0;
}

function playerctlNameFromDbusName(dbusName) {
  var raw = cleanText(dbusName);
  if (!raw)
    return "";

  var prefix = "org.mpris.MediaPlayer2.";
  if (raw.indexOf(prefix) === 0)
    return raw.slice(prefix.length);
  return raw;
}

function parsePlayerctlPositionMs(text) {
  var seconds = Number(cleanText(text));
  if (!isFinite(seconds) || seconds < 0)
    return NaN;
  return Math.round(seconds * 1000);
}

function parsePlainLyrics(text) {
  var raw = stringValue(text);
  if (!raw.trim())
    return [];

  var lines = raw.replace(/\r/g, "").split("\n");
  var result = [];
  for (var i = 0; i < lines.length; i++) {
    var line = cleanText(lines[i]);
    if (!line)
      continue;
    if (result.length > 0 && result[result.length - 1] === line)
      continue;
    result.push(line);
  }
  return result;
}

function lyricsTextValue(value) {
  if (Array.isArray(value)) {
    var parts = [];
    for (var i = 0; i < value.length; i++) {
      var line = stringValue(value[i]);
      if (line)
        parts.push(line);
    }
    return parts.join("\n");
  }

  return stringValue(value);
}

function isLikelyLyricsKey(key) {
  var raw = stringValue(key);
  if (!raw)
    return false;

  var normalized = raw.toLowerCase();
  if (normalized === "xesam:astext")
    return true;

  return normalized.indexOf("lyric") >= 0 || normalized.indexOf("lrc") >= 0;
}

function addLyricsCandidate(candidates, seen, container, key) {
  if (!container || key === undefined || key === null)
    return;

  var value = lyricsTextValue(container[key]);
  var trimmed = value.trim();
  if (!trimmed || seen[trimmed])
    return;

  seen[trimmed] = true;
  candidates.push(trimmed);
}

function extractPlayerSyncedLyrics(source) {
  if (!source)
    return [];

  var candidates = [];
  var seen = {};
  var directKeys = [
    "syncedLyrics",
    "synced_lyrics",
    "lyrics",
    "lyric",
    "lrc",
    "lrcLyrics",
    "lrc_lyrics",
    "lyricText",
    "lyricsText",
    "lrcText",
    "kde:lyrics",
    "mpris:lyrics",
    "xesam:lyrics",
    "xesam:lyric",
    "xesam:lrc",
    "xesam:asText"
  ];
  var metadataKeys = [
    "metadata",
    "metaData",
    "trackMetadata",
    "mprisMetadata"
  ];

  for (var i = 0; i < directKeys.length; i++)
    addLyricsCandidate(candidates, seen, source, directKeys[i]);

  var metadataContainers = [];
  for (var j = 0; j < metadataKeys.length; j++) {
    var container = source[metadataKeys[j]];
    if (container !== undefined && container !== null)
      metadataContainers.push(container);
  }

  for (var k = 0; k < metadataContainers.length; k++) {
    var metadata = metadataContainers[k];

    for (var m = 0; m < directKeys.length; m++)
      addLyricsCandidate(candidates, seen, metadata, directKeys[m]);

    for (var key in metadata) {
      if (!metadata.hasOwnProperty || metadata.hasOwnProperty(key)) {
        if (isLikelyLyricsKey(key))
          addLyricsCandidate(candidates, seen, metadata, key);
      }
    }
  }

  for (var n = 0; n < candidates.length; n++) {
    var parsed = parseLrc(candidates[n]);
    if (parsed.length > 0)
      return parsed;
  }

  return [];
}

function findLineIndex(entries, positionMs) {
  if (!entries || entries.length === 0)
    return -1;

  var target = Number(positionMs);
  if (!isFinite(target))
    target = 0;

  var low = 0;
  var high = entries.length - 1;
  var best = -1;

  while (low <= high) {
    var mid = Math.floor((low + high) / 2);
    var value = Number(entries[mid].timeMs || 0);

    if (value <= target) {
      best = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }

  return best;
}

function field(record, keys) {
  if (!record)
    return "";

  for (var i = 0; i < keys.length; i++) {
    if (record[keys[i]] !== undefined && record[keys[i]] !== null)
      return record[keys[i]];
  }

  return "";
}

function countTokenOverlap(a, b) {
  if (!a || !b)
    return 0;

  var left = a.split(" ");
  var rightMap = {};
  for (var i = 0; i < b.split(" ").length; i++)
    rightMap[b.split(" ")[i]] = true;

  var score = 0;
  for (var j = 0; j < left.length; j++) {
    if (left[j] && rightMap[left[j]])
      score++;
  }

  return score;
}

function scoreDuration(target, candidate) {
  if (!target || !candidate)
    return 0;
  var diff = Math.abs(target - candidate);
  if (diff === 0)
    return 35;
  return Math.max(0, 35 - Math.min(35, diff));
}

function scoreTextMatch(target, candidate, exactScore, partialScore) {
  if (!target || !candidate)
    return 0;
  if (target === candidate)
    return exactScore;
  if (target.indexOf(candidate) >= 0 || candidate.indexOf(target) >= 0)
    return partialScore;
  return countTokenOverlap(target, candidate) * 5;
}

function selectBestRecord(track, records) {
  if (!records || !records.length)
    return null;

  var trackTitle = normalizeText(track && track.title);
  var trackArtist = normalizeText(track && track.artist);
  var trackAlbum = normalizeText(track && track.album);
  var duration = secondsValue(track && track.duration);

  var bestRecord = null;
  var bestScore = -1e9;

  for (var i = 0; i < records.length; i++) {
    var record = records[i];
    if (!record)
      continue;

    var title = normalizeText(field(record, ["trackName", "track_name", "name"]));
    var artist = normalizeText(field(record, ["artistName", "artist_name", "artist"]));
    var album = normalizeText(field(record, ["albumName", "album_name", "album"]));
    var recordDuration = secondsValue(field(record, ["duration", "length", "trackLength"]));
    var syncedLyrics = stringValue(field(record, ["syncedLyrics", "synced_lyrics"]));
    var plainLyrics = stringValue(field(record, ["plainLyrics", "plain_lyrics", "lyrics"]));

    var score = 0;
    score += syncedLyrics.trim() ? 120 : 0;
    score += !syncedLyrics.trim() && plainLyrics.trim() ? 40 : 0;
    score += scoreTextMatch(trackTitle, title, 100, 55);
    score += scoreTextMatch(trackArtist, artist, 70, 35);
    score += scoreTextMatch(trackAlbum, album, 20, 10);
    score += scoreDuration(duration, recordDuration);

    if (score > bestScore) {
      bestScore = score;
      bestRecord = record;
    }
  }

  return bestRecord;
}

function buildQuery(params) {
  var parts = [];
  for (var key in params) {
    if (!params.hasOwnProperty(key))
      continue;
    var value = cleanText(params[key]);
    if (!value)
      continue;
    parts.push(encodeURIComponent(key) + "=" + encodeURIComponent(value));
  }
  return parts.join("&");
}
