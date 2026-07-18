--!nonstrict
-- MPRIS Lyrics — bar widget (thin client over service snapshot).
-- Presentation-only: width, status dot, optional secondary line layout.
-- Data (track, lines, translation/romanization) comes from the service snapshot.

local snap = noctalia.state.get("snapshot") or {}

-- ── Config helpers (instance settings from middle-click + seeded plugin keys) ─

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return value == true or value == "true" or value == 1 or value == "1"
end

local function cfgNumber(key, fallback, minValue, maxValue)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    value = fallback
  end
  if minValue ~= nil then
    value = math.max(minValue, value)
  end
  if maxValue ~= nil then
    value = math.min(maxValue, value)
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

-- ── Bar thickness / status dot ───────────────────────────────────────────────

local DEFAULT_BAR_THICKNESS = 34
local CAPSULE_FRACTION = 0.76
local DOT_FRACTION = 0.16
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
  local capsule = barThickness * CAPSULE_FRACTION
  return math.max(6, math.floor(capsule * DOT_FRACTION + 0.5))
end

-- ── Presentation helpers ─────────────────────────────────────────────────────

local function roleColor(role)
  if role == "primary" or role == "secondary" or role == "tertiary" or role == "error" then
    return role
  end
  return "outline"
end

local function hasActiveTrack()
  return not not snap.hasActiveTrack
end

local function shouldHide(hideWhenIdle)
  return hideWhenIdle and not hasActiveTrack()
end

local function displayText()
  local text = snap.barText
  if type(text) == "string" and text ~= "" then
    return text
  end
  return noctalia.tr("status.idle")
end

-- Choose secondary text from service-provided translation / romanization fields.
local function secondaryText()
  if not cfgBool("showSecondaryLine", false) then
    return ""
  end
  local mode = cfgString("secondaryLineContent", "translation")
  local text = ""
  if mode == "romanization" then
    text = snap.currentRomanization
  else
    text = snap.currentTranslation
  end
  if type(text) == "string" and text ~= "" then
    return text
  end
  return ""
end

local function secondaryLayout()
  return {
    primaryFontSize = cfgNumber("secondaryPrimaryFontSize", 12, 8, 20),
    secondaryFontSize = cfgNumber("secondaryFontSize", 10, 7, 16),
    lineGap = cfgNumber("secondaryLineGap", -4, -12, 8),
    opacity = cfgNumber("secondaryOpacity", 70, 30, 100) / 100,
    rowGap = 3,
  }
end

local function normalizeTextAlign(value)
  if value == "left" or value == "right" or value == "center" then
    return value
  end
  return "center"
end

-- Map text align to flex cross-axis align for the two-line column.
local function columnAlignFor(textAlign)
  if textAlign == "left" then
    return "start"
  end
  if textAlign == "right" then
    return "end"
  end
  return "center"
end

local function buildTextBlock(text, secondary, textWidth, isFixed, fetchState, textAlign)
  local primaryColor = if fetchState == "ready" or fetchState == "plain" then "on_surface" else "on_surface_variant"
  local showSecondary = secondary ~= ""
  local layout = if showSecondary then secondaryLayout() else nil
  textAlign = normalizeTextAlign(textAlign)

  local primaryLabel = {
    text = text,
    maxWidth = textWidth,
    maxLines = 1,
    color = primaryColor,
    textAlign = textAlign,
  }
  -- Fixed width: force label box width so textAlign/ellipsis align consistently.
  if isFixed then
    primaryLabel.width = textWidth
  end

  if not showSecondary then
    return ui.label(primaryLabel), 6
  end

  primaryLabel.fontSize = layout.primaryFontSize
  primaryLabel.fontWeight = "normal"
  primaryLabel.baseline = "inkCentered"

  local secondaryLabel = {
    text = secondary,
    maxWidth = textWidth,
    maxLines = 1,
    fontSize = layout.secondaryFontSize,
    fontWeight = "normal",
    baseline = "inkCentered",
    color = "on_surface_variant",
    opacity = layout.opacity,
    textAlign = textAlign,
  }
  if isFixed then
    secondaryLabel.width = textWidth
  end

  local block = ui.column({
    gap = layout.lineGap,
    align = columnAlignFor(textAlign),
    justify = "center",
    padding = 0,
    paddingV = 0,
  }, {
    ui.label(primaryLabel),
    ui.label(secondaryLabel),
  })
  return block, layout.rowGap
