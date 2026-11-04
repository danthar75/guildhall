local ADDON, ns = ...

local Util = {}
ns.Util = Util

function Util.Trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Util.DeepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[Util.DeepCopy(k)] = Util.DeepCopy(v) end
  return out
end

-- "Name-Realm". A name that already has a realm is returned unchanged.
function Util.FullName(name, realm, defaultRealm)
  if name:find("-", 1, true) then return name end
  local r = realm
  if r == nil or r == "" then r = defaultRealm end
  if r == nil or r == "" then return name end
  r = r:gsub("[ ']", "")
  return name .. "-" .. r
end

-- WoW Forever is realmless: names are stored as "Name-Realm" for reliable matching,
-- but shown to players without the realm part.
function Util.DisplayName(name)
  if type(name) ~= "string" then return name end
  return name:match("^([^%-]+)%-") or name
end

function Util.IsItemLink(s)
  return type(s) == "string" and s:find("|Hitem:", 1, true) ~= nil
end

function Util.ItemIdFromLink(s)
  if type(s) ~= "string" then return nil end
  local id = s:match("|Hitem:(%d+)")
  return id and tonumber(id) or nil
end

function Util.ItemName(linkOrName)
  local s = tostring(linkOrName)
  local name = s:match("|h%[(.-)%]|h")
  if name then return name end
  return Util.Trim(s)
end

function Util.Fill(template, vars)
  return (template:gsub("{([%w_]+)}", function(k)
    local v = vars[k]
    if v == nil then return nil end
    return tostring(v)
  end))
end
