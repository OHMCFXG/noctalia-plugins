--!nonstrict
-- MPRIS Lyrics — headless service.
-- Polls Noctalia's dev.noctalia.Mpris control plane, fetches synced lyrics from
-- NetEase / QQ Music / LRCLib, and publishes a snapshot for the bar widget.
-- Note: plugin VMs have no `require`; helpers are local to this file.

noctalia.setUpdateInterval(100)

-- ── Config ───────────────────────────────────────────────────────────────────

local function cfg(key)
  return noctalia.getConfig(key)
end

local function log(msg)
  noctalia.log(`mpris-lyrics: {msg}`)
end

-- Wall-clock / monotonic time for playhead + poll throttles.
-- Pure Lua only has os.time() (1s) and os.clock() (CPU time, freezes when idle).
-- Prefer /proc/uptime (monotonic, fractional seconds) when readable; fall back to
-- accumulating host update() ticks.
local TICK_MS = 100 -- how often update() runs (line index + poll throttle)
local POS_POLL_MS = 400 -- GetPositionActive while playing with synced lyrics
local ACTIVE_POLL_MS = 1000 -- GetActivePlayer (metadata / player switch)
-- Note: no fixed TRANSPORT_LEAD_MS. Host position is already projected; local
-- nowMs() is real monotonic time. User-facing lead is lyricAdvanceMs only.
local wallMs = 0
local useProcUptime = true

local function nowMsFromProc()
  local raw = noctalia.readFile("/proc/uptime")
  if type(raw) ~= "string" then
    return nil
  end
  local sec = tonumber(string.match(raw, "^[%d%.]+"))
  if sec == nil then
    return nil
  end
  return math.floor(sec * 1000)
end

local function nowMs()
  if useProcUptime then
    local ms = nowMsFromProc()
    if ms ~= nil then
      wallMs = ms
      return ms
    end
    useProcUptime = false
    log(" /proc/uptime unavailable; falling back to update-tick clock")
  end
  return wallMs
end

-- Fingerprint of service-owned settings (filter / source / timing).
local function lyricsConfigFingerprint()
  local list = cfg("playerFilterList")
  local listKey = ""
  if type(list) == "table" then
    local parts = {}
    for _, rule in ipairs(list) do
      table.insert(parts, tostring(rule))
    end
    listKey = table.concat(parts, "\n")
  end
  return table.concat({
    tostring(cfg("playerFilterMode") or ""),
    listKey,
    tostring(cfg("primaryLyricsSource") or ""),
    tostring(cfg("preferPlayerLyrics")),
    tostring(cfg("requestTimeoutMs") or ""),
    tostring(cfg("lyricAdvanceMs") or ""),
  }, "|")
end

local lastLyricsConfigFp = lyricsConfigFingerprint()

-- ── Text / track helpers ────────────────────────────────────────────────────

local function cleanText(value)
  if value == nil then
    return ""
  end
  local text = tostring(value)
  text = text:gsub("[\r\n\t]+", " "):gsub("%s+", " ")
  return noctalia.string.trim(text)
end

local function normalizeText(value)
  local text = cleanText(value):lower()
  text = text:gsub("%b()", " "):gsub("%b[]", " "):gsub("%b{}", " ")
  text = text:gsub("（.-）", " "):gsub("【.-】", " "):gsub("〈.-〉", " "):gsub("《.-》", " ")
  text = text:gsub("%f[%w]feat%.?%f[%W]", " "):gsub("%f[%w]ft%.?%f[%W]", " ")
  text = text:gsub("%f[%w]with%f[%W]", " "):gsub("%f[%w]vs%.?%f[%W]", " ")
  -- Keep letters/digits/CJK; drop common ASCII punctuation only.
  text = text:gsub("[%c!-/:-@%[-`{-~]+", " ")
  return noctalia.string.trim(text:gsub("%s+", " "))
end

local function formatTrack(title, artist)
  title = cleanText(title)
  artist = cleanText(artist)
  if title ~= "" and artist ~= "" then
    return `{artist} - {title}`
  end
  return title ~= "" and title or artist
end

-- Identity is title+artist only. Album/length often arrive a poll later; including
-- them in the key causes a second "track change" (loading flash + re-fetch) mid
-- credit-header. Album is still used for scoring when present.
local function buildTrackKey(title, artist, _album)
  return table.concat({
    normalizeText(title),
    normalizeText(artist),
  }, "::")
end

local function countTokenOverlap(a, b)
  if a == "" or b == "" then
    return 0
  end
  local right = {}
  for token in string.gmatch(b, "%S+") do
    right[token] = true
  end
  local score = 0
  for token in string.gmatch(a, "%S+") do
    if right[token] then
      score += 1
    end
  end
  return score
end

local function scoreTextMatch(target, candidate, exactScore, partialScore)
  if target == "" or candidate == "" then
    return 0
  end
  if target == candidate then
    return exactScore
  end
  if string.find(target, candidate, 1, true) or string.find(candidate, target, 1, true) then
    return partialScore
  end
  return countTokenOverlap(target, candidate) * 5
end

-- HTTP callbacks share a 25ms thread-CPU budget (Noctalia kCallbackBudget).
-- Cap every source the same; early-exit when title+artist+duration match well.
local SEARCH_CANDIDATE_LIMIT = 12
-- title exact(100) + artist exact(70) + duration(35)
local SCORE_EARLY_EXIT = 205

local function makeTrackNorms(track)
  return {
    title = normalizeText(track.title),
    artist = normalizeText(track.artist),
    album = normalizeText(track.album),
    durationMs = math.max(0, math.floor(tonumber(track.duration) or 0)) * 1000,
  }
end

local function nonEmptyText(value)
  if value == nil then
    return false
  end
  return noctalia.string.trim(tostring(value)) ~= ""
end

local function scoreTrackCandidate(norms, title, artists, album, durationMs)
  local score = scoreTextMatch(norms.title, normalizeText(title), 100, 55)
  local bestArtist = 0
  if type(artists) == "table" then
    for _, name in ipairs(artists) do
      local s = scoreTextMatch(norms.artist, normalizeText(name), 70, 35)
      if s > bestArtist then
        bestArtist = s
      end
    end
  end
  score += bestArtist
  score += scoreTextMatch(norms.album, normalizeText(album), 20, 10)
  durationMs = tonumber(durationMs) or 0
  if norms.durationMs > 0 and durationMs > 0 and math.abs(norms.durationMs - durationMs) < 5000 then
    score += 35
  end
  return score
end

-- ── LRC parsing ──────────────────────────────────────────────────────────────

local function parseFraction(raw)
  if raw == nil or raw == "" then
    return 0
  end
  local digits = tostring(raw):gsub("[^0-9]", "")
  if digits == "" then
    return 0
  end
  if #digits == 1 then
    return tonumber(digits) * 100
  end
  if #digits == 2 then
    return tonumber(digits) * 10
  end
  return tonumber(digits:sub(1, 3))
end

local function parseTimestamp(token)
  local raw = cleanText(token)
  if raw == "" then
    return nil
  end
  local parts = {}
  for part in string.gmatch(raw, "[^:]+") do
    table.insert(parts, part)
  end
  if #parts < 2 or #parts > 3 then
    return nil
  end
  local hours, minutes, secondChunk = 0, 0, ""
  if #parts == 3 then
    hours = tonumber(parts[1])
    minutes = tonumber(parts[2])
    secondChunk = parts[3]
  else
    minutes = tonumber(parts[1])
    secondChunk = parts[2]
  end
  if hours == nil or minutes == nil then
    return nil
  end
  local secParts = {}
  for part in string.gmatch(secondChunk, "[^.,]+") do
    table.insert(secParts, part)
  end
  local seconds = tonumber(secParts[1])
  if seconds == nil then
    return nil
  end
  local millis = parseFraction(secParts[2])
  return (((hours * 60) + minutes) * 60 + seconds) * 1000 + millis
