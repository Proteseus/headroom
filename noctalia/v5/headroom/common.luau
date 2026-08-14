--!nonstrict

local Common = {}

function Common.normalizedHostUrl(value)
  local url = noctalia.string.trim(tostring(value or "http://localhost:8737"))
  while #url > 0 and url:sub(-1) == "/" do
    url = url:sub(1, -2)
  end
  if url == "" then
    return "http://localhost:8737"
  end
  return url
end

function Common.fetchUsage(hostUrl, callback)
  return noctalia.http({
    method = "GET",
    url = Common.normalizedHostUrl(hostUrl) .. "/usage",
    headers = { "Accept: application/json" },
  }, function(response)
    if not response.ok or response.status < 200 or response.status >= 300 then
      callback(nil, `HTTP {response.status}`)
      return
    end
    local document, err = noctalia.json.decode(response.body)
    if type(document) ~= "table" then
      callback(nil, err or "invalid JSON response")
      return
    end
    callback(document, nil)
  end)
end

function Common.clamp(value, low, high)
  return math.max(low, math.min(high, tonumber(value) or low))
end

function Common.round(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

function Common.providerTint(provider)
  local accent = provider and provider.accent
  if type(accent) == "string" and accent:match("^#?%x%x%x%x%x%x$") then
    return accent:sub(1, 1) == "#" and accent or "#" .. accent
  end
  local providerId = provider and provider.id or ""
  if providerId == "claude" then
    return "#D97757"
  elseif providerId == "codex" then
    return "#10A37F"
  elseif providerId == "cursor" then
    return "#789BC8"
  end
  return "primary"
end

function Common.poolLayers(provider)
  local pools = type(provider) == "table" and provider.pools or nil
  if type(pools) ~= "table" then
    return {}
  end

  local ids = {}
  for id, pool in pairs(pools) do
    if type(pool) == "table" and pool.ring ~= false and pool.pct ~= nil then
      table.insert(ids, id)
    end
  end

  table.sort(ids, function(a, b)
    if provider.id == "opencode" then
      local order = { monthly = 0, weekly = 1, ["5h"] = 2 }
      local aOrder = order[a] or 999
      local bOrder = order[b] or 999
      if aOrder ~= bOrder then
        return aOrder < bOrder
      end
    end
    local aRank = tonumber(pools[a].rank) or 999
    local bRank = tonumber(pools[b].rank) or 999
    if aRank ~= bRank then
      return aRank < bRank
    end
    return tostring(a) < tostring(b)
  end)

  local layers = {}
  local limit = provider.id == "opencode" and 3 or 2
  for _, id in ipairs(ids) do
    local pool = pools[id]
    table.insert(layers, {
      id = id,
      name = pool.title or id,
      percent = tonumber(pool.pct),
      pacePercent = tonumber(pool.pacePct),
    })
    if #layers >= limit then
      break
    end
  end
  return layers
end

function Common.primaryPercent(provider)
  local pools = type(provider) == "table" and provider.pools or {}
  local headline = provider and provider.headline
  local headlinePool = headline and pools[headline]
  if type(headlinePool) == "table" and headlinePool.pct ~= nil then
    return tonumber(headlinePool.pct)
  end
  local layers = Common.poolLayers(provider)
  return layers[1] and layers[1].percent or nil
end

function Common.focusProviders(snapshot, requireReading)
  local providers = type(snapshot) == "table" and snapshot.providers or nil
  if type(providers) ~= "table" then
    return {}
  end

  local enabled = {}
  local byId = {}
  for _, provider in ipairs(providers) do
    if type(provider) == "table" and provider.enabled ~= false then
      if not requireReading or #Common.poolLayers(provider) > 0 then
        table.insert(enabled, provider)
        if provider.id then
          byId[provider.id] = provider
        end
      end
    end
  end

  local focused = {}
  local focus = snapshot.focus
  if type(focus) == "table" then
    for _, id in ipairs(focus) do
      if byId[id] then
        table.insert(focused, byId[id])
      end
    end
  end
  local result = #focused > 0 and focused or enabled
  while #result > 3 do
    table.remove(result)
  end
  return result
end

function Common.providerName(provider)
  return tostring(provider.title or provider.id or "Provider")
end

function Common.headroomText(provider)
  local used = Common.primaryPercent(provider)
  if used == nil then
    return "--"
  end
  return `{Common.round(100 - Common.clamp(used, 0, 100))}%`
end

function Common.updatedText(value)
  if type(value) ~= "string" or value == "" then
    return "Waiting for first update"
  end
  return "Updated " .. value
end

return Common
