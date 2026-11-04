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
--   * the asker is permitted when deriving (perms:Can "flex"; rank from this client's roster, absent
--     from the roster means not permitted; a raidlead grant needs Credit.RaidLeaders that day);
--   * the raider is a credited attendee of a verified kill of that instance on the ask's server day;
--   * a flexdone from the raider's profile (profile:OwnerOf(raider) == rec.by) with 0 <= at - ask.at <=
--     900, or a flexok from the asker's profile (rec.by equal to the ask's rec.by), exists.
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
  table.sort(asks, function(a, b) return a.id < b.id end)

  local leadersOf, attendees, out = {}, {}, {}
  for _, rec in ipairs(asks) do
    local d = rec.d
    local day = ns.Scoring.DayKey(d.at, tz)
    local lk = d.instance .. "|" .. day
    leadersOf[lk] = leadersOf[lk] or credit:RaidLeaders(d.instance, day)
    attendees[lk] = attendees[lk] or credit:Attendees(d.instance, day)
    local owner = profile and profile.OwnerOf and profile:OwnerOf(d.raider) or nil
    if attendees[lk][d.raider] and owner ~= rec.by and rec.char ~= d.raider then
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
          row.counted = true
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
  if type(ctx.db) == "table" then
    ctx.db.flexSent = type(ctx.db.flexSent) == "table" and ctx.db.flexSent or {}
    self.sent = ctx.db.flexSent
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
  local p = self.profile
  if self:_ownChars()[raiderChar] or (p and p.OwnerOf and p:OwnerOf(raiderChar) ~= nil
      and p:OwnerOf(raiderChar) == p:Id()) then
    return false, "not yourself"
  end
  local status, rec = self.obs:Publish({ kind = "flexask", raider = raiderChar, instance = instance, note = note,
    at = math.floor(self.now()) })
  if status ~= "accepted" then return false, status end
  return true, rec.id
end

-- The asker's "Switched" tick for one of their own asks.
function F:Tick(askId)
  local ask
  for _, rec in ipairs(self.obs:List("flexask")) do
    if rec.id == askId then ask = rec; break end
  end
  if not ask then return false, "no such ask" end
  if ask.by ~= self.profile:Id() then return false, "not your ask" end
  local status = self.obs:Publish({ kind = "flexok", ask = askId, at = math.floor(self.now()) })
  if status ~= "accepted" then return false, status end
  return true
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
      self.sent[rec.id] = true
      n = n + 1
    end
  end
  return n
end
