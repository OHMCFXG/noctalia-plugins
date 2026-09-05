--!nonstrict
-- Xiaomi Plug service: polls live power via the bundled Python helper.

local DEFAULT_POLL_SECONDS = 5
local MIN_POLL_SECONDS = 3
local MAX_POLL_SECONDS = 60
local UPDATE_INTERVAL_MS = 1000
local QUERY_TIMEOUT_MS = 15000
local UV_QUERY_TIMEOUT_MS = 60000
local DEFAULT_SIID = 11
local DEFAULT_PIID = 2

local requestInFlight = false
local requestSerial = 0
local lastFetchAt = 0
local lastConfigFingerprint = ""
local lastGoodModel = nil
local missingDepNotified = false

local function cfg(key)
  return noctalia.getConfig(key)
end

local function cleanText(value)
  if value == nil then
    return ""
  end
  return noctalia.string.trim(tostring(value):gsub("[\r\n\t]+", " "):gsub("%s+", " "))
end

local function number(value, fallback)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value) or fallback
  end
  return fallback
end

local function powerText(value)
  local watts = number(value)
  if watts == nil then
    return "--"
  end
  if math.abs(watts - math.floor(watts + 0.5)) < 0.05 then
    return tostring(math.floor(watts + 0.5)) .. " W"
  end
  return string.format("%.1f W", watts)
end

local function compactPowerText(value)
  local watts = number(value)
  if watts == nil then
    return "--"
  end
  if math.abs(watts - math.floor(watts + 0.5)) < 0.05 then
    return tostring(math.floor(watts + 0.5)) .. "W"
  end
  return string.format("%.1fW", watts)
end

local function emptyModel(status, error, stale, errorCode)
  return {
    status = status,
    stale = stale == true,
    error = error,
    errorCode = errorCode,
    power = nil,
    powerText = nil,
    compactPowerText = nil,
    updatedAt = nil,
  }
end

local function copyWithMeta(model, status, stale, error)
  local copy = {}
  if type(model) == "table" then
    for key, value in pairs(model) do
      copy[key] = value
    end
  end
  copy.status = status
  copy.stale = stale == true
  copy.error = error
  copy.errorCode = nil
  return copy
end

local function publish(model)
  noctalia.state.set("plug", model)
end

local function pollSeconds()
  local seconds = math.floor(number(cfg("pollSeconds"), DEFAULT_POLL_SECONDS) or DEFAULT_POLL_SECONDS)
  return math.max(MIN_POLL_SECONDS, math.min(MAX_POLL_SECONDS, seconds))
end