end

-- ── Render ───────────────────────────────────────────────────────────────────

local lastRenderKey = ""

local function render()
  local showDot = cfgBool("showBarStatusDot", true)
  local hideWhenIdle = cfgBool("barHideWhenIdle", true)
  local maxWidth = math.max(40, cfgNumber("barMaxWidth", 180, 40, 640))
  local widthMode = cfgString("barWidthMode", "adaptive")
  if widthMode ~= "fixed" then
    widthMode = "adaptive"
  end
  local textAlign = normalizeTextAlign(cfgString("textAlign", "center"))
  local paddingLeft = cfgNumber("paddingLeft", 6, 0, 32)
  local paddingRight = cfgNumber("paddingRight", 6, 0, 32)

  if shouldHide(hideWhenIdle) then
    if lastRenderKey ~= "hidden" then
      lastRenderKey = "hidden"
      barWidget.setVisible(false)
      barWidget.clearTooltip()
    end
    return
  end

  local text = displayText()
  local secondary = secondaryText()
  local color = roleColor(snap.statusRole)
  local isFixed = widthMode == "fixed"
  local isVertical = barWidget.isVertical()
  local showSecondary = secondary ~= ""
  local dotSize = statusDotSize()
  local layout = if showSecondary then secondaryLayout() else {
    primaryFontSize = 0,
    secondaryFontSize = 0,
    lineGap = 0,
    opacity = 0,
    rowGap = 6,
  }

  local renderKey = table.concat({
    text,
    secondary,
    color,
    tostring(showDot),
    tostring(maxWidth),
    widthMode,
    tostring(dotSize),
    tostring(showSecondary),
    tostring(layout.primaryFontSize),
    tostring(layout.secondaryFontSize),
    tostring(layout.lineGap),
    tostring(layout.opacity),
    tostring(paddingLeft),
    tostring(paddingRight),
    textAlign,
    tostring(snap.fetchState or ""),
  }, "|")
  if renderKey == lastRenderKey then
    return
  end
  lastRenderKey = renderKey

  barWidget.setVisible(true)
  local gap = layout.rowGap
  local visualDot = if showSecondary then math.max(5, math.floor(dotSize * 0.85 + 0.5)) else dotSize
  local dotSlot = if showDot then (visualDot + gap) else 0
  local sidePad = if isVertical then 0 else (paddingLeft + paddingRight)
  local textWidth = math.max(40, maxWidth - dotSlot - sidePad)
  local textBlock = buildTextBlock(text, secondary, textWidth, isFixed, snap.fetchState, textAlign)

  local children = {}
  if not isVertical and paddingLeft > 0 then
    table.insert(children, ui.box({ width = paddingLeft, height = 1, opacity = 0 }))
  end
  if showDot then
    table.insert(children, ui.box({
      width = visualDot,
      height = visualDot,
      radius = visualDot / 2,
      fill = color,
      opacity = if snap.fetchState == "loading" then 0.55 else 1.0,
    }))
  end
  table.insert(children, textBlock)
  if not isVertical and paddingRight > 0 then
    table.insert(children, ui.box({ width = paddingRight, height = 1, opacity = 0 }))
  end

  local container = if isVertical then ui.column else ui.row
  local rowProps = {
    gap = gap,
    align = "center",
  }
  -- Prefer host horizontal padding when supported (also keeps fixed-width math simple).
  if not isVertical then
    rowProps.paddingH = 0
  end
  if isFixed and not isVertical then
    rowProps.width = maxWidth
    rowProps.minWidth = maxWidth
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
  if type(value) == "table" then
    snap = value
  else
    snap = {}
  end
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
