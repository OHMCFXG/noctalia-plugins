--!nonstrict
-- MPRIS Lyrics — bar widget (thin client over service snapshot).

local snap = noctalia.state.get("snapshot") or {}

local function cfgBool(key, fallback)
  local value = noctalia.getConfig(key)
  if value == nil then
    return fallback
  end
  return not not value
end

local function cfgNumber(key, fallback)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    return fallback
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

-- v4: max(6, round(capsuleHeight * 0.16)), capsule ~ barThickness * 0.76
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

local function roleColor(role)
  if role == "primary" then
    return "primary"
  end
  if role == "secondary" then
    return "secondary"
  end
  if role == "tertiary" then
    return "tertiary"
  end
  if role == "error" then
    return "error"
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

local lastRenderKey = ""

local function render()
  local showDot = cfgBool("showBarStatusDot", true)
  local hideWhenIdle = cfgBool("barHideWhenIdle", true)
  local maxWidth = math.max(40, cfgNumber("barMaxWidth", 180))
  local widthMode = cfgString("barWidthMode", "adaptive")
  if widthMode ~= "fixed" then
    widthMode = "adaptive"
  end

  if shouldHide(hideWhenIdle) then
    if lastRenderKey ~= "hidden" then
      lastRenderKey = "hidden"
      barWidget.setVisible(false)
      barWidget.clearTooltip()
    end
    return
  end

  local text = displayText()
  local color = roleColor(snap.statusRole)
  local isFixed = widthMode == "fixed"
  local dotSize = statusDotSize()
  local renderKey = table.concat({
    text,
    color,
    tostring(showDot),
    tostring(maxWidth),
    widthMode,
    tostring(dotSize),
    tostring(snap.fetchState or ""),
  }, "|")
  if renderKey == lastRenderKey then
    return
  end
  lastRenderKey = renderKey

  barWidget.setVisible(true)
  local gap = 6
  local dotSlot = if showDot then (dotSize + gap) else 0
  local textWidth = math.max(40, maxWidth - dotSlot)

  local children = {}
  if showDot then
    table.insert(children, ui.box({
      width = dotSize,
      height = dotSize,
      radius = dotSize / 2,
      fill = color,
      opacity = if snap.fetchState == "loading" then 0.55 else 1.0,
    }))
  end

  local labelProps = {
    text = text,
    maxWidth = textWidth,
    maxLines = 1,
    color = if snap.fetchState == "ready" or snap.fetchState == "plain" then "on_surface" else "on_surface_variant",
  }
  if isFixed then
    labelProps.width = textWidth
  end
  table.insert(children, ui.label(labelProps))

  local container = if barWidget.isVertical() then ui.column else ui.row
  local rowProps = {
    gap = gap,
    align = "center",
  }
  if isFixed then
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
