--!nonstrict

local Common = require("./common")

local snapshot = {}
local healthy = false
local requestPending = false
local hovering = false

local function attentionColor()
  if not healthy then
    return "outline"
  end
  local attention = type(snapshot.attention) == "table" and snapshot.attention or {}
  if attention.level == "critical" then
    return "error"
  elseif attention.level == "warn" then
    return "tertiary"
  end
  return "primary"
end

local function tooltip()
  if not healthy then
    return "Headroom — host not answering"
  end
  local providers = Common.focusProviders(snapshot, false)
  if #providers == 0 then
    return "Headroom — no quota sources enabled"
  end
  local lines = { "Headroom" }
  for _, provider in ipairs(providers) do
    table.insert(lines, `{Common.providerName(provider)} — {Common.headroomText(provider)} left`)
  end
  table.insert(lines, "")
  table.insert(lines, "Click for quota details")
  return table.concat(lines, "\n")
end

local function providerNode(provider, vertical)
  local tint = Common.providerTint(provider)
  local children = {
    ui.glyph({ name = "chart-donut", size = 14, color = tint }),
  }
  if not vertical then
    table.insert(children, ui.label({
      text = Common.headroomText(provider),
      color = tint,
      fontWeight = "semibold",
    }))
  end
  return (vertical and ui.column or ui.row)({ gap = 3, align = "center" }, children)
end

local function render()
  local vertical = barWidget.isVertical()
  local providers = Common.focusProviders(snapshot, false)
  local children = {}
  for _, provider in ipairs(providers) do
    table.insert(children, providerNode(provider, vertical))
  end
  if #children == 0 then
    table.insert(children, ui.glyph({ name = "chart-donut", size = 15, color = "on_surface_variant" }))
  end
  table.insert(children, ui.glyph({ name = "point-filled", size = 8, color = attentionColor() }))
  local container = vertical and ui.column or ui.row
  barWidget.render(container({ gap = vertical and 2 or 6, align = "center" }, children))
  barWidget.setTooltip(tooltip())
end

local function poll()
  if requestPending then
    return
  end
  requestPending = true
  Common.fetchUsage(noctalia.getConfig("host_url"), function(document, err)
    requestPending = false
    if document then
      snapshot = document
      healthy = true
      noctalia.state.set("headroom.snapshot", document)
      noctalia.state.set("headroom.healthy", true)
    else
      healthy = false
      noctalia.state.set("headroom.healthy", false)
      noctalia.log("Headroom widget poll failed: " .. tostring(err))
    end
    render()
  end)
end

function update()
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 30
  noctalia.setUpdateInterval((hovering and 5 or math.max(5, seconds)) * 1000)
  poll()
  render()
end

function onHover(entered)
  hovering = entered == true
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 30
  noctalia.setUpdateInterval((hovering and 5 or math.max(5, seconds)) * 1000)
  if hovering then
    poll()
  end
end

function onClick()
  noctalia.togglePanel("centaur-labs/headroom:details")
end

function onRightClick()
  noctalia.openSettings()
end

render()
