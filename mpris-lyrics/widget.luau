--!nonstrict
-- MPRIS Lyrics — bar widget (thin client over service snapshot).
-- Owns presentation only. Track/lyrics data come from the service snapshot.

local snap = noctalia.state.get("snapshot") or {}

-- ── Config helpers ───────────────────────────────────────────────────────────

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value == true or value == "true" or value == 1 or value == "1"
end

local function cfgNumber(key, fallback, lo, hi)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    value = fallback
  end
  if lo ~= nil then
    value = math.max(lo, value)
  end
  if hi ~= nil then
    value = math.min(hi, value)
  end
  return value
end

local function cfgString(key, fallback)
  local value = noctalia.getConfig(key)
  if type(value) ~= "string" or value == "" then
    return fallback
  end
  return value
end

-- ── Bar metrics ──────────────────────────────────────────────────────────────

local DEFAULT_BAR_THICKNESS = 34
local CAPSULE_FRACTION = 0.76
local DOT_FRACTION = 0.16
local DEFAULT_ROW_GAP = 6
local TWO_LINE_ROW_GAP = 3

local barThickness = DEFAULT_BAR_THICKNESS
local thicknessRefreshLeft = 0

local function readBarThickness()
  local paths = {
    noctalia.expandPath("~/.local/state/noctalia/settings.toml"),
    noctalia.expandPath("~/.config/noctalia/config.toml"),
  }
  for _, path in ipairs(paths) do
    local raw = noctalia.readFile(path)
    if type(raw) == "string" then
      local t = tonumber(string.match(raw, "thickness%s*=%s*(%d+)"))
      if t ~= nil and t >= 16 and t <= 96 then
        return t
      end
    end
  end
  return DEFAULT_BAR_THICKNESS
end

local function statusDotSize()
  return math.max(6, math.floor(barThickness * CAPSULE_FRACTION * DOT_FRACTION + 0.5))
end

-- ── Snapshot → text ──────────────────────────────────────────────────────────

local function roleColor(role)
  if role == "primary" or role == "secondary" or role == "tertiary" or role == "error" then
    return role
  end
  return "outline"
end

local function mainText()
  local text = snap.barText
  if type(text) == "string" and text ~= "" then
    return text
  end
  return noctalia.tr("status.idle")
end

-- Host textAlign tokens are start|center|end (settings use left|center|right).
local function hostTextAlign(value)
  if value == "left" or value == "start" then
    return "start"
  end
  if value == "right" or value == "end" then
    return "end"
  end
  return "center"
end

local function extraLineText()
  if not cfgBool("showSecondaryLine", false) then
    return ""
  end
  local field
  if cfgString("secondaryLineContent", "translation") == "romanization" then
    field = snap.currentRomanization
  else
    field = snap.currentTranslation
  end
  if type(field) == "string" and field ~= "" then
    return field
  end
  return ""
end

-- ── Layout plan (one place for all presentation knobs) ───────────────────────

local function readLayout()
  local widthMode = cfgString("barWidthMode", "adaptive")
  if widthMode ~= "fixed" then
    widthMode = "adaptive"
  end
  local extra = extraLineText()
  local showExtra = extra ~= ""
  return {
    showDot = cfgBool("showBarStatusDot", true),
    hideWhenIdle = cfgBool("barHideWhenIdle", true),
    maxWidth = math.max(40, cfgNumber("barMaxWidth", 180, 40, 640)),
    widthMode = widthMode,
    fixed = widthMode == "fixed",
    textAlign = hostTextAlign(cfgString("textAlign", "center")),
    padL = cfgNumber("paddingLeft", 3, 0, 32),
    padR = cfgNumber("paddingRight", 3, 0, 32),
    extraText = extra,
    showExtra = showExtra,
    primaryFontSize = cfgNumber("secondaryPrimaryFontSize", 12, 8, 20),
    extraFontSize = cfgNumber("secondaryFontSize", 10, 7, 16),
    lineGap = cfgNumber("secondaryLineGap", -4, -12, 8),
    extraOpacity = cfgNumber("secondaryOpacity", 70, 30, 100) / 100,
    rowGap = if showExtra then TWO_LINE_ROW_GAP else DEFAULT_ROW_GAP,
    vertical = barWidget.isVertical(),
  }
end

-- Width budget for the lyric column when mode is fixed (after pads/dot/gaps).
-- Adaptive mode ignores this as a hard cap (no ellipsis); only fixed uses it.
local function lyricColumnWidth(layout, dotSize)
  local padL = if layout.vertical then 0 else layout.padL
  local padR = if layout.vertical then 0 else layout.padR
  local parts = 1 -- lyric column
  if padL > 0 then
    parts += 1
  end
  if layout.showDot then
    parts += 1
  end
  if padR > 0 then
    parts += 1
  end
  local fixed = padL + padR + (if layout.showDot then dotSize else 0)
  local gaps = math.max(0, parts - 1) * layout.rowGap
  return math.max(24, layout.maxWidth - fixed - gaps), padL, padR
end

-- ── UI builders ──────────────────────────────────────────────────────────────

local function makeLabel(text, opts)
  local label = {
    text = text,
    maxLines = 1,
    color = opts.color,
    textAlign = opts.textAlign,
  }
  -- Only cap when fixed (or explicit); adaptive omits maxWidth so the label
  -- sizes to full content without ellipsis.
  if opts.maxWidth ~= nil then
    label.maxWidth = opts.maxWidth
  end
  if opts.fontSize ~= nil then
    label.fontSize = opts.fontSize
  end
  if opts.fontWeight ~= nil then
    label.fontWeight = opts.fontWeight
  end
  if opts.baseline ~= nil then
    label.baseline = opts.baseline
  end
  if opts.opacity ~= nil then
    label.opacity = opts.opacity
  end
  return ui.label(label)
