--!nonstrict
-- Caiyun Weather declarative panel.

local snapshot = noctalia.state.get("weather") or {}
local panelOpen = false

local function tr(key, substitutions)
  return noctalia.tr(key, substitutions)
end

local function text(value, fallback)
  if value == nil then
    return fallback or "--"
  end
  local result = tostring(value)
  return result ~= "" and result or (fallback or "--")
end

local function list(value)
  return type(value) == "table" and value or {}
end

local function clamp(value, low, high)
  local numberValue = tonumber(value) or low
  return math.max(low, math.min(high, numberValue))
end

local function card(children, props)
  local options = {
    gap = 8,
    padding = 12,
    radius = 14,
    fill = "surface_variant/0.45",
    align = "stretch",
  }
  if type(props) == "table" then
    for key, value in pairs(props) do
      options[key] = value
    end
  end
  return ui.column(options, children)
end

local function sectionTitle(title, glyph)
  local children = {}
  if glyph ~= nil then
    table.insert(children, ui.glyph({ name = glyph, size = 16, color = "primary" }))
  end
  table.insert(children, ui.label({
    text = title,
    fontSize = 15,
    fontWeight = "bold",
    color = "on_surface",
    flexGrow = 1,
  }))
  return ui.row({ align = "center", gap = 8 }, children)
end

local function metricCell(title, value, glyph)
  return card({
    ui.row({ align = "center", gap = 6 }, {
      ui.glyph({ name = glyph, size = 15, color = "on_surface_variant" }),
      ui.label({ text = title, fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
    }),
    ui.label({ text = value, fontSize = 15, fontWeight = "bold", color = "on_surface" }),
  }, {
    flexGrow = 1,
    minHeight = 66,
  })
end

local function pollutantRow(label, value)
  return ui.row({ align = "center", gap = 8 }, {
    ui.label({ text = label, width = 52, minWidth = 52, color = "on_surface_variant" }),
    ui.label({ text = value, color = "on_surface", flexGrow = 1 }),
  })
end

local function locationText()
  if text(snapshot.locationName, "") ~= "" then
    return snapshot.locationName
  end
  if type(snapshot.latitude) == "number" and type(snapshot.longitude) == "number" then
    return string.format("%.3f, %.3f", snapshot.latitude, snapshot.longitude)
  end
  return tr("weather.location_unknown")
end

local function header()
  local loading = text(snapshot.status, "unconfigured") == "loading"
  return ui.row({ align = "center", gap = 8 }, {
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = tr("weather.title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = locationText(), fontSize = 11, color = "on_surface_variant" }),
    }),
    ui.button({
      glyph = loading and "loader-2" or "refresh",
      variant = "ghost",
      tooltip = loading and tr("weather.status.loading") or tr("weather.actions.refresh"),
      enabled = not loading,
      onClick = "onRefreshClicked",
    }),
    ui.button({ glyph = "close", variant = "ghost", tooltip = tr("weather.actions.close"), onClick = "onCloseClicked" }),
  })
end

local function statusBanner()
  if text(snapshot.status, "unconfigured") == "loading" then
    return nil
  end
  if snapshot.error ~= nil and text(snapshot.error, "") ~= "" then
    return card({
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
        ui.label({ text = snapshot.error, color = "error", maxLines = 2, flexGrow = 1 }),
      }),
    }, { padding = 10, fill = "error/0.12" })
  end
  if snapshot.stale == true then
    return card({
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "clock-exclamation", size = 15, color = "secondary" }),
        ui.label({ text = tr("weather.status.stale"), color = "on_surface_variant", flexGrow = 1 }),
      }),
    }, { padding = 10, fill = "secondary/0.12" })
  end
  return nil
end

local function setupNotice()
  local invalid = snapshot.status == "error" and snapshot.error == "invalid_coordinates"
  local title = invalid and tr("weather.setup.invalid_title") or tr("weather.setup.title")
  local description = invalid and tr("weather.setup.invalid_description") or tr("weather.setup.description")
  return card({
    ui.glyph({ name = invalid and "map-pin-off" or "map-pin", size = 42, color = "primary" }),
    ui.label({ text = title, fontSize = 17, fontWeight = "bold", color = "on_surface", textAlign = "center" }),
    ui.label({ text = description, color = "on_surface_variant", maxLines = 4, textAlign = "center" }),
    ui.label({ text = tr("weather.setup.path"), color = "on_surface_variant", fontSize = 12, textAlign = "center" }),
  }, {
    padding = 24,
    align = "center",
    fill = "surface_variant/0.55",
  })
end