end

local function parseLrc(text)
  local raw = tostring(text or "")
  if noctalia.string.trim(raw) == "" then
    return {}
  end
  raw = raw:gsub("\r", "")

  -- Collect (timeMs, text) by walking every [tag]. Text after a timestamp tag
  -- belongs to that timestamp until the next timestamp (handles single-line LRC
  -- where NetEase/others omit newlines between cues).
  local result = {}
  local globalOffsetMs = 0
  local pendingTimes = {}
  local lastEnd = 1

  local function flushPending(from, to)
    if #pendingTimes == 0 then
      return
    end
    local lyric = cleanText(raw:sub(from, to))
    if lyric ~= "" then
      for _, t in ipairs(pendingTimes) do
        table.insert(result, { timeMs = t, text = lyric })
      end
    end
    pendingTimes = {}
  end

  while true do
    local s, e, inner = string.find(raw, "%[([^%]]+)%]", lastEnd)
    if not s then
      flushPending(lastEnd, #raw)
      break
    end

    -- Text between previous tag end and this tag belongs to previous timestamps.
    if s > lastEnd then
      flushPending(lastEnd, s - 1)
    end

    local offsetMatch = string.match(inner, "^%s*[Oo][Ff][Ff][Ss][Ee][Tt]%s*:%s*(-?%d+)%s*$")
    if offsetMatch then
      globalOffsetMs = tonumber(offsetMatch) or 0
    else
      local ts = parseTimestamp(inner)
      if ts ~= nil then
        table.insert(pendingTimes, math.max(0, ts + globalOffsetMs))
      else
        -- Non-time tag (ar/ti/al/by…): ignore, do not flush.
      end
    end
    lastEnd = e + 1
  end

  table.sort(result, function(a, b)
    if a.timeMs == b.timeMs then
      return a.text < b.text
    end
    return a.timeMs < b.timeMs
  end)

  local deduped = {}
  for _, item in ipairs(result) do
    local prev = deduped[#deduped]
    if not prev or prev.timeMs ~= item.timeMs or prev.text ~= item.text then
      table.insert(deduped, item)
    end
  end
  return deduped
end

local function parsePlainLyrics(text)
  local raw = tostring(text or ""):gsub("\r", "")
  if noctalia.string.trim(raw) == "" then
    return {}
  end
  local result = {}
  for line in string.gmatch(raw .. "\n", "(.-)\n") do
    local cleaned = cleanText(line)
    if cleaned ~= "" and cleaned ~= result[#result] then
      table.insert(result, cleaned)
    end
  end
  return result
end

local function findLineIndex(entries, positionMs)
  if type(entries) ~= "table" or #entries == 0 then
    return -1
  end
  local target = tonumber(positionMs) or 0
  local low, high, best = 1, #entries, -1
  while low <= high do
    local mid = math.floor((low + high) / 2)
    local value = tonumber(entries[mid].timeMs) or 0
    if value <= target then
      best = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end
  -- 1-based index → convert to 0-based for parity with v4, but we use 1-based in Luau
  return best
end

local function selectBestLrcLibRecord(track, records)
  if type(records) ~= "table" or #records == 0 then
    return nil
  end
  local norms = makeTrackNorms(track)
  local duration = math.max(0, math.floor(tonumber(track.duration) or 0))
  local bestRecord, bestScore = nil, -1e9
  local maxScan = math.min(#records, SEARCH_CANDIDATE_LIMIT)

  for i = 1, maxScan do
    local record = records[i]
    if type(record) == "table" then
      local title = normalizeText(record.trackName or record.track_name or record.name)
      local artist = normalizeText(record.artistName or record.artist_name or record.artist)
      local album = normalizeText(record.albumName or record.album_name or record.album)
      local recordDuration = math.max(0, math.floor(tonumber(record.duration or record.length or record.trackLength) or 0))
      -- Presence only — do not cleanText full lyric bodies while scoring.
      local hasSynced = nonEmptyText(record.syncedLyrics or record.synced_lyrics)
      local hasPlain = nonEmptyText(record.plainLyrics or record.plain_lyrics or record.lyrics)
      local score = 0
      if hasSynced then
        score += 120
      elseif hasPlain then
        score += 40
      end
      score += scoreTextMatch(norms.title, title, 100, 55)
      score += scoreTextMatch(norms.artist, artist, 70, 35)
      score += scoreTextMatch(norms.album, album, 20, 10)
      if duration > 0 and recordDuration > 0 then
        local diff = math.abs(duration - recordDuration)
        if diff == 0 then
          score += 35
        else
          score += math.max(0, 35 - math.min(35, diff))
        end
      end
      if score > bestScore then
        bestScore = score
        bestRecord = record
        if bestScore >= SCORE_EARLY_EXIT + 120 then
          -- synced bonus + title/artist/duration strong match
          break
        end
      end
    end
  end
  return bestRecord
end

local function parseLyricsRecord(record)
  if type(record) ~= "table" then
    return nil
  end
  local synced = parseLrc(record.syncedLyrics or record.synced_lyrics or "")
  if #synced > 0 then
    return { state = "ready", entries = synced, plainLines = {}, error = "" }
  end
  local plain = parsePlainLyrics(record.plainLyrics or record.plain_lyrics or record.lyrics or "")
  if #plain > 0 then
    return { state = "plain", entries = {}, plainLines = plain, error = "" }
  end
  return nil
end

-- Attach a timed secondary LRC track onto primary entries by nearest timestamp.
-- Both sides are time-sorted → two-pointer O(n+m) instead of O(n*m).
local function mergeTimedField(primary, secondary, field, toleranceMs)
  if type(primary) ~= "table" or type(secondary) ~= "table" or #secondary == 0 then
    return primary
  end
  toleranceMs = tonumber(toleranceMs) or 500
  local j = 1
  local nPrimary = #primary
  if nPrimary == 0 then
    return primary
  end
  for _, s in ipairs(secondary) do
    local text = s.text or ""
    if text ~= "" then
      local st = tonumber(s.timeMs) or 0
      while j < nPrimary do
        local curDist = math.abs((tonumber(primary[j].timeMs) or 0) - st)
        local nextDist = math.abs((tonumber(primary[j + 1].timeMs) or 0) - st)
        if nextDist <= curDist then
          j += 1
        else
          break
        end
      end
      local dist = math.abs((tonumber(primary[j].timeMs) or 0) - st)
      if dist <= toleranceMs then
        local cur = primary[j][field]
        if cur == nil or cur == "" then
          primary[j][field] = text
        end
      end
    end
  end
  return primary
end

local function enrichEntriesWithSecondary(entries, translationLrc, romanizationLrc)
  if type(entries) ~= "table" or #entries == 0 then
    return entries
  end
  -- Ensure fields exist
  for _, e in ipairs(entries) do
    if e.translation == nil then
      e.translation = ""
    end
    if e.romanization == nil then
      e.romanization = ""
    end
  end
  if translationLrc and translationLrc ~= "" then
    mergeTimedField(entries, parseLrc(translationLrc), "translation", 500)
  end
  if romanizationLrc and romanizationLrc ~= "" then
    mergeTimedField(entries, parseLrc(romanizationLrc), "romanization", 500)
  end
  return entries
end

-- ── MPRIS via busctl JSON ────────────────────────────────────────────────────

local function variantData(node)
  if type(node) ~= "table" then
    return node
  end
  if node.data ~= nil then
    return node.data
  end
  return node
end

local function unwrapPlayerDict(dict)
  if type(dict) ~= "table" then
    return nil
  end
  local player = {}
  for key, node in pairs(dict) do
    player[key] = variantData(node)
  end
  return player
end

local function parseGetActivePlayerJson(raw)
  local decoded, err = noctalia.json.decode(raw)
  if not decoded then
    return nil, err or "json decode failed"
  end
  local payload = decoded.data
  if type(payload) ~= "table" then
    return nil, "unexpected busctl shape"
  end
  local found = payload[1]
  local dict = payload[2]
  if found ~= true then
    return { found = false }
  end
  local player = unwrapPlayerDict(dict)
  if not player then
    return { found = false }
  end
  local artists = player.artists
  local artistJoined = ""
  if type(artists) == "table" then
    local parts = {}
    for _, a in ipairs(artists) do
      local name = cleanText(a)
      if name ~= "" then
        table.insert(parts, name)
      end
    end
    artistJoined = table.concat(parts, ", ")
  end
  local positionUs = tonumber(player.position_us) or 0
  local lengthUs = tonumber(player.length_us) or 0
  return {
    found = true,
    busName = cleanText(player.bus_name),
    identity = cleanText(player.identity),
    desktopEntry = cleanText(player.desktop_entry),
    playbackStatus = cleanText(player.playback_status),
    title = cleanText(player.title),
    artist = artistJoined,
    album = cleanText(player.album),
    positionMs = math.max(0, math.floor(positionUs / 1000)),
    lengthMs = math.max(0, math.floor(lengthUs / 1000)),
    isPlaying = cleanText(player.playback_status) == "Playing",
  }
end

local function parseGetPositionJson(raw)
  local decoded, err = noctalia.json.decode(raw)
  if not decoded then
    return nil, err or "json decode failed"
  end
  local payload = decoded.data
  local us = nil
  if type(payload) == "table" then
    us = tonumber(payload[1])
  else
    us = tonumber(payload)
  end
  if us == nil or us < 0 then
    return nil, "bad position"
  end
  return math.floor(us / 1000)
end

local BUSCTL_ACTIVE =
  "busctl --user call dev.noctalia.Mpris /dev/noctalia/Mpris dev.noctalia.Mpris GetActivePlayer --json=short"
local BUSCTL_POS =
  "busctl --user call dev.noctalia.Mpris /dev/noctalia/Mpris dev.noctalia.Mpris GetPositionActive --json=short"

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

-- Read embedded lyrics from the player's own MPRIS Metadata (not Noctalia's
-- control dict). Keys commonly used by players / KDE / LRC providers.
local PLAYER_LYRIC_META_KEYS = {
  "xesam:asText",
  "xesam:lyrics",
  "xesam:lyric",
  "xesam:lrc",
  "mpris:lyrics",
  "kde:lyrics",
  "lyrics",
  "lyric",
  "syncedLyrics",
  "synced_lyrics",
  "lrc",
  "lrcLyrics",
  "lrc_lyrics",
  "lyricsText",
  "lyricText",
  "lrcText",
}

local function isLikelyLyricsMetaKey(key)
  local k = tostring(key or ""):lower()
  if k == "xesam:astext" then
    return true
  end
  return string.find(k, "lyric", 1, true) ~= nil or string.find(k, "lrc", 1, true) ~= nil
end

local function metaValueToText(value)
  if value == nil then
    return ""
  end
  if type(value) == "table" then
    -- busctl --json wraps as { type=..., data=... }
    if value.data ~= nil then
      return metaValueToText(value.data)
    end
    local parts = {}
    for _, item in ipairs(value) do
      local line = cleanText(item)
      if line ~= "" then
        table.insert(parts, line)
      end
    end
    return table.concat(parts, "\n")
  end
  return tostring(value)
end

local function extractLyricsFromMetadataDict(dict)
  if type(dict) ~= "table" then
    return ""
  end
  local candidates = {}
  local seen = {}

  local function addCandidate(raw)
    local text = metaValueToText(raw)
    -- Do not cleanText here — preserve newlines for LRC.
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local trimmed = noctalia.string.trim(text)
    if trimmed == "" or seen[trimmed] then
      return
    end
    seen[trimmed] = true
    table.insert(candidates, text)
  end

  for _, key in ipairs(PLAYER_LYRIC_META_KEYS) do
    if dict[key] ~= nil then
      addCandidate(dict[key])
    end
  end
  for key, value in pairs(dict) do
    if isLikelyLyricsMetaKey(key) then
      addCandidate(value)
    end
  end

  for _, text in ipairs(candidates) do
    local synced = parseLrc(text)
    if #synced > 0 then
      return text, "ready", synced
    end
  end
  for _, text in ipairs(candidates) do
    local plain = parsePlainLyrics(text)
    if #plain > 0 then
      return text, "plain", plain
    end
  end
  return "", nil, nil
end

local function parseMetadataJson(raw)
  local decoded, err = noctalia.json.decode(raw)
  if not decoded then
    return nil, err or "json decode failed"
  end
  -- get-property --json=short: { type: "a{sv}", data: { key: {type,data}, ... } }
  local data = decoded.data
  if type(data) ~= "table" then
    return nil, "unexpected metadata shape"
  end
  -- Sometimes nested under data again depending on busctl version
  if data.data ~= nil and type(data.data) == "table" and data.type ~= nil then
    data = data.data
  end
  local meta = {}
  for key, node in pairs(data) do
    meta[key] = variantData(node)
  end
  return meta
end

local function busctlMetadataCommand(busName)
  -- busctl get-property SERVICE OBJECT INTERFACE PROPERTY
  return "busctl --user get-property "
    .. shellQuote(busName)
    .. " /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Metadata --json=short"
end

local function tryPlayerEmbeddedLyrics(cacheKey, token, callback)
  local busName = track.busName
  if busName == nil or busName == "" then
    callback(nil)
    return
  end
  local cmd = busctlMetadataCommand(busName)
  local accepted = noctalia.runAsync(cmd, function(result)
    if token ~= fetchToken or cacheKey ~= track.key then
      callback(nil)
      return
    end
    if not result or result.exitCode ~= 0 then
      callback(nil)
      return
    end
    local meta = parseMetadataJson(result.stdout or "")
    if not meta then
      callback(nil)
      return
    end
    local _text, kind, payload = extractLyricsFromMetadataDict(meta)
    if kind == "ready" then
      callback({ state = "ready", entries = payload, plainLines = {}, error = "", source = "player" })
      return
    end
    if kind == "plain" then
      callback({ state = "plain", entries = {}, plainLines = payload, error = "", source = "player" })
      return
    end
    callback(nil)
  end, 3000)
  if not accepted then
    callback(nil)
  end
end

-- ── Player filter ────────────────────────────────────────────────────────────

local function normalizeFilterList(list)
  local out, seen = {}, {}
  if type(list) ~= "table" then
    return out
  end
  for _, rule in ipairs(list) do
    local r = noctalia.string.trim(tostring(rule or ""))
    local key = r:lower()
    if r ~= "" and not seen[key] then
      seen[key] = true
      table.insert(out, r)
    end
  end
  return out
end

local function playerAllowed(identity, desktopEntry)
  local mode = cfg("playerFilterMode")
  if mode ~= "blacklist" and mode ~= "whitelist" then
    return true
  end
  local rules = normalizeFilterList(cfg("playerFilterList"))
  local id = identity:lower()
  local de = desktopEntry:lower()
  local matched = false
  for _, rule in ipairs(rules) do
    local needle = rule:lower()
    if (id ~= "" and string.find(id, needle, 1, true)) or (de ~= "" and string.find(de, needle, 1, true)) then
      matched = true
      break
    end
  end
  if mode == "blacklist" then
    return not matched
  end
  return matched
end

-- ── Service state ────────────────────────────────────────────────────────────

local fetchState = "idle"
local lyricsEntries = {}
local plainLyricsLines = {}
local currentLineIndex = -1
local currentLyricsSource = ""
local lyricRevision = 0
local lyricsCache = {}
local lyricsCacheOrder = {}
local CACHE_LIMIT = 50

local track = {
  title = "",
  artist = "",
  album = "",
  duration = 0,
  key = "",
  busName = "",
  identity = "",
  desktopEntry = "",
  isPlaying = false,
  hasPlayer = false,
  hasActiveTrack = false,
}

local playhead = {
  ready = false,
  baseMs = 0,
  capturedAt = 0,
  isPlaying = false,
  trackKey = "",
  settleUntil = 0, -- ignore backward host samples until this (ms)
  zeroStreak = 0, -- consecutive near-zero host samples while we estimate ahead
}

local fetchToken = 0
local trackEpoch = 0 -- bumped on track identity change; invalidates in-flight pos polls
local pendingForceRefresh = false
local lastFetchScheduleAt = 0
local lastActivePollAt = 0
local lastPosPollAt = 0
local activePollInFlight = false
local posPollInFlight = false
local missingDepsNotified = false
local lastPublishedKey = ""
local loggedSourceKey = ""

local FALLBACK_ORDER = { "netease", "qqmusic", "lrclib" }

-- Per-line secondary fields for the widget (presentation chooses which to show).
local function currentLineField(field)
  if fetchState ~= "ready" or currentLineIndex < 1 or currentLineIndex > #lyricsEntries then
    return ""
  end
  local entry = lyricsEntries[currentLineIndex]
  if type(entry) ~= "table" then
    return ""
  end
  local text = entry[field]
  if text == nil or text == "" then
    return ""
  end
  return tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
end


-- ── Playhead ─────────────────────────────────────────────────────────────────

local function resetPlayhead()
  playhead.ready = false
  playhead.baseMs = 0
  playhead.capturedAt = 0
  playhead.isPlaying = false
  playhead.trackKey = ""
  playhead.settleUntil = 0
  playhead.zeroStreak = 0
end

local function setPlayheadBaseline(trackKey, positionMs, isPlaying, settleMs)
  playhead.trackKey = trackKey or ""
  playhead.baseMs = math.max(0, math.floor(tonumber(positionMs) or 0))
  playhead.capturedAt = nowMs()
  playhead.isPlaying = not not isPlaying
  playhead.ready = playhead.trackKey ~= ""
  playhead.zeroStreak = 0
  if settleMs and settleMs > 0 then
    playhead.settleUntil = playhead.capturedAt + settleMs
  end
end

local function estimatePositionMs()
  if not playhead.ready then
    return 0
  end
  if not playhead.isPlaying then
    return playhead.baseMs
  end
  local elapsed = nowMs() - playhead.capturedAt
  if elapsed < 0 or elapsed ~= elapsed then
    return playhead.baseMs
  end
  local pos = playhead.baseMs + elapsed
  if track.duration > 0 then
    pos = math.min(pos, track.duration * 1000)
  end
  return math.floor(pos)
end

-- Host projects position while Playing, but for ~1.25s after a track change
-- (and raw pos ≤ 5s) Noctalia returns unprojected MPRIS samples. Those raw
-- samples lag, and occasionally snap back to 0 even after projection resumes.
-- Logs showed: est=2710 obs=0 → line jumps 编曲→制作人. Defend with:
--   1) settle window after force/track change: no backward rebased
--   2) small lag ignore while playing
--   3) near-zero glitch filter (need 3 consecutive samples to accept →0)
local PLAYHEAD_LAG_IGNORE_MS = 2000
local PLAYHEAD_SETTLE_MS = 3000
local PLAYHEAD_ZERO_GLITCH_MS = 500

