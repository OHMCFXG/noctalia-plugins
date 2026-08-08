--!nonstrict
-- Caiyun Weather bar widget.

local snapshot = noctalia.state.get("weather") or {}
local PANEL_ID = "0x1ce/caiyun-weather:weather"

local function safeText(value, fallback)
  if value == nil then
    return fallback or ""
  end
  local text = tostring(value)
  return text ~= "" and text or (fallback or "")
end

local function render()
  local status = safeText(snapshot.status, "unconfigured")
  local current = type(snapshot.current) == "table" and snapshot.current or {}
  local icon = safeText(current.icon, status == "unconfigured" and "map-pin" or "cloud-off")
  local temperature = safeText(current.compactTemperatureText, "--")

  if status == "loading" and current.compactTemperatureText == nil then
    icon = "cloud"
    temperature = "…"
  elseif status == "error" and current.compactTemperatureText == nil then
    icon = "cloud-off"
    temperature = "--"
  end

  barWidget.setVisible(true)
  barWidget.setGlyph(icon)
  barWidget.setText(temperature)

  local location = safeText(snapshot.locationName, noctalia.tr("weather.location_unknown"))
  local condition = safeText(current.condition, noctalia.tr("weather.status.unavailable"))
  local tooltip = location .. " · " .. condition
  if current.temperatureText ~= nil then
    tooltip = tooltip .. " · " .. current.temperatureText
  end
  if snapshot.stale == true then
    tooltip = tooltip .. " · " .. noctalia.tr("weather.status.stale")
  end
  barWidget.setTooltip(tooltip)
end

local function requestRefresh()
  noctalia.state.set("weather-command", {
    op = "refresh",
    token = tostring(os.time()),
  })
end

noctalia.state.watch("weather", function(value)
  snapshot = type(value) == "table" and value or {}
  render()
end)

function update()
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
  requestRefresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    requestRefresh()
  elseif event == "toggle" then
    noctalia.togglePanel(PANEL_ID)
  end
end

render()
