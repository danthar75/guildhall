local ADDON, ns = ...

-- Observations: the replicated set of raw first-hand events (trades, COD, manual deals,
-- witnesses, bank readings) the Leaderboard derives its scores from. Day-bucketed Sync keeps
-- login cheap for large sets. Records live 400 days unless the publisher asks for a shorter
-- expiry (Publish opts.exp); every record's exp must lie within [d.at, t + 400 days]. Only
-- officers ever see the log detail.
ns.Observations = ns.Observations or {}
local Obs = ns.Observations

local SET_NAME = "core.observations"
local RETENTION = 34560000   -- 400 days
local DAY = 86400
local MAX_STR, MAX_ITEMS = 64, 6

Obs.KINDS = { trade = true, cod = true, manual = true, witness = true, bank = true }

local VALIDATORS, FIELDS = {}, {}
local MAX_NAMES = 40

-- Registers a kind. validateFn(d) -> ok, err is an optional strict check that runs after the
-- generic ones. opts.fields = { members = true, assists = true } declares the array fields the kind
-- may carry; other kinds reject them.
function Obs.AddKind(kind, validateFn, opts)
  if type(kind) == "string" and kind ~= "" then
    Obs.KINDS[kind] = true
    FIELDS[kind] = type(opts) == "table" and type(opts.fields) == "table" and opts.fields or nil
    VALIDATORS[kind] = type(validateFn) == "function" and validateFn or nil
  end
end

for _, k in ipairs({ "prepcheck", "prepared", "flexask", "flexdone", "flexok", "signup" }) do
  Obs.AddKind(k)
end

local function isInt(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge and x == math.floor(x)
end

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end

-- A record's expiry is valid when it is no later than the retention after its publish time and no
-- earlier than the event it records.
local function validExp(exp, t, at)
  return finite(exp) and finite(t) and finite(at) and exp <= t + RETENTION and exp >= at
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
    elseif tv == "table" and (k == "members" or k == "assists") and FIELDS[d.kind] and FIELDS[d.kind][k] then
      local count = 0
      for _ in pairs(v) do count = count + 1 end
      if count ~= #v or count > MAX_NAMES then return false, "bad " .. k end
      for _, name in ipairs(v) do
        if type(name) ~= "string" or name == "" or #name > MAX_STR then return false, "bad " .. k end
      end
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
  if d.kind == "bank" then
    local function inRange(v, lo, hi) return isInt(v) and v >= lo and v <= hi end
    if d.type ~= "dep" and d.type ~= "wd" then return false, "bad bank type" end
    if type(d.player) ~= "string" or d.player == "" then return false, "bad bank player" end
    if d.tab ~= nil then
      if not inRange(d.tab, 1, 8) then return false, "bad bank tab" end
      if not inRange(d.item, 1, 10000000) then return false, "bad bank item" end
      if not inRange(d.count, 1, 10000) then return false, "bad bank count" end
      if d.copper ~= nil then return false, "bad bank item entry" end
    else
      if not inRange(d.copper, 1, 100000000000) then return false, "bad bank copper" end
      if d.count ~= nil or d.item ~= nil then return false, "bad bank money entry" end
    end
  end
  local custom = VALIDATORS[d.kind]
  if custom then return custom(d) end
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
  self.changes = 0   -- bumps on every accepted change; the Ledger cache keys off it
  self.set = ns.ReplicatedSet.new(SET_NAME, self.store, {
    now = ctx.now, maxFuture = DAY,
    onChange = function()
      self.changes = self.changes + 1
      if ns.Events then ns.Events:Fire("ObservationsChanged") end
    end,
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
        if not validExp(rec.exp, rec.t, rec.d.at) then return false, "bad exp" end
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

-- Ids embed the publish second plus a per-session counter, so they never depend on local
-- history (a wiped store or purged records can't reissue an id peers still hold). The counter
-- is module-level so a fresh Observations object in the same session continues it.
local session = { at = nil, n = 0 }

function O:_nextId()
  local at = math.floor(self.now())
  if session.at ~= at then session.at, session.n = at, 0 end
  session.n = session.n + 1
  return string.format("%s:o%d_%d", self.profile:Id(), at, session.n)
end

-- opts.exp (optional): an earlier expiry for this record, within [d.at, now + 400 days]; the
-- record is dropped everywhere once it passes (List hides it, Purge removes it, Sync skips it).
function O:Publish(d, opts)
  if self.profile:IsExcluded(self.playerChar) then return "excluded" end
  local ok, err = Obs.Validate(d)
  if not ok then return "invalid", err end
  local t = self.now()
  local exp = t + RETENTION
  if type(opts) == "table" and opts.exp ~= nil then
    if not validExp(opts.exp, t, d.at) then return "invalid", "bad exp" end
    exp = opts.exp
  end
  local rec = { id = self:_nextId(), v = 1, t = t, exp = exp,
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
