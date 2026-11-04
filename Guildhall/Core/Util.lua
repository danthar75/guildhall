local ADDON, ns = ...

local Util = {}
ns.Util = Util

function Util.Trim(s)
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Hash: a deterministic string hash in [0, 2147483647). Plain arithmetic, no bit library,
-- so every client (Mainline or Classic) computes the same value.
function Util.Hash(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
  return h
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

-- True only for exactly one whole item link: a colour code (|cAARRGGBB or |cnNAME:), one
-- |Hitem:...|h[Name]|h|r and nothing else. The name may hold quality-tier atlases
-- (|A:...|a) but no other escape. Anything else must be shown through Util.Escape.
function Util.IsItemLink(s)
  if type(s) ~= "string" then return false end
  local rest = s:match("^|c%x%x%x%x%x%x%x%x(.*)$") or s:match("^|cn[%w_]+:(.*)$")
  if not rest then return false end
  local name = rest:match("^|Hitem:[%-%d:]+|h%[(.-)%]|h|r$")
  if not name then return false end
  name = name:gsub("|A:[%w_%-%.:]+|a", "")
  return name ~= "" and not name:find("[|%]]")
end

-- Text with every "|" doubled, so WoW renders it literally (no colours, textures or links).
function Util.Escape(s)
  if s == nil then return "" end
  return (tostring(s):gsub("|", "||"))
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