local function currentSection()
  local current = type(snapshot.current) == "table" and snapshot.current or {}
  return card({
    ui.row({ align = "center", gap = 14 }, {
      ui.glyph({ name = text(current.icon, "cloud"), size = 52, color = "primary" }),
      ui.column({ gap = 3, flexGrow = 1 }, {
        ui.label({ text = text(current.condition, tr("weather.status.unavailable")), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = tr("weather.feels_like", { value = text(current.apparentTemperatureText) }), color = "on_surface_variant" }),
      }),
      ui.label({ text = text(current.temperatureText), fontSize = 34, fontWeight = "bold", color = "on_surface" }),
    }),
    ui.label({
      text = text(snapshot.nowcast and snapshot.nowcast.description, tr("weather.nowcast.none")),
      color = "on_surface_variant",
      maxLines = 3,
    }),
  }, {
    padding = 16,
    fill = "primary/0.10",
    border = "primary/0.28",
    borderWidth = 1,
  })
end

local function currentMetricsSection()
  local current = type(snapshot.current) == "table" and snapshot.current or {}
  return ui.column({ gap = 10, align = "stretch" }, {
    sectionTitle(tr("weather.sections.current"), "activity"),
    ui.row({ gap = 10, align = "stretch" }, {
      metricCell(tr("weather.metrics.humidity"), text(current.humidityText), "droplets"),
      metricCell(tr("weather.metrics.wind"), text(current.windDirectionText) .. " " .. text(current.windSpeedText), "wind"),
    }),
    ui.row({ gap = 10, align = "stretch" }, {
      metricCell(tr("weather.metrics.visibility"), text(current.visibilityText), "eye"),
      metricCell(tr("weather.metrics.pressure"), text(current.pressureText), "gauge"),
    }),
    ui.row({ gap = 10, align = "stretch" }, {
      metricCell(tr("weather.metrics.clouds"), text(current.cloudrateText), "cloud"),
      metricCell(tr("weather.metrics.dewpoint"), text(current.dewpointText), "thermometer"),
    }),
  })
end

local function nowcastSection()
  local nowcast = type(snapshot.nowcast) == "table" and snapshot.nowcast or {}
  local values = list(nowcast.precipitation)
  if #values <= 1 then
    return nil
  end

  local children = {
    sectionTitle(tr("weather.sections.nowcast"), "cloud-rain"),
    ui.label({
      text = tr("weather.nowcast.chart"),
      fontSize = 11,
      color = "on_surface_variant",
    }),
    ui.graph({
      values = values,
      height = 58,
      color = "secondary",
      fillOpacity = 0.22,
      lineWidth = 2,
    }),
  }
  local timeline = list(nowcast.timeline)
  if #timeline > 1 then
    local labels = {}
    for _, value in ipairs(timeline) do
      table.insert(labels, ui.label({
        text = text(value),
        fontSize = 10,
        color = "on_surface_variant",
      }))
    end
    table.insert(children, ui.row({ justify = "space_between" }, labels))
  end
  return ui.column({ gap = 10, align = "stretch" }, children)
end

local function hourlySection()
  local hourly = list(snapshot.hourly)
  if #hourly == 0 then
    return nil
  end

  local cards = {}
  for index = 1, math.min(6, #hourly) do
    local item = hourly[index]
    table.insert(cards, ui.column({
      key = "hour-" .. tostring(index),
      width = 58,
      padding = 8,
      gap = 6,
      radius = 12,
      fill = index == 1 and "primary/0.16" or "surface_variant/0.45",
      align = "center",
    }, {
      ui.label({ text = index == 1 and tr("weather.nowcast.now") or text(item.time), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
      ui.glyph({ name = text(item.icon, "cloud"), size = 20, color = "primary" }),
      ui.label({ text = text(item.temperatureText), fontSize = 14, fontWeight = "bold", color = "on_surface" }),
      ui.label({ text = text(item.rainProbabilityText), fontSize = 10, color = "secondary" }),
    }))
  end

  local children = {
    sectionTitle(tr("weather.sections.hourly"), "clock"),
    ui.row({ gap = 8, align = "stretch" }, cards),
  }
  local graph = list(snapshot.hourlyGraph)
  if #graph > 1 then
    table.insert(children, ui.label({
      text = tr("weather.hourly.chart"),
      fontSize = 11,
      color = "on_surface_variant",
    }))
    table.insert(children, ui.graph({
      values = graph,
      height = 54,
      color = "primary",
      fillOpacity = 0.18,
      lineWidth = 2,
    }))
    local graphLabels = list(snapshot.hourlyGraphLabels)
    if #graphLabels > 1 then
      local labels = {}
      for _, value in ipairs(graphLabels) do
        table.insert(labels, ui.label({
          text = text(value),
          fontSize = 10,
          color = "on_surface_variant",
        }))
      end
      table.insert(children, ui.row({ justify = "space_between" }, labels))
    end
  end
  return ui.column({ gap = 10, align = "stretch" }, children)
end

local function dailyDateSlot(item, index)
  return ui.column({
    width = 52,
    minWidth = 52,
    align = "center",
    justify = "center",
  }, {
    ui.label({
      text = text(item.dateText),
      maxWidth = 52,
      maxLines = 1,
      textAlign = "center",
      fontWeight = index == 1 and "bold" or "normal",
      color = "on_surface",
    }),
  })
end

local function dailySection()
  local daily = list(snapshot.daily)
  if #daily == 0 then
    return nil
  end

  local rows = {}
  for index, item in ipairs(daily) do
    table.insert(rows, ui.row({
      key = "day-" .. tostring(index),
      gap = 10,
      padding = 10,
      radius = 12,
      fill = "surface_variant/0.38",
      align = "center",
    }, {
      dailyDateSlot(item, index),
      ui.glyph({ name = text(item.icon, "cloud"), size = 22, color = "primary" }),
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = text(item.condition), maxLines = 1, color = "on_surface" }),
        ui.label({ text = tr("weather.daily.rain", { value = text(item.rainProbabilityText) }), fontSize = 10, color = "on_surface_variant" }),
      }),
      ui.label({ text = text(item.temperatureText), fontSize = 12, color = "on_surface" }),
    }))
  end

  return ui.column({ gap = 10, align = "stretch" }, {
    sectionTitle(tr("weather.sections.daily"), "calendar"),
    ui.column({ gap = 7, align = "stretch" }, rows),
  })
