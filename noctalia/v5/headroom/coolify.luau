--!nonstrict

local Common = require("./common")

local snapshot = {}
local healthy = false
local requestPending = false
local hovering = false
local expanded = false

local function coolifyData()
  return type(snapshot.coolify) == "table" and snapshot.coolify or {}
end

local function deployments()
  local coolify = coolifyData()
  local active = type(coolify.active) == "table" and coolify.active or {}
  local failures = type(coolify.failures) == "table" and coolify.failures or {}
  local result = {}
  for _, deployment in ipairs(active) do
    table.insert(result, deployment)
  end
  for _, deployment in ipairs(failures) do
    table.insert(result, deployment)
  end
  return result, active, failures
end

local function counts()
  local coolify = coolifyData()
  local _, active, failures = deployments()
  local activeCount = tonumber(coolify.active_count) or #active
  local failureCount = tonumber(coolify.failure_count) or #failures
  local runningCount = 0
  local queuedCount = 0
  for _, deployment in ipairs(active) do
    if deployment.status == "in_progress" then
      runningCount += 1
    elseif deployment.status == "queued" then
      queuedCount += 1
    end
  end
  return activeCount, failureCount, runningCount, queuedCount
end

local function markerColor(deployment)
  if deployment.status == "failed" then
    return "error"
  elseif deployment.status == "queued" then
    return "tertiary"
  end
  return "primary"
end

local function stateColor()
  local coolify = coolifyData()
  local _, failureCount, runningCount, queuedCount = counts()
  if not healthy or coolify.auth_required or coolify.ok == false then
    return "error"
  elseif failureCount > 0 then
    return "error"
  elseif runningCount > 0 then
    return "primary"
  elseif queuedCount > 0 then
    return "tertiary"
  end
  return "on_surface_variant"
end

local function compactName(value)
  local name = tostring(value or "Application")
  if #name > 18 then
    return name:sub(1, 17) .. "…"
  end
  return name
end

local function emptyText()
  local coolify = coolifyData()
  if not healthy then
    return "Host unavailable"
  elseif coolify.auth_required then
    return "Coolify token rejected"
  elseif not coolify.configured then
    return "Coolify not connected"
  elseif coolify.stale then
    return "Cached · refresh failed"
  elseif coolify.ok == false then
    return coolify.error or "Coolify unavailable"
  end
  return "No active deployments"
end

local function tooltip()
  local coolify = coolifyData()
  if not healthy then
    return "Coolify — Headroom host not answering"
  elseif coolify.auth_required then
    return "Coolify — API token rejected or missing"
  elseif not coolify.configured then
    return "Coolify — not connected"
  end

  local all = deployments()
  local lines = { coolify.stale and "Coolify — cached; refresh failed" or "Coolify" }
  for index = 1, math.min(3, #all) do
    local deployment = all[index]
    local state = deployment.status_label or deployment.status or "Unknown"
    local age = deployment.ago and " · " .. tostring(deployment.ago) or ""
    table.insert(lines, `{deployment.application_name or "Application"} — {state}{age}`)
  end
  if #all == 0 then
    table.insert(lines, coolify.error or "No active deployments")
  elseif not barWidget.isVertical() then
    table.insert(lines, "")
    table.insert(lines, expanded and "Click to collapse" or "Click to expand")
  end
  return table.concat(lines, "\n")
end

local function compactNodes(all)
  local nodes = {}
  for index = 1, math.min(4, #all) do
    table.insert(nodes, ui.glyph({
      name = "point-filled",
      size = 10,
      color = markerColor(all[index]),
    }))
  end
  if #all == 0 then
    table.insert(nodes, ui.glyph({ name = "point-filled", size = 9, color = stateColor() }))
  elseif #all > 4 then
    table.insert(nodes, ui.label({
      text = "+" .. tostring(#all - 4),
      color = "on_surface_variant",
      fontSize = 11,
      fontWeight = "semibold",
    }))
  end
  return nodes
end

local function detailNodes(all)
  local nodes = {}
  for index = 1, math.min(3, #all) do
    local deployment = all[index]
    table.insert(nodes, ui.row({ gap = 4, align = "center" }, {
      ui.glyph({ name = "point-filled", size = 10, color = markerColor(deployment) }),
      ui.label({
        text = compactName(deployment.application_name),
        color = "on_surface",
        fontWeight = "semibold",
      }),
      ui.label({
        text = tostring(deployment.status_label or deployment.status or "Unknown"),
        color = markerColor(deployment),
        fontSize = 11,
      }),
      ui.label({
        text = tostring(deployment.ago or ""),
        color = "on_surface_variant",
        fontSize = 11,
      }),
    }))
  end
  if #all > 3 then
    table.insert(nodes, ui.label({
      text = "+" .. tostring(#all - 3),
      color = "on_surface_variant",
      fontSize = 11,
      fontWeight = "semibold",
    }))
  elseif #all == 0 then
    table.insert(nodes, ui.label({ text = emptyText(), color = "on_surface_variant", fontSize = 12 }))
  end
  return nodes
end

local function render()
  local all = deployments()
  local vertical = barWidget.isVertical()
  if vertical then
    expanded = false
  end
  local children = {
    ui.glyph({ name = "cloud-upload", size = 16, color = stateColor() }),
  }
  local states = expanded and detailNodes(all) or compactNodes(all)
  for _, node in ipairs(states) do
    table.insert(children, node)
  end
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
    else
      healthy = false
      noctalia.log("Coolify widget poll failed: " .. tostring(err))
    end
    render()
  end)
end

function update()
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 15
  noctalia.setUpdateInterval((hovering and 5 or math.max(5, seconds)) * 1000)
  poll()
  render()
end

function onHover(entered)
  hovering = entered == true
  local seconds = tonumber(noctalia.getConfig("poll_interval")) or 15
  noctalia.setUpdateInterval((hovering and 5 or math.max(5, seconds)) * 1000)
  if hovering then
    poll()
  end
end

function onClick()
  if not barWidget.isVertical() then
    expanded = not expanded
  end
  poll()
  render()
end

function onRightClick()
  noctalia.openSettings()
end

render()