local function isIpv4(value)
  local a, b, c, d = string.match(value, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil then
    return false
  end
  return tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255
end

local function isToken(value)
  return string.match(value, "^%x+$") ~= nil and #value == 32
end

local function pythonInterpreter()
  local configured = cleanText(cfg("pythonPath"))
  if configured == "" then
    return "python3", noctalia.commandExists("python3")
  end
  local path = noctalia.expandPath(configured)
  return path, noctalia.fileExists(path)
end

local function pollCommand(script, values)
  local query = {
    "--ip",
    values.ip,
    "--token",
    values.token,
    "--siid",
    tostring(values.siid),
    "--piid",
    tostring(values.piid),
  }

  local function withQuery(prefix, timeoutMs)
    local argv = {}
    for _, argument in ipairs(prefix) do
      table.insert(argv, argument)
    end
    for _, argument in ipairs(query) do
      table.insert(argv, argument)
    end
    return argv, timeoutMs, nil
  end

  local configured = cleanText(cfg("pythonPath"))
  if configured ~= "" then
    local python, pythonOk = pythonInterpreter()
    if not pythonOk then
      return nil, nil, "missing_python"
    end
    return withQuery({ python, script }, QUERY_TIMEOUT_MS)
  end

  if noctalia.commandExists("uv") then
    return withQuery({
      "uv",
      "run",
      "--no-project",
      "--quiet",
      "--with",
      "python-miio",
      "--",
      "python",
      script,
    }, UV_QUERY_TIMEOUT_MS)
  end

  local python, pythonOk = pythonInterpreter()
  if pythonOk then
    return withQuery({ python, script }, QUERY_TIMEOUT_MS)
  end

  return nil, nil, "missing_runtime"
end

local function configValues()
  local ip = cleanText(cfg("ip"))
  local token = cleanText(cfg("token"))
  if ip == "" or token == "" then
    return nil, "unconfigured"
  end
  if not isIpv4(ip) then
    return nil, "invalid_ip"
  end
  if not isToken(token) then
    return nil, "invalid_token"
  end

  local siid = math.floor(number(cfg("siid"), DEFAULT_SIID) or DEFAULT_SIID)
  local piid = math.floor(number(cfg("piid"), DEFAULT_PIID) or DEFAULT_PIID)
  siid = math.max(1, math.min(255, siid))
  piid = math.max(1, math.min(255, piid))

  return {
    ip = ip,
    token = token,
    siid = siid,
    piid = piid,
  }, nil
end

local function configFingerprint()
  return table.concat({
    cleanText(cfg("ip")),
    cleanText(cfg("token")),
    tostring(cfg("siid") or ""),
    tostring(cfg("piid") or ""),
    cleanText(cfg("pythonPath")),
  }, "|")
end

local function failureMessage(code)
  if code == "missing_python" then
    return noctalia.tr("plug.errors.missing_python")
  end
  if code == "missing_uv" then
    return noctalia.tr("plug.errors.missing_uv")
  end
  if code == "missing_runtime" then
    return noctalia.tr("plug.errors.missing_runtime")
  end
  if code == "missing_script" then
    return noctalia.tr("plug.errors.missing_script")
  end
  if code == "missing_miio" then
    return noctalia.tr("plug.errors.missing_miio")
  end
  if code == "invalid_ip" then
    return noctalia.tr("plug.errors.invalid_ip")
  end
  if code == "invalid_token" then
    return noctalia.tr("plug.errors.invalid_token")
  end
  if code == "invalid_response" then
    return noctalia.tr("plug.errors.invalid_response")
  end
  if code == "request_rejected" then
    return noctalia.tr("plug.errors.request_rejected")
  end
  if code == "timed_out" then
    return noctalia.tr("plug.errors.timed_out")
  end
  if code == "offline" then
    return noctalia.tr("plug.errors.offline")
  end
  return noctalia.tr("plug.errors.device")
end

local function publishUnconfigured(reason)
  lastGoodModel = nil
  if reason == "unconfigured" then
    publish(emptyModel("unconfigured", nil, false, nil))
    return
  end
  publish(emptyModel("error", failureMessage(reason), false, reason))
end

local function readyModel(watts)
  return {
    status = "ready",
    stale = false,
    error = nil,
    errorCode = nil,
    power = watts,
    powerText = powerText(watts),
    compactPowerText = compactPowerText(watts),
    updatedAt = os.time(),
  }
end

local function failWith(code)
  local message = failureMessage(code)
  if lastGoodModel ~= nil then
    local model = copyWithMeta(lastGoodModel, "error", true, message)
    model.errorCode = code
    publish(model)
  else
    publish(emptyModel("error", message, false, code))
  end
end

local function decodeHelperPayload(stdout)
  local text = cleanText(stdout)
  local payload = noctalia.json.decode(text)
  if type(payload) == "table" then
    return payload
  end
  local last = string.match(text, "([^\n]+)$")
  if last ~= nil and last ~= text then
    payload = noctalia.json.decode(noctalia.string.trim(last))
    if type(payload) == "table" then
      return payload
    end
  end
  return nil
end

local function notifyMissingDep(code)
  if missingDepNotified then
    return
  end
  missingDepNotified = true
  noctalia.notifyError(noctalia.tr("plug.status.unavailable"), failureMessage(code))
end

local function queryPower()
  if requestInFlight then
    return
  end

  local values, configError = configValues()
  if configError ~= nil then
    lastFetchAt = os.time()
    publishUnconfigured(configError)
    return
  end

  local pluginDir = noctalia.pluginDir()
  local script = nil
  if type(pluginDir) == "string" and pluginDir ~= "" then
    script = pluginDir .. "/poll.py"
  end
  if script == nil or not noctalia.fileExists(script) then
    lastFetchAt = os.time()
    failWith("missing_script")
    return
  end

  local argv, timeoutMs, commandError = pollCommand(script, values)
  if commandError ~= nil then
    lastFetchAt = os.time()
    failWith(commandError)
    notifyMissingDep(commandError)
    return
  end

  requestInFlight = true
  requestSerial += 1
  local serial = requestSerial
  local fingerprint = configFingerprint()
  if lastGoodModel == nil then
    publish(emptyModel("loading", nil, false))
  end

  local accepted = noctalia.runAsync(argv, function(result)
    requestInFlight = false
    if serial ~= requestSerial then
      return
    end
    if configFingerprint() ~= fingerprint then
      queryPower()
      return
    end

    lastFetchAt = os.time()
    if type(result) ~= "table" then
      failWith("request_rejected")
      return
    end
    if result.timedOut == true then
      failWith("timed_out")
      return
    end

    local payload = decodeHelperPayload(result.stdout)
    if type(payload) ~= "table" then
      failWith("invalid_response")
      return
    end

    if payload.ok == true then
      local watts = number(payload.power)
      if watts == nil then
        failWith("invalid_response")
        return
      end
      local model = readyModel(watts)
      lastGoodModel = model
      publish(model)
      return
    end

    local code = cleanText(payload.error)
    if code == "missing_miio" then
      notifyMissingDep("missing_miio")
      failWith("missing_miio")
      return
    end
    if code == "offline" then
      failWith("offline")
      return
    end
    failWith("device")
  end, timeoutMs)

  if not accepted then
    requestInFlight = false
    lastFetchAt = os.time()
    failWith("request_rejected")
  end
end

noctalia.setUpdateInterval(UPDATE_INTERVAL_MS)
noctalia.state.watch("plug-command", function(value)
  if type(value) == "table" and value.op == "refresh" then
    queryPower()
  end
end)

function onConfigChanged()
  local fingerprint = configFingerprint()
  local changed = fingerprint ~= lastConfigFingerprint
  lastConfigFingerprint = fingerprint
  if changed then
    missingDepNotified = false
    queryPower()
  end
end

function onIpc(event, _payload)
  if event == "refresh" then
    queryPower()
  end
end

function update()
  local fingerprint = configFingerprint()
  if fingerprint ~= lastConfigFingerprint then
    lastConfigFingerprint = fingerprint
    missingDepNotified = false
    queryPower()
    return
  end

  if not requestInFlight and (lastFetchAt == 0 or os.time() - lastFetchAt >= pollSeconds()) then
    queryPower()
  end
end

lastConfigFingerprint = configFingerprint()
queryPower()
