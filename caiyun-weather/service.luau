--!nonstrict
-- Caiyun Weather service: fetches one normalized snapshot for the widget and panel.

local API_URL = "https://api.caiyunapp.com/v2.7/Y2FpeXVuIGFuZHJpb2QgYXBp/"
local API_SUFFIX = "/weather?alert=true"
local DEFAULT_REFRESH_MINUTES = 10
local MIN_REFRESH_MINUTES = 1
local MAX_REFRESH_MINUTES = 120
local UPDATE_INTERVAL_MS = 60000

local requestInFlight = false
local requestSerial = 0
local lastFetchAt = 0
local lastConfigFingerprint = ""
local lastGoodModel = nil

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


local function numberText(value, decimals, fallback)
  local n = number(value)
  if n == nil then
    return fallback or "--"
  end
  return string.format("%." .. tostring(decimals or 0) .. "f", n)
end

local function temperatureText(value)
  return numberText(value, 1, "--") .. "°"
end

local function compactTemperatureText(value)
  local n = number(value)
  if n == nil then
    return "--"
  end
  return tostring(math.floor(n + 0.5)) .. "°"
end

local function percentText(value)
  local n = number(value)
  if n == nil then
    return "--"
  end
  if n <= 1 then
    n *= 100
  end
  return tostring(math.floor(n + 0.5)) .. "%"
end

local function probabilityText(value)
  return percentText(value)
end

local function pressureText(value)
  local n = number(value)
  if n == nil then
    return "--"
  end
  return numberText(n / 100, 0) .. " hPa"
end

local function isoTime(value)
  local hour, minute = string.match(tostring(value or ""), "T(%d%d):(%d%d)")
  if hour ~= nil and minute ~= nil then
    return hour .. ":" .. minute
  end
  return "--:--"
end

local function isoDate(value)
  local year, month, day = string.match(tostring(value or ""), "^(%d%d%d%d)-(%d%d)-(%d%d)")
  if year ~= nil then
    return year .. "-" .. month .. "-" .. day
  end
  return ""
end

local function shortDate(value, index)
  if index == 1 then
    return noctalia.tr("weather.today")
  end
  local _, month, day = string.match(tostring(value or ""), "^(%d%d%d%d)-(%d%d)-(%d%d)")
  if month ~= nil then
    return month .. "/" .. day
  end
  return "--/--"
end

local function apiClock(unixSeconds, tzshift)
  local timestamp = number(unixSeconds, os.time()) + number(tzshift, 0)
  return os.date("!*t", timestamp)
end

local function updatedTime(unixSeconds, tzshift)
  local clock = apiClock(unixSeconds, tzshift)
  return string.format("%02d:%02d", clock.hour or 0, clock.min or 0)
end

local function timeLabelAfter(unixSeconds, tzshift, minutes)
  local clock = apiClock(number(unixSeconds, os.time()) + minutes * 60, tzshift)
  return string.format("%02d:%02d", clock.hour or 0, clock.min or 0)
end

local function weatherIcon(skycon)
  local icons = {
    CLEAR_DAY = "sun",
    CLEAR_NIGHT = "moon",
    PARTLY_CLOUDY_DAY = "cloud-sun",
    PARTLY_CLOUDY_NIGHT = "haze-moon",
    CLOUDY = "cloud",
    LIGHT_RAIN = "cloud-rain",
    MODERATE_RAIN = "cloud-rain",
    HEAVY_RAIN = "cloud-storm",
    STORM_RAIN = "cloud-storm",
    LIGHT_SNOW = "snowflake",
    MODERATE_SNOW = "snowflake",
    HEAVY_SNOW = "snowflake",
    STORM_SNOW = "snowflake",
    HAIL = "cloud-storm",
    SLEET = "cloud-snow",
    FOG = "cloud-fog",
    LIGHT_HAZE = "cloud-fog",
    MODERATE_HAZE = "cloud-fog",
    HEAVY_HAZE = "cloud-fog",
    DUST = "wind",
    SAND = "wind",
    WIND = "wind",
  }
  return icons[skycon] or "cloud"
