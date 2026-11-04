local ADDON, ns = ...

-- Ledger: turns observations into Contributions (via the derivers modules register with
-- Activity) and answers every board's question with one windowed Query. Credit goes to the
-- profile: a bank character counts for a profile only if that profile's record lists it,
-- otherwise it counts toward the guild total alone. Netted types (bank gold, bank items) are
-- netted here, per window, never at storage.
--
-- Contribution: { type, profile?, char?, value (signed int), at, item?, tab?, ref, counted,
--   why?, net? }. why: "unpaired", "waiting for confirmation", "rank excluded",
--   "tab not counted", "not linked".
ns.Ledger = ns.Ledger or {}
local Ledger = ns.Ledger
local L = {}
L.__index = L

-- ctx: { observations, profile, roster, now, activity }. Callers may add fields (derivers
-- receive ctx as their second argument).
function Ledger.new(ctx)
  return setmetatable({ ctx = ctx, cache = nil, cacheChanges = nil, dirty = true }, L)
end

function L:Invalidate() self.dirty = true end

local function kinds()
  local out = {}
  for k in pairs((ns.Observations and ns.Observations.KINDS) or {}) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function L:Contributions()
  local obs = self.ctx.observations
  local changes = obs.changes
  if self.cache and not self.dirty and self.cacheChanges == changes then return self.cache end
  local activity = self.ctx.activity or ns.Activity
  local out, failed = {}, false
  for _, kind in ipairs(kinds()) do
    local fn = activity.Deriver(kind)
    if fn then
      local ok, list = pcall(fn, obs:List(kind), self.ctx)
      if ok and type(list) == "table" then
        for _, c in ipairs(list) do out[#out + 1] = c end
      elseif not ok then
        failed = true
        if ns.OnError then ns.OnError("Leaderboard deriver '" .. kind .. "': " .. tostring(list)) end
      end
    end
  end
  if failed then
    -- Don't cache a partial result: the next call retries the failed deriver.
    self.cache, self.dirty = nil, true
    return out
  end
  self.cache, self.cacheChanges, self.dirty = out, changes, false
  return out
end

local function toSet(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

-- The profile credited for a bank character, or nil (counts for the guild only).
function L:_resolve(char)
  local profile = self.ctx.profile
  local owner = profile:OwnerOf(char)
  if not owner then return nil end
  for _, c in ipairs(profile:CharsOf(owner)) do
    if c == char then return owner end
  end
  return nil
end

-- q: { from (incl), to (excl), types (set), item (fn), excludeRanks (set), tabs (set),
--   includeUncounted }. An item filter only drops contributions that carry a
-- non-matching item; contributions with no item are governed by `types`.
function L:Query(q)
  q = q or {}
  local ctx = self.ctx
  local excludeRanks = q.excludeRanks or toSet(ctx.roster:ConfigList("bankexclude"))
  local tabs = q.tabs or toSet(ctx.roster:ConfigList("donations"))
  local anyTab = next(tabs) ~= nil

  local result = { byProfile = {}, guild = {}, goldKept = 0 }
  if q.includeUncounted then result.rows = {} end
  local nets = {}

  local function addTo(tbl, key, v) tbl[key] = (tbl[key] or 0) + v end

  for _, c in ipairs(self:Contributions()) do
    local inWindow = (q.from == nil or c.at >= q.from) and (q.to == nil or c.at < q.to)
    local typeOk = q.types == nil or q.types[c.type]
    local itemOk = q.item == nil or c.item == nil or q.item(c.item)
    if inWindow and typeOk and itemOk then
      local counted, why, profile = c.counted, c.why, c.profile
      if counted and c.char ~= nil then
        profile = self:_resolve(c.char)
        local rank = ctx.roster:RankIndex(c.char)
        if rank ~= nil and excludeRanks[rank] then
          counted, why = false, "rank excluded"
        end
      end
      if counted and c.tab ~= nil and anyTab and not tabs[c.tab] then
        counted, why = false, "tab not counted"
      end
      if result.rows then
        local row = {}
        for k, v in pairs(c) do row[k] = v end
        row.counted, row.why = counted, counted and nil or why
        if profile then row.profile = profile end
        result.rows[#result.rows + 1] = row
      end
      if counted then
        if c.net then
          local owner = profile and ("p:" .. profile) or ("c:" .. tostring(c.char))
          local key = c.type .. "|" .. owner .. "|" .. tostring(c.item)
          local n = nets[key]
          if not n then
            n = { type = c.type, profile = profile, sum = 0 }
            nets[key] = n
          end
          n.sum = n.sum + c.value
        else
          addTo(result.guild, c.type, c.value)
          if profile then
            result.byProfile[profile] = result.byProfile[profile] or {}
            addTo(result.byProfile[profile], c.type, c.value)
          end
          if c.type == "exchange.gold.earned" and c.value > 0 then
            result.goldKept = result.goldKept + c.value
          end
        end
      end
    end
  end

  for _, n in pairs(nets) do
    local v = math.max(n.sum, 0)
    addTo(result.guild, n.type, v)
    if n.profile then
      result.byProfile[n.profile] = result.byProfile[n.profile] or {}
      addTo(result.byProfile[n.profile], n.type, v)
    end
    if n.type == "bank.gold" then result.goldKept = result.goldKept + v end
  end
  return result
end
