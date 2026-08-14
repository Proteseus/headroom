--!nonstrict

local Common = require("./common")

local snapshot = noctalia.state.get("headroom.snapshot") or {}
local healthy = noctalia.state.get("headroom.healthy") == true

local function statusText()
  if not healthy then
    return "Host not answering"
  end
  local attention = type(snapshot.attention) == "table" and snapshot.attention or {}
  if attention.level == "warn" or attention.level == "critical" then
    return attention.summary or "Needs attention"
  end
  local count = #Common.focusProviders(snapshot, true)
  if count == 0 then
    return "No active sources"
  end
  return count == 1 and "All clear · 1 source" or `All clear · {count} sources`
end

local function statusColor()
  if not healthy then
    return "error"
  end
  local attention = type(snapshot.attention) == "table" and snapshot.attention or {}
  if attention.level == "critical" then
    return "error"
  elseif attention.level == "warn" then
    return "tertiary"
  end
  return "primary"
end

local function providerCard(provider)
  local tint = Common.providerTint(provider)
  local used = Common.primaryPercent(provider)
  local progress = used == nil and 0 or Common.clamp(1 - used / 100, 0, 1)
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "chart-donut", size = 18, color = tint }),
      ui.label({
        text = Common.providerName(provider),
        color = "on_surface",
        fontWeight = "semibold",
        flexGrow = 1,
      }),
      ui.label({ text = Common.headroomText(provider) .. " left", color = tint, fontWeight = "bold" }),
    }),
    ui.progress({ progress = progress, fill = tint, height = 6, radius = 3 }),
  }

  local layers = Common.poolLayers(provider)
  if #layers > 1 then
    local parts = {}
    for _, layer in ipairs(layers) do
      local left = Common.round(100 - Common.clamp(layer.percent, 0, 100))
      table.insert(parts, `{layer.name} {left}%`)
    end
    table.insert(rows, ui.label({
      text = table.concat(parts, " · "),
      color = "on_surface_variant",
      fontSize = 12,
    }))
  end

  return ui.column({ gap = 7, paddingH = 10, paddingV = 9, fill = "surface_variant", radius = 10 }, rows)
end

local function dailyBurn()
  local byDay = type(snapshot.byDay) == "table" and snapshot.byDay or {}
  if #byDay == 0 then
    return nil
  end
  local values = {}
  local maxBurn = 0
  local first = math.max(1, #byDay - 6)
  for index = first, #byDay do
    local total = tonumber(byDay[index].total) or 0
    maxBurn = math.max(maxBurn, total)
    table.insert(values, { label = tostring(byDay[index].date or index), total = total })
  end

  local rows = {
    ui.row({ align = "center" }, {
      ui.label({ text = "Daily burn", fontWeight = "semibold", flexGrow = 1 }),
      ui.label({ text = `{#byDay} days`, color = "on_surface_variant", fontSize = 12 }),
    }),
  }
  for _, day in ipairs(values) do
    table.insert(rows, ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = day.label, color = "on_surface_variant", fontSize = 11, minWidth = 74 }),
      ui.progress({
        progress = maxBurn > 0 and day.total / maxBurn or 0,
        fill = "primary",
        height = 5,
        radius = 3,
        flexGrow = 1,
      }),
      ui.label({ text = tostring(Common.round(day.total)), color = "on_surface_variant", fontSize = 11 }),
    }))
  end
  return ui.column({ gap = 6 }, rows)
end

local function render()
  local rows = {
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Headroom", fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.glyph({ name = "point-filled", size = 9, color = statusColor() }),
      ui.label({ text = statusText(), color = "on_surface_variant", fontSize = 12 }),
      ui.button({ glyph = "close", variant = "ghost", onClick = "onCloseClicked" }),
    }),
  }

  local providers = Common.focusProviders(snapshot, true)
  if #providers == 0 then
    table.insert(rows, ui.box({ paddingH = 16, paddingV = 24, fill = "surface_variant", radius = 10 }, {
      ui.label({
        text = healthy and "Waiting for quota readings" or "Check the Headroom host and try again",
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
  else
    for _, provider in ipairs(providers) do
      table.insert(rows, providerCard(provider))
    end
  end

  local burn = dailyBurn()
  if burn then
    table.insert(rows, burn)
  end
  table.insert(rows, ui.label({
    text = Common.updatedText(snapshot.updated),
    color = "on_surface_variant",
    fontSize = 11,
  }))
  panel.render(ui.column({ gap = 12, flexGrow = 1 }, rows))
end

function onCloseClicked()
  panel.close()
end

function onOpen()
  snapshot = noctalia.state.get("headroom.snapshot") or snapshot
  healthy = noctalia.state.get("headroom.healthy") == true
  render()
end

noctalia.state.watch("headroom.snapshot", function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.state.watch("headroom.healthy", function(value)
  healthy = value == true
  render()
end)

render()
