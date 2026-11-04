local ADDON, ns = ...

-- Observations: the replicated set of raw first-hand events (trades, COD, manual deals,
-- witnesses, bank readings) the Leaderboard derives its scores from. Day-bucketed Sync keeps
-- login cheap for large sets. Records live 400 days. Only officers ever see the log detail.
ns.Observations = ns.Observations or {}
local Obs = ns.Observations

local SET_NAME = "core.observations"
local RETENTION = 34560000   -- 400 days
local DAY = 86400
local MAX_STR, MAX_ITEMS = 64, 6

Obs.KINDS = { trade = true, cod = true, manual = true, witness = true, bank = true }

function Obs.AddKind(kind)
  if type(kind) == "string" and kind ~= "" then Obs.KINDS[kind] = true end
end

local function isInt(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge and x == math.floor(x)
end

function Obs.Validate(d)
  if type(d) ~= "table" then return false, "not a table" end
  if type(d.kind) ~= "string" or not Obs.KINDS[d.kind] then return false, "unknown kind" end
  if not isInt(d.at) then return false, "bad at" end
  for k, v in pairs(d) do
    local tv = type(v)
    if type(k) ~= "string" then return false, "bad key" end
    if tv == "string" then
      if #v > MAX_STR then return false, "string too long: " .. k end
    elseif tv == "number" then
      if not isInt(v) then return false, "bad number: " .. k end
    elseif tv == "boolean" then
      -- allowed flag
    elseif tv == "table" and k == "items" then
      if #v > MAX_ITEMS then return false, "too many items" end
      local count = 0
      for _ in pairs(v) do count = count + 1 end
      if count ~= #v then return false, "bad items" end
      for _, it in ipairs(v) do
        if type(it) ~= "table" or not isInt(it.id) or not isInt(it.n) then return false, "bad item" end
        for ik in pairs(it) do
          if ik ~= "id" and ik ~= "n" then return false, "bad item" end
        end
      end
    else
      return false, "bad field: " .. k
    end
  end
  return true
end

local O = {}
O.__index = O

local function copy(t) return t ~= nil and ns.Util.DeepCopy(t) or nil end

-- Tolerates tombstones and malformed records (no payload).
local function bucket(rec)
  local at = type(rec.d) == "table" and rec.d.at or rec.t
  if type(at) ~= "number" then at = rec.t end
  if type(at) ~= "number" then at = 0 end
  return string.format("%d", math.floor(at / DAY))
end

function Obs.New(ctx)
  local self = setmetatable({}, O)
  self.ctx = ctx
  self.profile, self.log, self.now = ctx.profile, ctx.log, ctx.now
  self.playerChar = ctx.playerChar
  self.store = ctx.db
  self.counter = nil
  self.set = ns.ReplicatedSet.new(SET_NAME, self.store, {
    now = ctx.now, maxFuture = DAY,
    onChange = function() if ns.Events then ns.Events:Fire("ObservationsChanged") end end,
  })

  local function logApplied(rec, status, old, sender, reason)
    local e = { t = self.now(), set = SET_NAME, id = rec.id, v = rec.v, author = rec.by,
      authorChar = rec.char, relayer = sender }
    if status == "accepted" then
      e.result, e.reason = "accepted", reason
      e.action = "observe"
      if type(rec.d) == "table" then
        e.after = { kind = rec.d.kind }
        e.detail = copy(rec.d)
      end
    elseif status == "stale" then
      e.action, e.result = "ignored", "stale"
    else
      e.action, e.result, e.reason = "invalid", "rejected", reason or status
    end
    self.log:Add(e)
  end

  self.sync = ns.Sync.new({
    comm = ctx.comm, set = self.set, module = SET_NAME,
    after = ctx.after, random = ctx.random, playerName = ctx.playerChar,
    bucket = bucket,
    validate = function(rec)
      if type(rec.char) == "string" then
        local owner = self.profile:OwnerOf(rec.char)
        if owner ~= nil and owner ~= rec.by then return false, "not owner" end
      end
      if rec.del ~= true then
        local ok, err = Obs.Validate(rec.d)
        if not ok then return false, err end
        if rec.d.at > self.now() + DAY then return false, "at too far ahead" end
      end
      return true
    end,
    onApplied = logApplied,
  })
  ctx.syncs = ctx.syncs or {}
  ctx.syncs[#ctx.syncs + 1] = self.sync
  return self
end

function O:Start()
  self.set:Purge()
  self.sync:Start()
end

function O:_nextId()
  local pid = self.profile:Id()
  if not self.counter then
    local prefix, max = pid .. ":o", 0
    for id in pairs(self.store) do
      if id:sub(1, #prefix) == prefix then
        local n = tonumber(id:sub(#prefix + 1))
        if n and n > max then max = n end
      end
    end
    self.counter = max
  end
  self.counter = self.counter + 1
  return pid .. ":o" .. self.counter
end

function O:Publish(d)
  if self.profile:IsExcluded(self.playerChar) then return "excluded" end
  local ok, err = Obs.Validate(d)
  if not ok then return "invalid", err end
  local t = self.now()
  local rec = { id = self:_nextId(), v = 1, t = t, exp = t + RETENTION,
    by = self.profile:Id(), char = self.playerChar, d = copy(d) }
  local status = self.sync:Publish(rec)
  return status, rec
end

function O:List(kind)
  local out = {}
  local now = self.now()
  for _, rec in ipairs(self.set:List(false)) do
    if rec.exp > now and type(rec.d) == "table" and (kind == nil or rec.d.kind == kind) then
      out[#out + 1] = rec
    end
  end
  return out
end
