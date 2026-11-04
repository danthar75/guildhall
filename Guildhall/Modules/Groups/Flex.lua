local ADDON, ns = ...

-- Flex: asking a raider to switch spec, and the "spec switches when asked" credit.
--
-- Observations (strict validators, kinds registered in Observations):
--   flexask  { raider, instance, note? (<= 64), at }: a leader asks one of the raider's chars. The ask's
--       id is the observation record id (rec.id); the other two kinds name it in `ask`.
--   flexdone { ask, at }: the raider's client, when the active spec group (read through Compat, never
--       secret or nil) changes within 900 s of an open ask naming one of its chars. Once per ask.
--   flexok   { ask, at }: the asker's "Switched" tick, for raiders without dual spec.
-- Deriver "flexask": one groups.flex per ask (char = raider, ref = "flex:<ask id>") when all hold:
--   * the raider attended: Credit's AttendedNear finds a verified kill of that instance crediting the
--     raider with kill.at in [ask.at - 30 min, ask.at + 6 h]; the night is that kill's server day
--     (an ask at 23:40 before kills after midnight counts);
--   * the asker is permitted when deriving (perms:Can "flex"; rank from this client's roster, absent
--     from the roster means not permitted; a raidlead grant needs Credit.RaidLeaders that night);
--   * a flexdone from the raider's profile (profile:OwnerOf(raider) == rec.by) with 0 <= at - ask.at <=
--     900, or a flexok from the asker's profile (rec.by equal to the ask's rec.by), exists.
-- One groups.flex per raider per instance per night: the first qualifying ask by (at, id) counts, later
-- ones get an uncounted row, why = "already credited tonight" (own chars only).
-- An ask whose asker's profile owns the raider never counts. Uncounted rows ("waiting for the switch",
-- "not permitted") go only to the raider's own chars (the deriving client's profile).
--
-- Wiring: the owner of the Flex service calls flex:OnSpecChanged() from ACTIVE_TALENT_GROUP_CHANGED
-- and PLAYER_TALENT_UPDATE (KillWatch:OnSpecChanged stays an empty hook; Task 9 wires Flex).
--
-- Globals: ns.Groups.Flex.
ns.Groups = ns.Groups or {}
local Flex = {}
ns.Groups.Flex = Flex

local WINDOW = 900
local MAX_STR = 64
local REFUSED = "no permission"
local ASK_FIELDS = { kind = true, raider = true, instance = true, note = true, at = true }
local REPLY_FIELDS = { kind = true, ask = true, at = true }

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
local function isInt(x) return finite(x) and x == math.floor(x) end

local function validRaider(r)
  return type(r) == "string" and #r <= MAX_STR and r:match("^[^%-]+%-[^%-]+$") ~= nil
end