local function syncPlayhead(observedMs, isPlaying, force)
  local key = track.key
  if key == "" then
    resetPlayhead()
    return
  end
  observedMs = math.max(0, math.floor(tonumber(observedMs) or 0))

  if force or not playhead.ready or playhead.trackKey ~= key then
    setPlayheadBaseline(key, observedMs, isPlaying, PLAYHEAD_SETTLE_MS)
    return
  end

  local estimated = estimatePositionMs()
  local t = nowMs()

  -- play → pause: prefer local estimate if D-Bus is only slightly behind
  if not isPlaying and playhead.isPlaying then
    if math.abs(observedMs - estimated) <= 1200 then
      observedMs = estimated
    end
  elseif isPlaying and playhead.isPlaying then
    local lag = estimated - observedMs
    if lag > 0 then
      -- Fresh track: free-run from baseline; host zeros/lags are noise.
      if t < playhead.settleUntil then
        return
      end
      if lag <= PLAYHEAD_LAG_IGNORE_MS then
        return
      end
      -- Host occasionally reports 0 mid-play (not a real seek-to-start).
      if observedMs <= PLAYHEAD_ZERO_GLITCH_MS then
        playhead.zeroStreak += 1
        if playhead.zeroStreak < 3 then
          return
        end
      else
        playhead.zeroStreak = 0
      end
    else
      playhead.zeroStreak = 0
    end
  end

  setPlayheadBaseline(key, observedMs, isPlaying, 0)
