local ADDON, ns = ...

-- Local-only audit log of every accepted/rejected/ignored change this client sees.
-- Never synced. `store` is an array living in SavedVariables and is only mutated in place.
local Log = {}
Log.__index = Log
ns.Log = Log

local MAX_AGE = 2592000 -- 30 days
local MAX_ENTRIES = 5000
local TIME_FMT = "%Y-%m-%d %H:%M:%S"

local function defaultFmt(t)
  local f = date or os.date -- WoW provides global `date`
  return f(TIME_FMT, t)
end

function Log.new(store, now, fmtTime)
  return setmetatable({
    store = store,
    now = now or os.time,
    fmtTime = fmtTime or defaultFmt,
  }, Log)
end

function Log:Add(entry)
  if entry.t == nil then entry.t = self.now() end
  self.store[#self.store + 1] = entry
  self:Prune()
end

-- Drops entries older than MAX_AGE, then the oldest beyond MAX_ENTRIES. Single pass each (no O(n^2) removes).
function Log:Prune()
  local store = self.store
  local n = #store
  local cutoff = self.now() - MAX_AGE
  local w = 0
  for r = 1, n do
    local e = store[r]
    local t = type(e) == "table" and tonumber(e.t) or nil
    if not t or t >= cutoff then
      w = w + 1
      if w ~= r then store[w] = e end
    end
  end
  for i = w + 1, n do store[i] = nil end
  if w > MAX_ENTRIES then
    local drop = w - MAX_ENTRIES
    for i = 1, MAX_ENTRIES do store[i] = store[i + drop] end
    for i = MAX_ENTRIES + 1, w do store[i] = nil end
  end
end

function Log:Query(filter)
  filter = filter or {}
  local out = {}
  local store = self.store
  for i = #store, 1, -1 do
    local e = store[i]
    if (filter.id == nil or e.id == filter.id)
      and (filter.author == nil or e.author == filter.author)
      and (filter.char == nil or e.authorChar == filter.char or e.relayer == filter.char) then
      out[#out + 1] = e
    end
  end
  return out
end

local function str(v)
  if v == nil then return "" end
  return tostring(v)
end

local function fields(d)
  if type(d) ~= "table" then return str(d) end
  -- A plain list (profile chars) reads better as names than as 1=... 2=...
  local n = #d
  if n > 0 then
    local count = 0
    for _ in pairs(d) do count = count + 1 end
    if count == n then
      local names = {}
      for i = 1, n do names[i] = type(d[i]) == "table" and "{...}" or tostring(d[i]) end
      return table.concat(names, ", ")
    end
  end
  local keys = {}
  for k in pairs(d) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta == tb and (ta == "number" or ta == "string") then return a < b end
    if ta ~= tb then return ta < tb end
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = d[k]
    parts[#parts + 1] = tostring(k) .. "=" .. (type(v) == "table" and "{...}" or tostring(v))
  end
  return table.concat(parts, " ")
end

function Log:Export(entries)
  local lines = {}
  for _, e in ipairs(entries or {}) do
    local idv = str(e.id)
    if e.v ~= nil then idv = idv .. " v" .. tostring(e.v) end
    local who = str(e.author)
    if e.authorChar ~= nil then who = who .. "/" .. tostring(e.authorChar) end
    if e.relayer ~= nil then who = who .. " via " .. tostring(e.relayer) end
    local ts = type(e.t) == "number" and self.fmtTime(e.t) or str(e.t)
    lines[#lines + 1] = table.concat({ ts, str(e.action), str(e.result), idv, who, str(e.reason) }, " | ")
    if e.before ~= nil then lines[#lines + 1] = "  before: " .. fields(e.before) end
    if e.after ~= nil then lines[#lines + 1] = "  after: " .. fields(e.after) end
  end
  return table.concat(lines, "\n")
end