end

local function weatherText(skycon)
  local names = {
    CLEAR_DAY = "weather.condition.clear_day",
    CLEAR_NIGHT = "weather.condition.clear_night",
    PARTLY_CLOUDY_DAY = "weather.condition.partly_cloudy_day",
    PARTLY_CLOUDY_NIGHT = "weather.condition.partly_cloudy_night",
    CLOUDY = "weather.condition.cloudy",
    LIGHT_RAIN = "weather.condition.light_rain",
    MODERATE_RAIN = "weather.condition.moderate_rain",
    HEAVY_RAIN = "weather.condition.heavy_rain",
    STORM_RAIN = "weather.condition.storm_rain",
    LIGHT_SNOW = "weather.condition.light_snow",
    MODERATE_SNOW = "weather.condition.moderate_snow",
    HEAVY_SNOW = "weather.condition.heavy_snow",
    STORM_SNOW = "weather.condition.storm_snow",
    HAIL = "weather.condition.hail",
    SLEET = "weather.condition.sleet",
    FOG = "weather.condition.fog",
    LIGHT_HAZE = "weather.condition.light_haze",
    MODERATE_HAZE = "weather.condition.moderate_haze",
    HEAVY_HAZE = "weather.condition.heavy_haze",
    DUST = "weather.condition.dust",
    SAND = "weather.condition.sand",
    WIND = "weather.condition.wind",
  }
  local key = names[skycon]
  return key ~= nil and noctalia.tr(key) or noctalia.tr("weather.condition.unknown")
end

local function windDirection(degrees)
  local n = number(degrees)
  if n == nil then
    return "--"
  end
  local directions = {
    "north", "north_east", "east", "south_east",
    "south", "south_west", "west", "north_west",
  }
  local index = math.floor(((n % 360) + 22.5) / 45) % 8 + 1
  return noctalia.tr("weather.wind." .. directions[index])
end

local function array(value)
  return type(value) == "table" and value or {}
end

local function findByDatetime(items, datetime)
  for _, item in ipairs(array(items)) do
    if type(item) == "table" and item.datetime == datetime then
      return item
    end
  end
  return nil
end

local function findByDate(items, date)
  for _, item in ipairs(array(items)) do
    if type(item) == "table" and isoDate(item.date or item.datetime) == date then
      return item
    end
  end
  return nil
end

local function downsample(values, limit)
  local source = array(values)
  local count = #source
  if count == 0 then
    return {}
  end

  local target = math.max(1, limit or 24)
  local step = math.max(1, math.ceil(count / target))
  local result = {}
  for start = 1, count, step do
    local peak = 0
    local finish = math.min(count, start + step - 1)
    for index = start, finish do
      peak = math.max(peak, number(source[index], 0) or 0)
    end
    table.insert(result, math.max(0, peak))
  end
  return result
end

local function normalizeGraphValues(values, minimumRange)
  local source = array(values)
  local low = nil
  local high = nil
  local validCount = 0

  for _, item in ipairs(source) do
    local value = number(item, nil)
    if value ~= nil then
      validCount += 1
      low = low == nil and value or math.min(low, value)
      high = high == nil and value or math.max(high, value)
    end
  end

  if low == nil or high == nil then
    return {}
  end
  if high == low then
    local flat = {}
    for _ = 1, validCount do
      table.insert(flat, 0.5)
    end
    return flat
  end

  local displayLow = low
  local displayHigh = high
  local range = high - low
  local minimum = math.max(0, number(minimumRange, 0) or 0)
  if range < minimum then
    local center = (low + high) / 2
    displayLow = center - minimum / 2
    displayHigh = center + minimum / 2
  end

  local displayRange = displayHigh - displayLow
  local result = {}
  for _, item in ipairs(source) do
    local value = number(item, nil)
    if value ~= nil then
      table.insert(result, math.max(0, math.min(1, (value - displayLow) / displayRange)))
    end
  end
  return result
end