end

-- ── Snapshot publish ─────────────────────────────────────────────────────────

local function sourceDisplayName(sourceKey)
  if sourceKey == "netease" then
    return noctalia.tr("status.source_netease")
  end
  if sourceKey == "qqmusic" then
    return noctalia.tr("status.source_qqmusic")
  end
  if sourceKey == "lrclib" then
    return noctalia.tr("status.source_lrclib")
  end
  if sourceKey == "player" then
    return noctalia.tr("status.source_player")
  end
  return cleanText(sourceKey)
end

local function stateLabel()
  if fetchState == "loading" then
    return noctalia.tr("status.loading")
  end
  if fetchState == "ready" then
    return noctalia.tr("status.ready")
  end
  if fetchState == "plain" then
    return noctalia.tr("status.plain")
  end
  if fetchState == "empty" then
    return noctalia.tr("status.empty")
  end
  if fetchState == "error" then
    return noctalia.tr("status.error")
  end
  if fetchState == "no-track" then
    return noctalia.tr("status.no_track")
  end
  return noctalia.tr("status.idle")
end

local function statusRoleFor(state)
  if state == "ready" then
    return "primary"
  end
  if state == "plain" then
    return "secondary"
  end
  if state == "loading" then
    return "tertiary"
  end
  if state == "error" then
    return "error"
  end
  return "outline"
end

local function currentLineText()
  if currentLineIndex >= 1 and currentLineIndex <= #lyricsEntries then
    return lyricsEntries[currentLineIndex].text or ""
  end
  return ""
end

local function plainExcerpt()
  if #plainLyricsLines > 0 then
    return plainLyricsLines[1]
  end
  return ""
end