end

local function aqiColor(aqi)
  local value = tonumber(aqi) or 0
  if value <= 50 then
    return "primary"
  elseif value <= 100 then
    return "secondary"
  elseif value <= 150 then
    return "tertiary"
  end
  return "error"
end

local function airQualitySection()
  local air = type(snapshot.airQuality) == "table" and snapshot.airQuality or {}
  if air.aqi == nil and air.pm25 == nil and air.pm10 == nil then
    return nil
  end

  local color = aqiColor(air.aqi)
  local children = {
    sectionTitle(tr("weather.sections.air_quality"), "wind"),
    ui.row({ gap = 10, align = "stretch" }, {
      card({
        ui.row({ align = "center", gap = 8 }, {
          ui.glyph({ name = "leaf", size = 18, color = color }),
          ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = tr("weather.metrics.aqi"), fontSize = 11, color = "on_surface_variant" }),
            ui.label({ text = text(air.aqi), fontSize = 25, fontWeight = "bold", color = color }),
          }),
          ui.label({ text = text(air.aqiText, "--"), color = color, fontWeight = "bold" }),
        }),
        ui.progress({ progress = clamp((tonumber(air.aqi) or 0) / 300, 0, 1), height = 6, fill = color, track = "surface_variant" }),
      }, { flexGrow = 1, minHeight = 82 }),
      card({
        ui.label({ text = tr("weather.metrics.pollutants"), fontSize = 11, color = "on_surface_variant" }),
        pollutantRow(tr("weather.pollutants.pm25"), text(air.pm25)),
        pollutantRow(tr("weather.pollutants.pm10"), text(air.pm10)),
      }, { flexGrow = 1, minHeight = 82 }),
    }),
  }
  return ui.column({ gap = 10, align = "stretch" }, children)
end

local function lifeIndexSection()
  local life = type(snapshot.lifeIndex) == "table" and snapshot.lifeIndex or {}
  local definitions = {
    { key = "ultraviolet", label = "weather.life.ultraviolet", glyph = "sun" },
    { key = "comfort", label = "weather.life.comfort", glyph = "mood-happy" },
    { key = "dressing", label = "weather.life.dressing", glyph = "shirt" },
    { key = "carWashing", label = "weather.life.car_washing", glyph = "car" },
    { key = "coldRisk", label = "weather.life.cold_risk", glyph = "virus" },
  }
  local cells = {}
  for _, definition in ipairs(definitions) do
    local item = life[definition.key]
    if type(item) == "table" and text(item.desc, "") ~= "" then
      table.insert(cells, card({
        ui.row({ align = "center", gap = 6 }, {
          ui.glyph({ name = definition.glyph, size = 15, color = "secondary" }),
          ui.label({ text = tr(definition.label), fontSize = 11, color = "on_surface_variant", flexGrow = 1 }),
        }),
        ui.label({ text = text(item.desc), fontWeight = "bold", color = "on_surface" }),
      }, { flexGrow = 1, minHeight = 58 }))
    end
  end
  if #cells == 0 then
    return nil
  end

  local rows = {}
  for index = 1, #cells, 2 do
    local row = { cells[index] }
    if cells[index + 1] ~= nil then
      table.insert(row, cells[index + 1])
    end
    table.insert(rows, ui.row({ gap = 10, align = "stretch" }, row))
  end

  return ui.column({ gap = 10, align = "stretch" }, {
    sectionTitle(tr("weather.sections.life"), "heart"),
    ui.column({ gap = 8, align = "stretch" }, rows),
  })