local function normalizeSeries(values, limit, startIndex, minimumRange)
  local source = array(values)
  local raw = {}
  local start = math.max(1, startIndex or 1)
  local finish = math.min(#source, start + (limit or 24) - 1)

  for index = start, finish do
    local value = number(source[index] and source[index].value, nil)
    if value ~= nil then
      table.insert(raw, value)
    end
  end

  return normalizeGraphValues(raw, minimumRange)
end

local function adcodeName(result)
  local alert = type(result.alert) == "table" and result.alert or {}
  local adcodes = array(alert.adcodes)
  local last = adcodes[#adcodes]
  if type(last) == "table" and cleanText(last.name) ~= "" then
    return cleanText(last.name)
  end
  return ""
end

local function alertText(item)
  if type(item) == "string" then
    return cleanText(item)
  end
  if type(item) ~= "table" then
    return ""
  end
  local fields = { "description", "title", "content", "text", "message", "level", "type" }
  for _, field in ipairs(fields) do
    local value = item[field]
    if type(value) == "string" and cleanText(value) ~= "" then
      return cleanText(value)
    end
  end
  return ""
end

local function normalizeAlerts(result)
  local alert = type(result.alert) == "table" and result.alert or {}
  local content = array(alert.content)
  local alerts = {}
  for _, item in ipairs(content) do
    local text = alertText(item)
    if text ~= "" then
      local title = ""
      if type(item) == "table" then
        title = cleanText(item.title or item.type or item.level)
      end
      table.insert(alerts, {
        title = title ~= "" and title or noctalia.tr("weather.alert"),
        text = text,
      })
    end
  end
  return alerts
end

local function normalizeLifeIndex(daily, realtime)
  local result = {}
  local dailyLife = type(daily.life_index) == "table" and daily.life_index or {}
  local realtimeLife = type(realtime.life_index) == "table" and realtime.life_index or {}
  local keys = { "ultraviolet", "comfort", "dressing", "carWashing", "coldRisk" }

  for _, key in ipairs(keys) do
    local item = nil
    local dailyValues = dailyLife[key]
    if type(dailyValues) == "table" then
      item = dailyValues[1]
    end
    if type(item) ~= "table" then
      item = realtimeLife[key]
    end
    if type(item) == "table" then
      result[key] = {
        index = cleanText(item.index),
        desc = cleanText(item.desc),
      }
    end
  end
  return result
end

local function normalizeAirQuality(realtime)
  local air = type(realtime.air_quality) == "table" and realtime.air_quality or {}
  local aqi = type(air.aqi) == "table" and air.aqi or {}
  local description = type(air.description) == "table" and air.description or {}
  return {
    aqi = number(aqi.chn),
    aqiText = cleanText(description.chn),
    pm25 = number(air.pm25),
    pm10 = number(air.pm10),
    o3 = number(air.o3),
    so2 = number(air.so2),
    no2 = number(air.no2),
    co = number(air.co),
  }
end

local function normalizeHourly(hourly, serverTime, tzshift)
  local temperatures = array(hourly.temperature)
  local skycons = array(hourly.skycon)
  local precipitation = array(hourly.precipitation)
  local apparent = array(hourly.apparent_temperature)
  local clock = apiClock(serverTime, tzshift)
  local today = string.format("%04d-%02d-%02d", clock.year, clock.month, clock.day)
  local startIndex = 1

  for index, item in ipairs(temperatures) do
    if type(item) == "table" then
      local date = isoDate(item.datetime)
      local hour = tonumber(string.match(tostring(item.datetime or ""), "T(%d%d):"))
      if date == today and hour ~= nil and hour >= (clock.hour or 0) then
        startIndex = index
        break
      end
    end
  end

  if startIndex > #temperatures then
    startIndex = 1
  end

  local rows = {}
  local graphLabels = {}
  for _, offset in ipairs({ 0, 6, 12, 18, 23 }) do
    local graphItem = temperatures[startIndex + offset]
    if type(graphItem) == "table" then
      table.insert(graphLabels, isoTime(graphItem.datetime))
    end
  end

  local finish = math.min(#temperatures, startIndex + 7)
  for index = startIndex, finish do
    local item = temperatures[index]
    if type(item) == "table" then
      local datetime = item.datetime
      local sky = findByDatetime(skycons, datetime) or {}
      local rain = findByDatetime(precipitation, datetime) or {}
      local feels = findByDatetime(apparent, datetime) or {}
      table.insert(rows, {
        datetime = datetime,
        time = isoTime(datetime),
        icon = weatherIcon(sky.value),
        condition = weatherText(sky.value),
        temperature = number(item.value),
        temperatureText = compactTemperatureText(item.value),
        apparentTemperature = number(feels.value),
        rainAmount = number(rain.value),
        rainAmountText = number(rain.value) ~= nil and numberText(rain.value, 1) .. " mm" or "--",
        rainProbability = number(rain.probability),
        rainProbabilityText = probabilityText(rain.probability),
      })
    end
  end

  return rows, normalizeSeries(temperatures, 24, startIndex, 8), graphLabels
end

local function normalizeDaily(daily)
  local temperatures = array(daily.temperature)
  local precipitation = array(daily.precipitation)
  local skycons = array(daily.skycon)
  local airQuality = type(daily.air_quality) == "table" and daily.air_quality or {}
  local dailyAqi = array(airQuality.aqi)
  local rows = {}

  for index = 1, math.min(5, #temperatures) do
    local temperature = temperatures[index]
    if type(temperature) == "table" then
      local date = isoDate(temperature.date)
      local sky = findByDate(skycons, date) or {}
      local rain = findByDate(precipitation, date) or {}
      local aqi = findByDate(dailyAqi, date) or {}
      table.insert(rows, {
        date = date,
        dateText = shortDate(temperature.date, index),
        icon = weatherIcon(sky.value),
        condition = weatherText(sky.value),
        temperatureMin = number(temperature.min),
        temperatureMax = number(temperature.max),
        temperatureText = temperatureText(temperature.min) .. " / " .. temperatureText(temperature.max),
        rainProbability = number(rain.probability),
        rainProbabilityText = probabilityText(rain.probability),
        rainAmount = number(rain.max),
        rainAmountText = number(rain.max) ~= nil and numberText(rain.max, 1) .. " mm" or "--",
        aqi = number(aqi.avg and aqi.avg.chn),
      })
    end
  end
  return rows
end

local function normalizeModel(payload)
  local result = payload.result
  local realtime = result.realtime
  local hourly = type(result.hourly) == "table" and result.hourly or {}
  local daily = type(result.daily) == "table" and result.daily or {}
  local serverTime = number(payload.server_time, os.time())
  local tzshift = number(payload.tzshift, 0)
  local location = array(payload.location)
  local skycon = cleanText(realtime.skycon)
  local wind = type(realtime.wind) == "table" and realtime.wind or {}
  local hourlyRows, hourlyGraph, hourlyGraphLabels = normalizeHourly(hourly, serverTime, tzshift)
  local dailyRows = normalizeDaily(daily)
  local locationName = adcodeName(result)
  local airQuality = normalizeAirQuality(realtime)
  local precipitationGraph = normalizeGraphValues(
    downsample(result.minutely and result.minutely.precipitation_2h, 24),
    0.2
  )

  return {
    status = "ready",
    stale = false,
    error = nil,
    updatedAt = serverTime,
    updatedTime = updatedTime(serverTime, tzshift),
    timezone = cleanText(payload.timezone),
    latitude = number(location[1]),
    longitude = number(location[2]),
    locationName = locationName,
    current = {
      skycon = skycon,
      icon = weatherIcon(skycon),
      condition = weatherText(skycon),
      temperature = number(realtime.temperature),
      temperatureText = temperatureText(realtime.temperature),
      compactTemperatureText = compactTemperatureText(realtime.temperature),
      apparentTemperature = number(realtime.apparent_temperature),
      apparentTemperatureText = temperatureText(realtime.apparent_temperature),
      humidity = number(realtime.humidity),
      humidityText = percentText(realtime.humidity),
      cloudrate = number(realtime.cloudrate),
      cloudrateText = percentText(realtime.cloudrate),
      visibility = number(realtime.visibility),
      visibilityText = number(realtime.visibility) ~= nil and numberText(realtime.visibility, 1) .. " km" or "--",
      pressure = number(realtime.pressure),
      pressureText = pressureText(realtime.pressure),
      dewpoint = number(realtime.dewpoint),
      dewpointText = temperatureText(realtime.dewpoint),
      windSpeed = number(wind.speed),
      windSpeedText = number(wind.speed) ~= nil and numberText(wind.speed, 0) .. " km/h" or "--",
      windDirection = number(wind.direction),
      windDirectionText = windDirection(wind.direction),
    },
    nowcast = {
      description = cleanText(result.forecast_keypoint),
      precipitation = precipitationGraph,
      timeline = {
        timeLabelAfter(serverTime, tzshift, 0),
        timeLabelAfter(serverTime, tzshift, 30),
        timeLabelAfter(serverTime, tzshift, 60),
        timeLabelAfter(serverTime, tzshift, 90),
        timeLabelAfter(serverTime, tzshift, 120),
      },
    },
    hourly = hourlyRows,
    hourlyGraph = hourlyGraph,
    hourlyGraphLabels = hourlyGraphLabels,
    daily = dailyRows,
    airQuality = airQuality,
    lifeIndex = normalizeLifeIndex(daily, realtime),
    astronomy = {
      sunrise = type(array(daily.astro)[1]) == "table" and cleanText(array(daily.astro)[1].sunrise and array(daily.astro)[1].sunrise.time) or "--:--",
      sunset = type(array(daily.astro)[1]) == "table" and cleanText(array(daily.astro)[1].sunset and array(daily.astro)[1].sunset.time) or "--:--",
    },
    alerts = normalizeAlerts(result),
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
  return copy
end

local function publish(model)
  noctalia.state.set("weather", model)
end

local function emptyModel(status, error, stale)
  return {
    status = status,
    stale = stale == true,
    error = error,
    updatedAt = nil,
    updatedTime = "--:--",
    timezone = "",
    latitude = nil,
    longitude = nil,
    locationName = "",
    current = {},
    nowcast = {},
    hourly = {},
    hourlyGraph = {},
    hourlyGraphLabels = {},
    daily = {},
    airQuality = {},
    lifeIndex = {},
    astronomy = {},
    alerts = {},
  }
end

local function refreshIntervalSeconds()
  local minutes = number(cfg("refreshIntervalMinutes"), DEFAULT_REFRESH_MINUTES)
  minutes = math.floor(minutes or DEFAULT_REFRESH_MINUTES)
  minutes = math.max(MIN_REFRESH_MINUTES, math.min(MAX_REFRESH_MINUTES, minutes))
  return minutes * 60
end

local function configValues()
  local latitudeText = cleanText(cfg("latitude"))
  local longitudeText = cleanText(cfg("longitude"))
  if latitudeText == "" or longitudeText == "" then
    return nil, nil, "unconfigured"
  end

  local latitude = tonumber(latitudeText)
  local longitude = tonumber(longitudeText)
  if latitude == nil or longitude == nil then
    return nil, nil, "invalid_coordinates"
  end
  if latitude < -90 or latitude > 90 or longitude < -180 or longitude > 180 then
    return nil, nil, "invalid_coordinates"
  end
  return latitude, longitude, nil
end

local function configFingerprint()
  return cleanText(cfg("latitude")) .. "|" .. cleanText(cfg("longitude"))
end

local function publishUnconfigured(reason)
  publish(emptyModel(reason == "invalid_coordinates" and "error" or "unconfigured", reason, false))
end

local function failureMessage(response, decodeError, apiError)
  if decodeError ~= nil and cleanText(decodeError) ~= "" then
    return noctalia.tr("weather.errors.invalid_response")
  end
  if apiError ~= nil and cleanText(apiError) ~= "" then
    return noctalia.tr("weather.errors.api_error", { status = cleanText(apiError) })
  end
  if type(response) ~= "table" then
    return noctalia.tr("weather.errors.no_response")
  end
  if response.status ~= nil and number(response.status, 0) ~= 0 then
    return noctalia.tr("weather.errors.http_status", { status = tostring(response.status) })
  end
  return noctalia.tr("weather.errors.request_failed")
end

local function requestWeather()
  if requestInFlight then
    return
  end

  local latitude, longitude, configError = configValues()
  if configError ~= nil then
    lastGoodModel = nil
    lastFetchAt = os.time()
    publishUnconfigured(configError)
    return
  end

  requestInFlight = true
  requestSerial += 1
  local serial = requestSerial
  local fingerprint = configFingerprint()
  local url = API_URL .. numberText(longitude, 6) .. "," .. numberText(latitude, 6) .. API_SUFFIX
  local loading = copyWithMeta(lastGoodModel, "loading", lastGoodModel ~= nil, nil)
  if lastGoodModel == nil then
    loading = emptyModel("loading", nil, false)
  end
  publish(loading)

  local accepted = noctalia.http({
    url = url,
    method = "GET",
    headers = { "Accept: application/json" },
  }, function(response)
    requestInFlight = false
    if serial ~= requestSerial then
      return
    end
    if configFingerprint() ~= fingerprint then
      requestWeather()
      return
    end

    local ok = type(response) == "table"
      and response.ok == true
      and number(response.status, 0) >= 200
      and number(response.status, 0) < 300
    if not ok then
      lastFetchAt = os.time()
      local message = failureMessage(response, nil)
      if lastGoodModel ~= nil then
        publish(copyWithMeta(lastGoodModel, "error", true, message))
      else
        publish(emptyModel("error", message, false))
      end
      return
    end

    local payload, decodeError = noctalia.json.decode(tostring(response.body or ""))
    if type(payload) ~= "table" or payload.status ~= "ok" or type(payload.result) ~= "table" or type(payload.result.realtime) ~= "table" then
      lastFetchAt = os.time()
      local apiError = nil
      if type(payload) == "table" and payload.status ~= "ok" then
        apiError = payload.error or payload.message or payload.status
      end
      local parseError = decodeError
      if parseError == nil and apiError == nil then
        parseError = "invalid_response"
      end
      local message = failureMessage(response, parseError, apiError)
      if lastGoodModel ~= nil then
        publish(copyWithMeta(lastGoodModel, "error", true, message))
      else
        publish(emptyModel("error", message, false))
      end
      return
    end

    local model = normalizeModel(payload)
    lastGoodModel = model
    lastFetchAt = os.time()
    publish(model)
  end)

  if not accepted then
    requestInFlight = false
    lastFetchAt = os.time()
    local message = noctalia.tr("weather.errors.request_rejected")
    if lastGoodModel ~= nil then
      publish(copyWithMeta(lastGoodModel, "error", true, message))
    else
      publish(emptyModel("error", message, false))
    end
  end
end

noctalia.setUpdateInterval(UPDATE_INTERVAL_MS)
noctalia.state.watch("weather-command", function(value)
  if type(value) == "table" and value.op == "refresh" then
    requestWeather()
  end
end)

function onConfigChanged()
  local fingerprint = configFingerprint()
  local locationChanged = fingerprint ~= lastConfigFingerprint
  lastConfigFingerprint = fingerprint
  if locationChanged then
    requestWeather()
  end
end

function update()
  local fingerprint = configFingerprint()
  if fingerprint ~= lastConfigFingerprint then
    lastConfigFingerprint = fingerprint
    requestWeather()
    return
  end

  if not requestInFlight and (lastFetchAt == 0 or os.time() - lastFetchAt >= refreshIntervalSeconds()) then
    requestWeather()
  end
end

lastConfigFingerprint = configFingerprint()
requestWeather()