local function barText()
  local line = currentLineText()
  if fetchState == "ready" and line ~= "" then
    return line
  end
  local plain = plainExcerpt()
  if fetchState == "plain" and plain ~= "" then
    return plain
  end
  if fetchState == "loading" then
    return stateLabel()
  end
  local summary = formatTrack(track.title, track.artist)
  if summary ~= "" then
    return summary
  end
  return stateLabel()
end

local function tooltipText()
  local parts = {}
  if track.title ~= "" then
    table.insert(parts, track.title)
  end
  if track.artist ~= "" then
    table.insert(parts, track.artist)
  end
  table.insert(parts, noctalia.tr("status.state_prefix", { state = stateLabel() }))
  if currentLyricsSource ~= "" then
    table.insert(parts, noctalia.tr("status.source_prefix", { source = sourceDisplayName(currentLyricsSource) }))
  end
  return table.concat(parts, "\n")
end

local function publishSnapshot()
  local snap = {
    hasPlayer = track.hasPlayer,
    hasActiveTrack = track.hasActiveTrack,
    trackTitle = track.title,
    trackArtist = track.artist,
    trackAlbum = track.album,
    trackDurationMs = track.duration * 1000,
    trackKey = track.key,
    playerIdentity = track.identity,
    playerDesktopEntry = track.desktopEntry,
    busName = track.busName,
    isPlaying = track.isPlaying,
    fetchState = fetchState,
    currentLineText = currentLineText(),
    -- Widget picks translation vs romanization (instance setting).
    currentTranslation = currentLineField("translation"),
    currentRomanization = currentLineField("romanization"),
    plainExcerpt = plainExcerpt(),
    currentLyricsSource = currentLyricsSource,
    barText = barText(),
    tooltipText = tooltipText(),
    statusRole = statusRoleFor(fetchState),
    lyricRevision = lyricRevision,
  }
  local key = table.concat({
    snap.fetchState,
    snap.barText,
    snap.currentTranslation or "",
    snap.currentRomanization or "",
    snap.tooltipText,
    snap.statusRole,
    tostring(snap.hasActiveTrack),
    tostring(snap.isPlaying),
    tostring(snap.lyricRevision),
  }, "|")
  if key == lastPublishedKey then
    return
  end
  lastPublishedKey = key
  noctalia.state.set("snapshot", snap)
end

local function updateCurrentLine(force)
  if fetchState ~= "ready" or #lyricsEntries == 0 then
    if currentLineIndex ~= -1 or force then
      currentLineIndex = -1
      lyricRevision += 1
    end
    return
  end
  local advance = tonumber(cfg("lyricAdvanceMs"))
  if advance == nil then
    advance = 0
  end
  local pos = math.max(0, estimatePositionMs() + advance)
  local nextIndex = findLineIndex(lyricsEntries, pos)
  if nextIndex ~= currentLineIndex or force then
    currentLineIndex = nextIndex
    lyricRevision += 1
  end
end

-- ── Cache ────────────────────────────────────────────────────────────────────

local function storeCache(cacheKey, result)
  lyricsCache[cacheKey] = result
  local order = {}
  for _, k in ipairs(lyricsCacheOrder) do
    if k ~= cacheKey then
      table.insert(order, k)
    end
  end
  table.insert(order, cacheKey)
  while #order > CACHE_LIMIT do
    local evicted = table.remove(order, 1)
    lyricsCache[evicted] = nil
  end
  lyricsCacheOrder = order
end

local function applyResult(result, cacheKey)
  result = result or { state = "empty", entries = {}, plainLines = {}, error = "", source = "" }
  storeCache(cacheKey, result)
  fetchState = result.state or "empty"
  lyricsEntries = result.entries or {}
  plainLyricsLines = result.plainLines or {}
  if fetchState == "ready" or fetchState == "plain" then
    currentLyricsSource = result.source or ""
  else
    currentLyricsSource = ""
  end
  if cacheKey ~= "" and currentLyricsSource ~= "" then
    local sk = `{cacheKey}::{currentLyricsSource}`
    if sk ~= loggedSourceKey then
      log(`[Title] {track.title} [Source] {sourceDisplayName(currentLyricsSource)}`)
      loggedSourceKey = sk
    end
  end
  updateCurrentLine(true)
  publishSnapshot()
end

local function resetLyricsState(newState)
  fetchState = newState
  lyricsEntries = {}
  plainLyricsLines = {}
  currentLineIndex = -1
  currentLyricsSource = ""
  loggedSourceKey = ""
  -- Keep playhead when still on the same track (e.g. force refresh); clear only
  -- when leaving an active track.
  if newState == "idle" or newState == "no-track" then
    resetPlayhead()
  end
  lyricRevision += 1
  publishSnapshot()
end

-- ── NetEase weapi ────────────────────────────────────────────────────────────

local WEAPI_PRESET_KEY_HEX = "30436f4a556d365179773857386a7564"
local WEAPI_IV_HEX = "30313032303330343035303630373038"
local WEAPI_PUBKEY = table.concat({
  "-----BEGIN PUBLIC KEY-----",
  "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB",
  "-----END PUBLIC KEY-----",
}, "\n")