end

-- Force a layout width so host textAlign can shift ink inside the box.
-- (label.width is ignored by the reconciler; stretch columns assign exact width.)
local function forceWidthColumn(child, width)
  return ui.column({
    width = width,
    minWidth = width,
    gap = 0,
    align = "stretch",
    justify = "center",
    flexGrow = 1,
  }, { child })
end

local function buildLyricColumn(main, extra, width, layout, fetchState)
  local mainColor = if fetchState == "ready" or fetchState == "plain" then "on_surface" else "on_surface_variant"
  local align = layout.textAlign
  -- Fixed: cap + force box width for alignment/ellipsis.
  -- Adaptive: no maxWidth → grow with full lyric (no "..." from our side).
  local cap = if layout.fixed then width else nil

  if not layout.showExtra then
    local label = makeLabel(main, {
      maxWidth = cap,
      color = mainColor,
      textAlign = align,
    })
    if layout.fixed then
      return forceWidthColumn(label, width)
    end
    return label
  end

  local primary = makeLabel(main, {
    maxWidth = cap,
    color = mainColor,
    textAlign = align,
    fontSize = layout.primaryFontSize,
    fontWeight = "normal",
    baseline = "inkCentered",
  })
  local secondary = makeLabel(extra, {
    maxWidth = cap,
    color = "on_surface_variant",
    textAlign = align,
    fontSize = layout.extraFontSize,
    fontWeight = "normal",
    baseline = "inkCentered",
    opacity = layout.extraOpacity,
  })

  local props = {
    gap = layout.lineGap,
    justify = "center",
    padding = 0,
    paddingV = 0,
  }
  if layout.fixed then
    props.width = width
    props.minWidth = width
    props.align = "stretch"
    props.flexGrow = 1
  else
    props.align = align
  end
  return ui.column(props, { primary, secondary })
end

local function spacer(width)
  return ui.box({ width = width, height = 1, opacity = 0 })
end

local function statusDot(size, color, loading)
  return ui.box({
    width = size,
    height = size,
    radius = size / 2,
    fill = color,
    opacity = if loading then 0.55 else 1.0,
  })
end

-- ── Render ───────────────────────────────────────────────────────────────────

local lastRenderKey = ""

local function render()
  local layout = readLayout()

  if layout.hideWhenIdle and not snap.hasActiveTrack then
    if lastRenderKey ~= "hidden" then
      lastRenderKey = "hidden"
      barWidget.setVisible(false)
      barWidget.clearTooltip()
    end
    return
  end

  local main = mainText()
  local color = roleColor(snap.statusRole)
  local baseDot = statusDotSize()
  local dotSize = if layout.showExtra then math.max(5, math.floor(baseDot * 0.85 + 0.5)) else baseDot
  local textWidth, padL, padR = lyricColumnWidth(layout, dotSize)

  local renderKey = table.concat({
    main,
    layout.extraText,
    color,
    tostring(layout.showDot),
    tostring(layout.maxWidth),
    layout.widthMode,
    tostring(dotSize),
    tostring(layout.showExtra),
    tostring(layout.primaryFontSize),
    tostring(layout.extraFontSize),
    tostring(layout.lineGap),
    tostring(layout.extraOpacity),
    tostring(padL),
    tostring(padR),
    layout.textAlign,
    tostring(snap.fetchState or ""),
  }, "|")
  if renderKey == lastRenderKey then
    return
  end
  lastRenderKey = renderKey

  barWidget.setVisible(true)

  local children = {}
  if padL > 0 then
    table.insert(children, spacer(padL))
  end
  if layout.showDot then
    table.insert(children, statusDot(dotSize, color, snap.fetchState == "loading"))
  end
  table.insert(children, buildLyricColumn(main, layout.extraText, textWidth, layout, snap.fetchState))
  if padR > 0 then
    table.insert(children, spacer(padR))
  end

  local container = if layout.vertical then ui.column else ui.row
  local rowProps = {
    gap = layout.rowGap,
    align = "center",
    justify = "start",
  }
  if layout.fixed and not layout.vertical then
    rowProps.width = layout.maxWidth
    rowProps.minWidth = layout.maxWidth
  end
  barWidget.render(container(rowProps, children))

  local tip = snap.tooltipText
  if type(tip) == "string" and tip ~= "" then
    barWidget.setTooltip(tip)
  else
    barWidget.clearTooltip()
  end
end

noctalia.state.watch("snapshot", function(value)
  snap = if type(value) == "table" then value else {}
  render()
end)

function update()
  noctalia.setUpdateInterval(if snap.fetchState == "ready" then 100 else 250)
  thicknessRefreshLeft -= 1
  if thicknessRefreshLeft <= 0 then
    barThickness = readBarThickness()
    thicknessRefreshLeft = 50
  end
  render()
end

function onRightClick()
  noctalia.state.set("command", { op = "refresh", token = tostring(os.time()) })
  noctalia.notify(noctalia.tr("actions.refresh"), snap.trackTitle or "")
end

function onIpc(event, _payload)
  if event == "refresh" then
    noctalia.state.set("command", { op = "refresh", token = tostring(os.time()) })
  end
end

barThickness = readBarThickness()
render()
