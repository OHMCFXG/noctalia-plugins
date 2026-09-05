--!nonstrict
-- Xiaomi Plug bar widget.

local snapshot = noctalia.state.get("plug") or {}

local function safeText(value, fallback)
  if value == nil then
    return fallback or ""
  end
  local text = tostring(value)
  return text ~= "" and text or (fallback or "")
end

local function powerGlyph(watts)
  if watts ~= nil and watts >= 0.5 then
    return "bolt"
  end
  return "plug"
end

local function glyphFor(status, errorCode, watts)
  if status == "unconfigured" then
    return "settings"
  end
  if errorCode == "missing_python" or errorCode == "missing_uv" or errorCode == "missing_runtime" or errorCode == "missing_miio" or errorCode == "missing_script" then
    return "package"
  end
  if errorCode == "invalid_ip" or errorCode == "invalid_token" then
    return "settings"
  end
  if errorCode == "offline" then
    return "plug-off"
  end
  if status == "ready" or status == "loading" then
    return powerGlyph(watts)
  end
  if watts ~= nil then
    return powerGlyph(watts)
  end
  return "alert-circle"
end

local function render()
  local status = safeText(snapshot.status, "unconfigured")
  local errorCode = safeText(snapshot.errorCode, "")
  local powerText = safeText(snapshot.compactPowerText, "--")
  local watts = tonumber(snapshot.power)

  if status == "unconfigured" then
    powerText = "--"
  elseif status == "loading" and snapshot.compactPowerText == nil then
    powerText = "…"
  elseif status == "error" and snapshot.compactPowerText == nil then
    powerText = "--"
  end

  local icon = glyphFor(status, errorCode, watts)

  barWidget.setVisible(true)
  barWidget.setGlyph(icon)
  barWidget.setText(powerText)

  local tooltip
  if status == "unconfigured" then
    tooltip = noctalia.tr("plug.status.unconfigured") .. " · " .. noctalia.tr("plug.setup.path")
  elseif status == "loading" then
    if snapshot.powerText ~= nil then
      tooltip = safeText(snapshot.powerText, powerText)
    else
      tooltip = noctalia.tr("plug.status.loading")
    end
  elseif status == "ready" then
    tooltip = safeText(snapshot.powerText, powerText)
  elseif snapshot.error ~= nil and snapshot.error ~= "" then
    tooltip = tostring(snapshot.error)
  else
    tooltip = noctalia.tr("plug.status.unavailable")
  end
  if snapshot.stale == true then
    tooltip = tooltip .. " · " .. noctalia.tr("plug.status.stale")
  end
  barWidget.setTooltip(tooltip)
end

local function requestRefresh()
  noctalia.state.set("plug-command", {
    op = "refresh",
    token = tostring(os.time()),
  })
end

noctalia.state.watch("plug", function(value)
  snapshot = type(value) == "table" and value or {}
  render()
end)

function update()
  noctalia.setUpdateInterval(1000)
  render()
end

function onClick()
  noctalia.openSettings()
end

function onRightClick()
  requestRefresh()
end

function onIpc(event, _payload)
  if event == "refresh" then
    requestRefresh()
  elseif event == "settings" then
    noctalia.openSettings()
  end
end

render()