local BASE62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
math.randomseed(os.time() + (os.clock() * 1e6) // 1)

local function randomSecret()
  local secret = {}
  for _ = 1, 16 do
    local idx = math.random(1, #BASE62)
    table.insert(secret, BASE62:sub(idx, idx))
  end
  return table.concat(secret)
end

local function asciiHex(value)
  local out = {}
  for i = 1, #value do
    table.insert(out, string.format("%02x", string.byte(value, i)))
  end
  return table.concat(out)
end

local function reverseString(value)
  return string.reverse(value)
end

local function buildNeteaseEncryptCommand(payload)
  local secretText = randomSecret()
  local payloadText = noctalia.json.encode(payload) or "{}"
  local secretHex = asciiHex(secretText)
  local reversedSecret = reverseString(secretText)
  local zeroByteCount = 128 - #secretText
  local script = table.concat({
    "set -eu",
    "payload=" .. shellQuote(payloadText),
    "secret_hex=" .. shellQuote(secretHex),
    "reversed_secret=" .. shellQuote(reversedSecret),
    'tmp_pub=$(mktemp)',
    "trap 'rm -f \"$tmp_pub\"' EXIT HUP INT TERM",
    "cat > \"$tmp_pub\" <<'NETEASE_PUBKEY'",
    WEAPI_PUBKEY,
    "NETEASE_PUBKEY",
    "first=$(printf %s \"$payload\" | openssl enc -aes-128-cbc -K "
      .. WEAPI_PRESET_KEY_HEX
      .. " -iv "
      .. WEAPI_IV_HEX
      .. " -base64 -A | tr -d '=')",
    "second=$(printf %s \"$first\" | openssl enc -aes-128-cbc -K \"$secret_hex\" -iv "
      .. WEAPI_IV_HEX
      .. " -base64 -A | tr -d '=')",
    "enc_sec_key=$({ dd if=/dev/zero bs=1 count="
      .. tostring(zeroByteCount)
      .. ' 2>/dev/null; printf %s "$reversed_secret"; } | openssl pkeyutl -encrypt -pubin -inkey "$tmp_pub" -pkeyopt rsa_padding_mode:none | od -An -tx1 -v | tr -d \' \\n\')',
    "printf '{\\\"params\\\":\\\"%s\\\",\\\"encSecKey\\\":\\\"%s\\\"}\\n' \"$second\" \"$enc_sec_key\"",
  }, "\n")
  return `sh -c {shellQuote(script)}`
end

local function parseNeteaseEncryptStdout(text)
  local decoded = noctalia.json.decode(noctalia.string.trim(tostring(text or "")))
  if type(decoded) ~= "table" then
    return nil
  end
  local params = tostring(decoded.params or "")
  local encSecKey = tostring(decoded.encSecKey or "")
  if params == "" or not string.match(encSecKey, "^[0-9a-f]+$") or #encSecKey ~= 256 then
    return nil
  end
  return { params = params, encSecKey = encSecKey }
end

-- ── Lyrics fetch orchestration ───────────────────────────────────────────────

local function normalizeSource(sourceKey)
  if sourceKey == "netease" or sourceKey == "qqmusic" or sourceKey == "lrclib" then
    return sourceKey
  end
  return "netease"
end

local function lyricsSourceOrder()
  local preferred = normalizeSource(cfg("primaryLyricsSource"))
  local order = { preferred }
  for _, key in ipairs(FALLBACK_ORDER) do
    if key ~= preferred then
      table.insert(order, key)
    end
  end
  return order
end

local requestTimeoutMs = function()
  local t = tonumber(cfg("requestTimeoutMs")) or 5000
  return math.max(1000, math.min(12000, t))
end

local function httpGet(url, headers, callback)
  noctalia.http({
    url = url,
    method = "GET",
    headers = headers,
  }, callback)
end

local function httpPost(url, body, headers, callback)
  noctalia.http({
    url = url,
    method = "POST",
    body = body,
    headers = headers,
  }, callback)
end

-- forward decl
local fetchNextSource
local loadLyrics

local function fetchLrcLib(cacheKey, token, callback)
  local title = track.title
  local artist = track.artist
  local album = track.album
  local duration = track.duration
  if title == "" and artist == "" then
    callback(nil)
    return
  end

  local params = {
    track_name = title,
    artist_name = artist,
  }
  if album ~= "" then
    params.album_name = album
  end
  if duration > 0 then
    params.duration = tostring(duration)
  end
  local parts = {}
  for k, v in pairs(params) do
    if cleanText(v) ~= "" then
      table.insert(parts, `{noctalia.string.urlEncode(k)}={noctalia.string.urlEncode(tostring(v))}`)
    end
  end
  local exactUrl = "https://lrclib.net/api/get?" .. table.concat(parts, "&")

  httpGet(exactUrl, { "Accept: application/json" }, function(res)
    if token ~= fetchToken or cacheKey ~= track.key then
      callback(nil)
      return
    end
    local parsed = nil
    if res.ok and res.status >= 200 and res.status < 300 then
      local data = noctalia.json.decode(res.body)
      parsed = parseLyricsRecord(data)
      if parsed and parsed.state == "ready" then
        callback(parsed)
        return
      end
    end

    local searchParams = {}
    if title ~= "" then
      searchParams.track_name = title
    end
    if artist ~= "" then
      searchParams.artist_name = artist
    end
    if album ~= "" then
      searchParams.album_name = album
    end
    local sp = {}
    for k, v in pairs(searchParams) do
      table.insert(sp, `{noctalia.string.urlEncode(k)}={noctalia.string.urlEncode(tostring(v))}`)
    end
    if #sp == 0 then
      callback(parsed)
      return
    end
    local searchUrl = "https://lrclib.net/api/search?" .. table.concat(sp, "&")
    httpGet(searchUrl, { "Accept: application/json" }, function(res2)
      if token ~= fetchToken or cacheKey ~= track.key then
        callback(nil)
        return
      end
      if res2.ok and res2.status >= 200 and res2.status < 300 then
        local data = noctalia.json.decode(res2.body)
        if type(data) == "table" then
          local candidate = selectBestLrcLibRecord(track, data)
          local fromSearch = parseLyricsRecord(candidate)
          if fromSearch then
            callback(fromSearch)
            return
          end
        end
      end
      callback(parsed)
    end)
  end)
end

local function neteaseWeApi(url, payload, cacheKey, token, callback)
  if not noctalia.commandExists("openssl") then
    callback(false, nil, "openssl missing")
    return
  end
  local cmd = buildNeteaseEncryptCommand(payload)
  local accepted = noctalia.runAsync(cmd, function(result)
    if token ~= fetchToken or cacheKey ~= track.key then
      callback(false, nil, "stale")
      return
    end
    if not result or result.exitCode ~= 0 then
      callback(false, nil, (result and result.stderr) or "encrypt failed")
      return
    end
    local form = parseNeteaseEncryptStdout(result.stdout)
    if not form then
      callback(false, nil, "invalid encrypt output")
      return
    end
    local body = `params={noctalia.string.urlEncode(form.params)}&encSecKey={noctalia.string.urlEncode(form.encSecKey)}`
    httpPost(url, body, {
      "Content-Type: application/x-www-form-urlencoded",
      "Accept: application/json",
      "Referer: https://music.163.com/",
      "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 11_1_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/88.0.4324.87 Safari/537.36",
    }, function(res)
      if token ~= fetchToken or cacheKey ~= track.key then
        callback(false, nil, "stale")
        return
      end
      if not res.ok or res.status < 200 or res.status >= 300 then
        callback(false, nil, `http {res.status}`)
        return
      end
      local data = noctalia.json.decode(res.body)
      callback(true, data, "")
    end)
  end, requestTimeoutMs() + 2000)
  if not accepted then
    callback(false, nil, "runAsync rejected")
  end
end

local function fetchNetease(cacheKey, token, callback)
  local keyword = track.title
  if track.artist ~= "" and track.title ~= "" then
    keyword = `{track.title} {track.artist}`
  elseif track.artist ~= "" then
    keyword = track.artist
  end
  if keyword == "" then
    callback(nil)
    return
  end
  neteaseWeApi("https://music.163.com/weapi/cloudsearch/pc", {
    s = keyword,
    type = 1,
    offset = 0,
    total = true,
    limit = SEARCH_CANDIDATE_LIMIT,
  }, cacheKey, token, function(ok, data)
    if not ok or type(data) ~= "table" then
      callback(nil)
      return
    end
    if tonumber(data.code or 200) ~= 200 then
      callback(nil)
      return
    end
    local songs = data.result and data.result.songs
    if type(songs) ~= "table" or #songs == 0 then
      callback(nil)
      return
    end
    local norms = makeTrackNorms(track)
    local bestScore, bestId = -1, ""
    local maxScan = math.min(#songs, SEARCH_CANDIDATE_LIMIT)
    for i = 1, maxScan do
      local song = songs[i]
      local artists = {}
      if type(song.ar) == "table" then
        for _, ar in ipairs(song.ar) do
          table.insert(artists, cleanText(ar and ar.name))
        end
      end
      local score = scoreTrackCandidate(
        norms,
        cleanText(song.name),
        artists,
        cleanText(song.al and song.al.name),
        tonumber(song.dt) or 0
      )
      if score > bestScore then
        bestScore = score
        bestId = cleanText(song.id)
        if bestScore >= SCORE_EARLY_EXIT then
          break
        end
      end
    end
    if bestId == "" or bestScore < 100 then
      callback(nil)
      return
    end
    neteaseWeApi("https://music.163.com/weapi/song/lyric", {
      id = bestId,
      lv = -1,
      tv = -1,
      rv = -1,
      kv = -1,
      _nmclfl = 1,
    }, cacheKey, token, function(ok2, lyricData)
      if not ok2 or type(lyricData) ~= "table" then
        callback(nil)
        return
      end
      if tonumber(lyricData.code or 200) ~= 200 then
        callback(nil)
        return
      end
      local lyric = tostring(lyricData.lrc and lyricData.lrc.lyric or "")
      local parsed = parseLrc(lyric)
      if #parsed > 0 then
        local tlyric = tostring(lyricData.tlyric and lyricData.tlyric.lyric or "")
        local romalrc = tostring(lyricData.romalrc and lyricData.romalrc.lyric or "")
        enrichEntriesWithSecondary(parsed, tlyric, romalrc)
        callback({ state = "ready", entries = parsed, plainLines = {}, error = "" })
      else
        callback(nil)
      end
    end)
  end)
end

local function fetchQQMusic(cacheKey, token, callback)
  local keyword = track.title
  if track.artist ~= "" and track.title ~= "" then
    keyword = `{track.artist} {track.title}`
  elseif track.artist ~= "" then
    keyword = track.artist
  end
  if keyword == "" then
    callback(nil)
    return
  end
  local searchBody = noctalia.json.encode({
    comm = {
      ct = 19,
      cv = "1845",
      v = "1003006",
      os_ver = "12",
      phonetype = "0",
      devicelevel = "31",
      tmeAppID = "qqmusiclight",
      nettype = "NETWORK_WIFI",
    },
    req = {
      module = "music.search.SearchCgiService",
      method = "DoSearchForQQMusicLite",
      param = {
        query = keyword,
        search_type = 0,
        num_per_page = SEARCH_CANDIDATE_LIMIT,
        page_num = 0,
        nqc_flag = 0,
        grp = 0,
      },
    },
  }) or "{}"

  httpPost("https://u.y.qq.com/cgi-bin/musicu.fcg", searchBody, {
    "Accept: application/json",
    "Content-Type: application/json",
    "User-Agent: Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)",
  }, function(res)
    if token ~= fetchToken or cacheKey ~= track.key then
      callback(nil)
      return
    end
    if not res.ok or res.status < 200 or res.status >= 300 then
      callback(nil)
      return
    end
    local data = noctalia.json.decode(res.body)
    if type(data) ~= "table" then
      callback(nil)
      return
    end
    local topCode = tonumber(data.code or 0)
    local reqCode = tonumber(data.req and data.req.code or 0)
    if topCode ~= 0 or reqCode ~= 0 then
      callback(nil)
      return
    end
    local songs = data.req and data.req.data and data.req.data.body and data.req.data.body.item_song
    if type(songs) ~= "table" or #songs == 0 then
      callback(nil)
      return
    end
    local norms = makeTrackNorms(track)
    local bestScore, bestMid = -1, ""
    local maxScan = math.min(#songs, SEARCH_CANDIDATE_LIMIT)
    for i = 1, maxScan do
      local song = songs[i]
      local artists = {}
      if type(song.singer) == "table" then
        for _, s in ipairs(song.singer) do
          table.insert(artists, cleanText(s and s.name))
        end
      end
      local durationMs = (tonumber(song.interval) or 0) * 1000
      local score = scoreTrackCandidate(
        norms,
        cleanText(song.songname or song.name or song.title),
        artists,
        cleanText(song.albumname or (song.album and (song.album.name or song.album.title))),
        durationMs
      )
      if score > bestScore then
        bestScore = score
        bestMid = cleanText(song.mid)
        if bestScore >= SCORE_EARLY_EXIT then
          break
        end
      end
    end
    if bestMid == "" or bestScore < 100 then
      callback(nil)
      return
    end
    local lyricUrl = "https://i.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?"
      .. table.concat({
        `songmid={noctalia.string.urlEncode(bestMid)}`,
        "g_tk=5381",
        "format=json",
        "inCharset=utf8",
        "outCharset=utf-8",
        "nobase64=1",
      }, "&")
    httpGet(lyricUrl, {
      "Accept: application/json",
      "Referer: https://y.qq.com",
    }, function(res2)
      if token ~= fetchToken or cacheKey ~= track.key then
        callback(nil)
        return
      end
      if not res2.ok or res2.status < 200 or res2.status >= 300 then
        callback(nil)
        return
      end
      local payload = noctalia.json.decode(res2.body)
      if type(payload) ~= "table" then
        callback(nil)
        return
      end
      local code = tonumber(payload.code or 0)
      local retcode = tonumber(payload.retcode or 0)
      local subcode = tonumber(payload.subcode or 0)
      if code ~= 0 or retcode ~= 0 or subcode ~= 0 then
        callback(nil)
        return
      end
      local lyric = tostring(payload.lyric or "")
      local parsed = parseLrc(lyric)
      if #parsed > 0 then
        local trans = tostring(payload.trans or "")
        local roma = tostring(payload.roma or "")
        -- Some responses base64-encode when nobase64 is ignored
        if trans ~= "" and not string.find(trans, "%[%d", 1) then
          -- leave as-is; plain non-LRC trans is useless for merge
          trans = ""
        end
        if roma ~= "" and not string.find(roma, "%[%d", 1) then
          roma = ""
        end
        enrichEntriesWithSecondary(parsed, trans, roma)
        callback({ state = "ready", entries = parsed, plainLines = {}, error = "" })
      else
        callback(nil)
      end
    end)
  end)
end

local function fetchFromSource(sourceKey, cacheKey, token, callback)
  if sourceKey == "netease" then
    fetchNetease(cacheKey, token, callback)
  elseif sourceKey == "qqmusic" then
    fetchQQMusic(cacheKey, token, callback)
  else
    fetchLrcLib(cacheKey, token, callback)
  end
end

fetchNextSource = function(cacheKey, token, sources, index)
  if token ~= fetchToken or cacheKey ~= track.key then
    return
  end
  if index > #sources then
    applyResult({ state = "empty", entries = {}, plainLines = {}, error = "", source = "" }, cacheKey)
    return
  end
  local sourceKey = sources[index]
  fetchFromSource(sourceKey, cacheKey, token, function(result)
    if token ~= fetchToken or cacheKey ~= track.key then
      return
    end
    if result then
      result.source = sourceKey
      applyResult(result, cacheKey)
      return
    end
    fetchNextSource(cacheKey, token, sources, index + 1)
  end)
end

loadLyrics = function(forceRefresh)
  if not track.hasActiveTrack then
    resetLyricsState(if track.hasPlayer then "no-track" else "idle")
    return
  end
  local cacheKey = track.key
  if cacheKey == "" then
    resetLyricsState("no-track")
    return
  end

  fetchToken += 1
  local token = fetchToken
  local preferPlayer = cfg("preferPlayerLyrics")
  if preferPlayer == nil then
    preferPlayer = false
  end

  local function useCacheOrNetwork()
    if token ~= fetchToken or cacheKey ~= track.key then
      return
    end
    local cached = lyricsCache[cacheKey]
    if not forceRefresh and type(cached) == "table" then
      -- Don't reuse player-sourced cache when preferPlayerLyrics is off.
      if preferPlayer or cached.source ~= "player" then
        applyResult(cached, cacheKey)
        return
      end
    end

    fetchState = "loading"
    lyricsEntries = {}
    plainLyricsLines = {}
    currentLineIndex = -1
    currentLyricsSource = ""
    lyricRevision += 1
    publishSnapshot()
    fetchNextSource(cacheKey, token, lyricsSourceOrder(), 1)
  end

  if preferPlayer and track.busName ~= "" then
    fetchState = "loading"
    lyricsEntries = {}
    plainLyricsLines = {}
    currentLineIndex = -1
    currentLyricsSource = ""
    lyricRevision += 1
    publishSnapshot()
    tryPlayerEmbeddedLyrics(cacheKey, token, function(result)
      if token ~= fetchToken or cacheKey ~= track.key then
        return
      end
      if result then
        applyResult(result, cacheKey)
        return
      end
      useCacheOrNetwork()
    end)
    return
  end

  useCacheOrNetwork()
end

local function scheduleLyricsRefresh(force)
  pendingForceRefresh = pendingForceRefresh or not not force
  lastFetchScheduleAt = nowMs()
end

local function consumeScheduledFetch()
  if lastFetchScheduleAt <= 0 then
    return
  end
  if (nowMs() - lastFetchScheduleAt) < 250 then
    return
  end
  local force = pendingForceRefresh
  pendingForceRefresh = false
  lastFetchScheduleAt = 0
  loadLyrics(force)
end

-- ── MPRIS polling ────────────────────────────────────────────────────────────

local function applyActivePlayer(info)
  if not info or not info.found then
    local had = track.hasPlayer or track.hasActiveTrack
    track.hasPlayer = false
    track.hasActiveTrack = false
    track.title = ""
    track.artist = ""
    track.album = ""
    track.duration = 0
    track.key = ""
    track.busName = ""
    track.identity = ""
    track.desktopEntry = ""
    track.isPlaying = false
    if had then
      trackEpoch += 1
      resetLyricsState("idle")
    else
      publishSnapshot()
    end
    return
  end

  if not playerAllowed(info.identity, info.desktopEntry) then
    local had = track.hasPlayer or track.hasActiveTrack
    track.hasPlayer = false
    track.hasActiveTrack = false
    track.title = ""
    track.artist = ""
    track.album = ""
    track.duration = 0
    track.key = ""
    track.busName = info.busName
    track.identity = info.identity
    track.desktopEntry = info.desktopEntry
    track.isPlaying = false
    if had then
      trackEpoch += 1
      resetLyricsState("idle")
    else
      publishSnapshot()
    end
    return
  end

  local durationSec = 0
  if info.lengthMs > 0 then
    durationSec = math.floor((info.lengthMs / 1000) + 0.5)
  end
  local nextKey = buildTrackKey(info.title, info.artist, info.album)
  local trackChanged = nextKey ~= track.key
  local playingChanged = info.isPlaying ~= track.isPlaying

  track.hasPlayer = true
  track.hasActiveTrack = info.title ~= "" or info.artist ~= ""
  track.title = info.title
  track.artist = info.artist
  track.album = info.album
  -- Keep last known duration if this sample omits length (common right after skip).
  if durationSec > 0 or trackChanged then
    track.duration = durationSec
  end
  track.key = nextKey
  track.busName = info.busName
  track.identity = info.identity
  track.desktopEntry = info.desktopEntry
  track.isPlaying = info.isPlaying

  syncPlayhead(info.positionMs, info.isPlaying, trackChanged)
  if trackChanged then
    trackEpoch += 1
    -- Prefer cache immediately so we don't flash "searching" on a known track.
    -- Network path still goes through the debounced schedule.
    local preferPlayer = cfg("preferPlayerLyrics")
    if preferPlayer == nil then
      preferPlayer = false
    end
    local cached = lyricsCache[nextKey]
    if type(cached) == "table" and (preferPlayer or cached.source ~= "player") then
      fetchToken += 1
      applyResult(cached, nextKey)
    else
      resetLyricsState("loading")
      scheduleLyricsRefresh(false)
    end
  elseif not track.hasActiveTrack then
    resetLyricsState("no-track")
  elseif playingChanged then
    updateCurrentLine(false)
  end
  publishSnapshot()
end

local function pollActivePlayer()
  if activePollInFlight then
    return
  end
  if not noctalia.commandExists("busctl") then
    if not missingDepsNotified then
      missingDepsNotified = true
      noctalia.notifyError(noctalia.tr("errors.plugin_title"), noctalia.tr("errors.busctl_missing"))
    end
    return
  end
  activePollInFlight = true
  local accepted = noctalia.runAsync(BUSCTL_ACTIVE, function(result)
    activePollInFlight = false
    -- Transient failures must not wipe a healthy track (would flash idle/hide).
    if not result or result.exitCode ~= 0 then
      return
    end
    local info, err = parseGetActivePlayerJson(result.stdout or "")
    if not info then
      log(`GetActivePlayer parse failed: {err or "?"}`)
      return
    end
    applyActivePlayer(info)
  end, 3000)
  if not accepted then
    activePollInFlight = false
  end
end

local function pollPosition()
  if posPollInFlight or not track.hasActiveTrack or not track.isPlaying then
    return
  end
  posPollInFlight = true
  local epoch = trackEpoch
  local accepted = noctalia.runAsync(BUSCTL_POS, function(result)
    posPollInFlight = false
    if epoch ~= trackEpoch then
      return
    end
    if not result or result.exitCode ~= 0 then
      return
    end
    local posMs = parseGetPositionJson(result.stdout or "")
    if posMs == nil then
      return
    end
    syncPlayhead(posMs, track.isPlaying, false)
    updateCurrentLine(false)
    publishSnapshot()
  end, 2000)
  if not accepted then
    posPollInFlight = false
  end
end

-- ── Commands / IPC / config ──────────────────────────────────────────────────

local function forceRefresh()
  scheduleLyricsRefresh(true)
end

local function consumeCommand()
  local cmd = noctalia.state.get("command")
  if type(cmd) ~= "table" then
    return
  end
  noctalia.state.set("command", nil)
  if cmd.op == "refresh" then
    forceRefresh()
  end
end

function onIpc(event, _payload)
  if event == "refresh" then
    forceRefresh()
  end
end

local lastLyricsFetchFp = lyricsConfigFingerprint()

function onConfigChanged()
  -- Service owns filter/source/timing only. Presentation is per-widget instance.
  local fp = lyricsConfigFingerprint()
  local changed = fp ~= lastLyricsFetchFp
  lastLyricsFetchFp = fp
  lastLyricsConfigFp = fp

  if not changed then
    updateCurrentLine(true)
    publishSnapshot()
    return
  end

  if track.key ~= "" then
    lyricsCache[track.key] = nil
  end
  if track.hasPlayer and not playerAllowed(track.identity, track.desktopEntry) then
    applyActivePlayer(nil)
    return
  end
  scheduleLyricsRefresh(true)
  updateCurrentLine(true)
  publishSnapshot()
end

-- ── Tick ─────────────────────────────────────────────────────────────────────

function update()
  noctalia.setUpdateInterval(TICK_MS)
  -- Only advance the tick-clock fallback when /proc/uptime is unavailable.
  if not useProcUptime then
    wallMs += TICK_MS
  end

  consumeCommand()
  consumeScheduledFetch()

  local t = nowMs()
  if (t - lastActivePollAt) >= ACTIVE_POLL_MS then
    lastActivePollAt = t
    pollActivePlayer()
  end
  -- Prefer frequent GetPositionActive while lyrics are live: host projection is
  -- more accurate than long local interpolation.
  local posInterval = if fetchState == "ready" then POS_POLL_MS else 500
  if track.hasActiveTrack and track.isPlaying and (t - lastPosPollAt) >= posInterval then
    lastPosPollAt = t
    pollPosition()
  end

  if fetchState == "ready" then
    updateCurrentLine(false)
  end
  publishSnapshot()
end

-- bootstrap
if not noctalia.commandExists("busctl") and not missingDepsNotified then
  missingDepsNotified = true
  noctalia.notifyError(noctalia.tr("errors.plugin_title"), noctalia.tr("errors.busctl_missing"))
end
publishSnapshot()
pollActivePlayer()