end

local function alertsSection()
  local alerts = list(snapshot.alerts)
  if #alerts == 0 then
    return nil
  end
  local cards = {}
  for index, item in ipairs(alerts) do
    table.insert(cards, card({
      ui.row({ align = "center", gap = 7 }, {
        ui.glyph({ name = "alert-triangle", size = 16, color = "error" }),
        ui.label({ text = text(item.title, tr("weather.alert")), fontWeight = "bold", color = "error", flexGrow = 1 }),
      }),
      ui.label({ text = text(item.text), color = "on_surface", maxLines = 4 }),
    }, { key = "alert-" .. tostring(index), fill = "error/0.12", border = "error/0.35", borderWidth = 1 }))
  end
  return ui.column({ gap = 8, align = "stretch" }, {
    sectionTitle(tr("weather.sections.alerts"), "alert-triangle"),
    ui.column({ gap = 8, align = "stretch" }, cards),
  })
end

local function footerSection()
  local astronomy = type(snapshot.astronomy) == "table" and snapshot.astronomy or {}
  return ui.row({ gap = 10, align = "stretch" }, {
    metricCell(tr("weather.metrics.sunrise"), text(astronomy.sunrise), "sunrise"),
    metricCell(tr("weather.metrics.sunset"), text(astronomy.sunset), "sunset"),
  })
end

local function emptyStateNotice()
  local loading = snapshot.status == "loading"
  return card({
    ui.glyph({ name = loading and "loader-2" or "cloud-off", size = 42, color = loading and "primary" or "error" }),
    ui.label({
      text = loading and tr("weather.status.loading") or tr("weather.errors.title"),
      fontSize = 17,
      fontWeight = "bold",
      color = "on_surface",
      textAlign = "center",
    }),
    ui.label({
      text = loading and tr("weather.status.loading_description") or text(snapshot.error, tr("weather.errors.request_failed")),
      color = "on_surface_variant",
      maxLines = 4,
      textAlign = "center",
    }),
    ui.button({ text = tr("weather.actions.refresh"), variant = "primary", onClick = "onRefreshClicked" }),
  }, {
    padding = 24,
    align = "center",
    fill = loading and "primary/0.10" or "error/0.10",
  })
end

local function render()
  local status = text(snapshot.status, "unconfigured")
  local body = {}

  if status == "unconfigured" or snapshot.error == "invalid_coordinates" then
    table.insert(body, setupNotice())
  elseif type(snapshot.current) ~= "table" or snapshot.current.temperature == nil then
    table.insert(body, emptyStateNotice())
  else
    local banner = statusBanner()
    if banner ~= nil then
      table.insert(body, banner)
    end
    table.insert(body, currentSection())
    local alerts = alertsSection()
    if alerts ~= nil then
      table.insert(body, alerts)
    end
    table.insert(body, currentMetricsSection())
    local nowcast = nowcastSection()
    if nowcast ~= nil then
      table.insert(body, nowcast)
    end
    local hourly = hourlySection()
    if hourly ~= nil then
      table.insert(body, hourly)
    end
    local daily = dailySection()
    if daily ~= nil then
      table.insert(body, daily)
    end
    local air = airQualitySection()
    if air ~= nil then
      table.insert(body, air)
    end
    local life = lifeIndexSection()
    if life ~= nil then
      table.insert(body, life)
    end
    table.insert(body, footerSection())
    table.insert(body, ui.label({
      text = tr("weather.footer.updated", { time = text(snapshot.updatedTime), source = tr("weather.footer.source") }),
      fontSize = 10,
      color = "on_surface_variant",
      textAlign = "center",
    }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    header(),
    ui.scroll({ flexGrow = 1, gap = 16, align = "stretch" }, body),
  }))
end

noctalia.state.watch("weather", function(value)
  snapshot = type(value) == "table" and value or {}
  if panelOpen then
    render()
  end
end)

function onOpen(_context)
  panelOpen = true
  render()
end

function onClose()
  panelOpen = false
end

function onCloseClicked()
  panel.close()
end

function onRefreshClicked()
  noctalia.state.set("weather-command", {
    op = "refresh",
    token = tostring(os.time()),
  })
end

function onIpc(event, _payload)
  if event == "refresh" then
    onRefreshClicked()
  end
end