function Flex.ValidateAsk(d)
  for k in pairs(d) do if not ASK_FIELDS[k] then return false, "bad field: " .. tostring(k) end end
  if not validRaider(d.raider) then return false, "bad raider" end
  if not ns.Instances.Get(d.instance) then return false, "bad instance" end
  if d.note ~= nil and (type(d.note) ~= "string" or #d.note > MAX_STR) then return false, "bad note" end
  if not isInt(d.at) then return false, "bad at" end
  return true
end

local function validateReply(d)
  for k in pairs(d) do if not REPLY_FIELDS[k] then return false, "bad field: " .. tostring(k) end end
  if type(d.ask) ~= "string" or d.ask == "" or #d.ask > MAX_STR then return false, "bad ask" end
  if not isInt(d.at) then return false, "bad at" end
  return true
end
Flex.ValidateDone, Flex.ValidateOk = validateReply, validateReply

if ns.Observations and ns.Observations.AddKind then
  ns.Observations.AddKind("flexask", Flex.ValidateAsk)
  ns.Observations.AddKind("flexdone", validateReply)
  ns.Observations.AddKind("flexok", validateReply)
end

local function tzOf(config, compat, now)
  return ns.Scoring.Clock(config, compat, finite(now) and now or 0).tz
end

local function leaders(instance, dayKey)
  local Credit = ns.Groups.Credit
  if not (Credit and Credit.RaidLeaders) then return {} end
  return Credit.RaidLeaders(instance, dayKey) or {}
end

-- Deriver -----------------------------------------------------------------------------------

local function wellFormedAsk(rec)
  local d = type(rec) == "table" and rec.d
  return type(d) == "table" and d.kind == "flexask" and type(rec.id) == "string" and type(rec.char) == "string"
    and type(rec.by) == "string" and validRaider(d.raider) and finite(d.at) and ns.Instances.Get(d.instance)
end

function Flex.Derive(list, ctx)
  ctx = ctx or {}
  local config = ctx.config
  local perms = ctx.perms or (config and config.perms)
  if not perms then return {} end
  local now = ctx.now
  if type(now) == "function" then now = now() end
  local tz = tzOf(config, ctx.compat, now)
  local profile = ctx.profile or (config and config.profile)
  local credit = ns.Groups.Credit.new(ctx)

  -- the deriving client's own chars (uncounted rows are for these only)
  local own = {}
  if ctx.playerChar or (config and config.playerChar) then own[ctx.playerChar or config.playerChar] = true end
  if profile and profile.Id and profile.CharsOf then
    for _, ch in ipairs(profile:CharsOf(profile:Id()) or {}) do own[ch] = true end
  end

  -- replies by ask id (the Ledger's ctx.observations answers List for every kind)
  local function replies(kind)
    local by, src = {}, ctx.observations
    for _, rec in ipairs(src and src.List and src:List(kind) or {}) do
      local d = type(rec) == "table" and rec.d
      if type(d) == "table" and d.kind == kind and type(d.ask) == "string" and finite(d.at)
          and type(rec.by) == "string" then
        by[d.ask] = by[d.ask] or {}
        table.insert(by[d.ask], rec)
      end
    end
    return by
  end
  local dones, oks = replies("flexdone"), replies("flexok")

  local asks = {}
  for _, rec in ipairs(list or {}) do
    if wellFormedAsk(rec) then asks[#asks + 1] = rec end
  end
  table.sort(asks, function(a, b)
    if a.d.at ~= b.d.at then return a.d.at < b.d.at end
    return a.id < b.id
  end)
  local credited = {}

  local leadersOf, out = {}, {}
  for _, rec in ipairs(asks) do
    local d = rec.d
    local kill = credit:AttendedNear(d.instance, d.raider, d.at)
    local day = kill and ns.Scoring.DayKey(kill.at, tz)
    local lk = kill and d.instance .. "|" .. day
    if lk then leadersOf[lk] = leadersOf[lk] or credit:RaidLeaders(d.instance, day) end
    local owner = profile and profile.OwnerOf and profile:OwnerOf(d.raider) or nil
    if kill and owner ~= rec.by and rec.char ~= d.raider then
      local permitted = perms:Can(rec.char, "flex", { raidLeaders = leadersOf[lk] })
      local row = { type = "groups.flex", char = d.raider, value = 1, at = d.at, ref = "flex:" .. rec.id }
      if not permitted then
        row.counted, row.why = false, "not permitted"
      else
        local done = false
        if owner ~= nil then
          for _, r in ipairs(dones[rec.id] or {}) do
            local delta = r.d.at - d.at
            if r.by == owner and delta >= 0 and delta <= WINDOW then done = true; break end
          end
        end
        if not done then
          for _, r in ipairs(oks[rec.id] or {}) do
            if r.by == rec.by then done = true; break end
          end
        end
        if done then
          local ck = d.raider .. "|" .. lk
          if credited[ck] then
            row.counted, row.why = false, "already credited tonight"
          else
            credited[ck] = true
            row.counted = true
          end
        else
          row.counted, row.why = false, "waiting for the switch"
        end
      end
      if row.counted or own[d.raider] then out[#out + 1] = row end
    end
  end
  return out
end

ns.Activity.RegisterDeriver("flexask", Flex.Derive)

-- Service ---------------------------------------------------------------------------------
-- ctx: { config (LbConfig), observations, compat, now, playerChar, profile?, perms?, db? }.

local F = {}
F.__index = F

function Flex.new(ctx)
  local self = setmetatable({ ctx = ctx }, F)
  self.config, self.obs, self.compat, self.now = ctx.config, ctx.observations, ctx.compat, ctx.now
  self.perms = ctx.perms or (ctx.config and ctx.config.perms)
  self.playerChar = ctx.playerChar or (ctx.config and ctx.config.playerChar)
  self.profile = ctx.profile or (ctx.config and ctx.config.profile)
  -- db.flexSent[ask id] = the ask's at, for asks this client answered. An ask is open for 900 s
  -- only, so older entries (and malformed ones) are dropped here.
  if type(ctx.db) == "table" then
    ctx.db.flexSent = type(ctx.db.flexSent) == "table" and ctx.db.flexSent or {}
    self.sent = ctx.db.flexSent
    local now, dead = self.now(), {}
    for id, at in pairs(self.sent) do
      if not finite(at) or now - at >= WINDOW then dead[#dead + 1] = id end
    end
    for _, id in ipairs(dead) do self.sent[id] = nil end
  else
    self.sent = {}
  end
  self.group = self.compat and self.compat.ActiveSpecGroup and self.compat:ActiveSpecGroup() or nil
  return self
end

function F:_today()
  local now = self.now()
  return ns.Scoring.DayKey(now, tzOf(self.config, self.compat, now))
end

function F:_ownChars()
  local own = { [self.playerChar] = true }
  local p = self.profile
  if p and p.Id and p.CharsOf then
    for _, ch in ipairs(p:CharsOf(p:Id()) or {}) do own[ch] = true end
  end
  return own
end

-- Asks the raider's char to switch spec. Returns true, ask id or false, reason.
function F:Ask(raiderChar, instance, note)
  if not validRaider(raiderChar) then return false, "bad raider" end
  if type(instance) ~= "string" or not ns.Instances.Get(instance) then return false, "bad instance" end
  if note ~= nil then
    if type(note) ~= "string" then return false, "bad note" end
    note = ns.Util.Trim(note)
    if #note > MAX_STR then return false, "bad note" end
    if note == "" then note = nil end
  end
  if not self.perms:Can(self.playerChar, "flex", { raidLeaders = leaders(instance, self:_today()) }) then
    return false, REFUSED
  end
  if self:_ownChars()[raiderChar] then return false, "not yourself" end
  local status, rec = self.obs:Publish({ kind = "flexask", raider = raiderChar, instance = instance, note = note,
    at = math.floor(self.now()) })
  if status ~= "accepted" then return false, status end
  return true, rec.id
end

-- The asker's "Switched" tick for one of their own asks.
function F:Tick(askId)
  local p = self.profile
  local myId = p and p.Id and p:Id() or nil
  if myId == nil then return false, "not ready" end
  local ask
  for _, rec in ipairs(self.obs:List("flexask")) do
    if rec.id == askId then ask = rec; break end
  end
  if not ask then return false, "no such ask" end
  if ask.by ~= myId then return false, "not your ask" end
  local status = self.obs:Publish({ kind = "flexok", ask = askId, at = math.floor(self.now()) })
  if status ~= "accepted" then return false, status end
  return true
end

-- Tonight's (this server day) newest ask per raider char in `instance`, for the roster:
-- { ask = id, mine = asked by this profile, done = a flexdone from the raider's profile within 900 s
-- or a flexok from the asker's profile }. For display only: credit is decided by the deriver.
function F:Status(instance)
  local now = self.now()
  local tz = tzOf(self.config, self.compat, now)
  local today = ns.Scoring.DayKey(now, tz)
  local p = self.profile
  local me = p and p.Id and p:Id() or nil
  local latest = {}
  for _, rec in ipairs(self.obs:List("flexask")) do
    local d = rec.d
    if wellFormedAsk(rec) and d.instance == instance and ns.Scoring.DayKey(d.at, tz) == today then
      local cur = latest[d.raider]
      if not cur or d.at > cur.d.at or (d.at == cur.d.at and rec.id > cur.id) then latest[d.raider] = rec end
    end
  end
  local function answered(kind, ok)
    local set = {}
    for _, r in ipairs(self.obs:List(kind)) do
      local d = type(r) == "table" and r.d
      if type(d) == "table" and type(d.ask) == "string" and finite(d.at) and ok(r, d) then set[d.ask] = true end
    end
    return set
  end
  local byId = {}
  for _, rec in pairs(latest) do byId[rec.id] = rec end
  local dones = answered("flexdone", function(r, d)
    local ask = byId[d.ask]
    if not ask then return false end
    local owner = p and p.OwnerOf and p:OwnerOf(ask.d.raider) or nil
    local delta = d.at - ask.d.at
    return owner ~= nil and r.by == owner and delta >= 0 and delta <= WINDOW
  end)
  local oks = answered("flexok", function(r, d)
    local ask = byId[d.ask]
    return ask ~= nil and r.by == ask.by
  end)
  local out = {}
  for raider, rec in pairs(latest) do
    out[raider] = { ask = rec.id, mine = me ~= nil and rec.by == me, done = dones[rec.id] == true or oks[rec.id] == true }
  end
  return out
end

-- Open asks naming one of this profile's chars, newest first: under 900 s old, not answered yet.
function F:OpenAsks()
  local own, now, out = self:_ownChars(), self.now(), {}
  for _, rec in ipairs(self.obs:List("flexask")) do
    local d = rec.d
    if own[d.raider] and not self.sent[rec.id] and finite(d.at) and now - d.at >= 0 and now - d.at < WINDOW then
      out[#out + 1] = rec
    end
  end
  table.sort(out, function(a, b)
    if a.d.at ~= b.d.at then return a.d.at > b.d.at end
    return a.id > b.id
  end)
  return out
end

-- ACTIVE_TALENT_GROUP_CHANGED / PLAYER_TALENT_UPDATE: when the active spec group differs from the one
-- last read, answers each open ask once. A secret or nil reading changes nothing.
function F:OnSpecChanged()
  local g = self.compat and self.compat.ActiveSpecGroup and self.compat:ActiveSpecGroup() or nil
  if g ~= 1 and g ~= 2 then return 0 end
  local prev = self.group
  self.group = g
  if prev == nil or prev == g then return 0 end
  local n = 0
  for _, rec in ipairs(self:OpenAsks()) do
    local status = self.obs:Publish({ kind = "flexdone", ask = rec.id, at = math.floor(self.now()) })
    if status == "accepted" then
      self.sent[rec.id] = rec.d.at
      n = n + 1
    end
  end
  return n
end
