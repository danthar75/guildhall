local ADDON, ns = ...

-- Checklist: raid checklists, the raider's self-check, and the leadership-confirmed "prepared"
-- credit.
--
-- Records (in core.config, registered with LbConfig.AddRecordKind; sync bucket "c", version floor):
--   "checklist:<instance>:<slug>"   { instance, name (1..32 bytes), lines (<= 12), deleted?, by, at }
--       slug [a-z0-9_], 1..16, from the name (a numeric suffix when taken); the id is <= 48 bytes.
--       A line is { kind = "item", item, count = 1..200 }, { kind = "enchants" } or
--       { kind = "manual", text <= 64 }. core.config refuses deletions, so Delete publishes a new
--       version with deleted = true. Ids are never reused.
--   "checklistdefault:<instance>"   { instance, id, by, at }: the instance's default checklist. The
--       first checklist saved for an instance becomes its default; deleting the default moves it to
--       the first remaining checklist (by name).
--   Both: by = the author char, at = rec.t, exp = t + 10 years. Checked on arrival with the
--   Leaderboard's model: an unknown roster rejects for now, an author a loaded roster doesn't list
--   (left the guild) is accepted, otherwise perms:Can(rec.char, "checklists") with the raid leaders
--   of that instance on the record's server day (a raidlead grant covers only nights the author led
--   or assisted a verified kill there). Save, Delete and SetDefault check the same rule for today,
--   and each writes a history entry what = "checklist", key = the checklist id, before/after with
--   the changed keys (lines, deleted, default) plus the name on both sides, so the history reads
--   with the checklist's name.
--   Timestamps are client-trusted: a raidlead-only author can stamp a record (rec.t) on a night they
--   led and have it accepted later. The prepared deriver's attendance rule limits what that can do
--   to credit.
--
-- Observations:
--   prepcheck { instance, list = checklist id, ok, miss = failed lines, at }: the raider's own
--       check, published on READY_CHECK and the first time the client enters a raid with an active
--       checklist, at most once per instance per server day (db.lastCheck[instance] = dayKey,
--       persisted in ctx.db). Nothing is published when no automatic line (item, enchants) could
--       be read. ok = false means at least one line failed (miss >= 1). Informational only: it
--       earns nothing.
--   prepared  { raider, instance, ok, at }: a leadership confirmation (Confirm needs "prepared").
-- Deriver "prepared": a confirmation counts only when the raider attended: Credit's AttendedNear finds a
-- verified kill of that instance crediting the raider (named by at least 2 reports) with kill.at in
-- [at - 30 min, at + 6 h], so a confirmation backdated to a night the raider wasn't there earns
-- nothing, and one at 23:40 before kills after midnight still counts. The night is the server day of
-- that kill. Per (raider, instance, night), the newest confirmation whose author is permitted when
-- deriving wins (the author's rank from this client's roster; not on the roster means not permitted;
-- a raidlead grant needs Credit.RaidLeaders for that instance and night). One groups.prepared
-- contribution when it says ok = true.
--
-- Globals: ns.Groups.Checklist.
ns.Groups = ns.Groups or {}
local Checklist = {}
ns.Groups.Checklist = Checklist

local SLUG_MAX, ID_MAX, NAME_MAX, RAIDER_MAX = 16, 48, 32, 64
local RETENTION = 345600000 -- 10 years
local REFUSED = "no permission"
local CL_FIELDS = { instance = true, name = true, lines = true, deleted = true, by = true, at = true }
local DEF_FIELDS = { instance = true, id = true, by = true, at = true }
local PREPCHECK_FIELDS = { kind = true, instance = true, list = true, ok = true, miss = true, at = true }
local PREPARED_FIELDS = { kind = true, raider = true, instance = true, ok = true, at = true }

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
local function isInt(x) return finite(x) and x == math.floor(x) end
local function copy(t) return t ~= nil and ns.Util.DeepCopy(t) or nil end

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function validLines(lines)
  return ns.LbConfig ~= nil and ns.LbConfig.ValidChecklistLines(lines) == true
end

-- The instance and slug of a well-formed checklist id, else nil.
function Checklist.ParseId(id)
  if type(id) ~= "string" or #id > ID_MAX then return nil end
  local inst, slug = id:match("^checklist:([^:]+):([^:]*)$")
  if not inst or not ns.Instances.Get(inst) then return nil end
  if #slug < 1 or #slug > SLUG_MAX or not slug:match("^[a-z0-9_]+$") then return nil end
  return inst, slug
end
local parseId = Checklist.ParseId

local function defaultInstance(id)
  local inst = type(id) == "string" and id:match("^checklistdefault:([^:]+)$")
  if inst and ns.Instances.Get(inst) then return inst end
  return nil
end

local function tzOf(config, compat, now)
  return ns.Scoring.Clock(config, compat, finite(now) and now or 0).tz
end

-- Leaders and assistants of a verified kill of instance on server day dayKey.
local function leaders(instance, dayKey)
  local Credit = ns.Groups.Credit
  if not (Credit and Credit.RaidLeaders) then return {} end
  return Credit.RaidLeaders(instance, dayKey) or {}
end

-- Arrival validation ----------------------------------------------------------------------

local function stamped(rec)
  local d = rec.d
  if d.by ~= rec.char then return false, "checklist author mismatch" end
  if not finite(d.at) or d.at ~= rec.t then return false, "bad checklist time" end
  if rec.exp ~= rec.t + RETENTION then return false, "bad checklist expiry" end
  return true
end

local function authorCheck(config, rec, instance)
  local Config = ns.LbConfig
  local status = Config.AuthorStatus(config.roster, rec.char)
  if status == "unknown" or status == "bad" then return false, "roster unknown" end
  if status == "left" then return true, Config.LEFT end
  local day = ns.Scoring.DayKey(rec.t, tzOf(config, config.compat, rec.t))
  if not config.perms:Can(rec.char, "checklists", { raidLeaders = leaders(instance, day) }) then
    return false, "author lacks permission"
  end
  return true
end

function Checklist.ValidateRecord(config, rec)
  local inst = parseId(rec.id)
  if not inst then return false, "bad checklist id" end
  local d = rec.d
  if type(d) ~= "table" then return false, "not a table" end
  for k in pairs(d) do if not CL_FIELDS[k] then return false, "unknown checklist field" end end
  if d.instance ~= inst then return false, "checklist instance mismatch" end
  if type(d.name) ~= "string" or #d.name < 1 or #d.name > NAME_MAX then return false, "bad checklist name" end
  if not validLines(d.lines) then return false, "bad checklist lines" end
  if d.deleted ~= nil and type(d.deleted) ~= "boolean" then return false, "bad deleted" end
  local ok, err = stamped(rec)
  if not ok then return false, err end
  return authorCheck(config, rec, inst)
end

function Checklist.ValidateDefault(config, rec)
  local inst = defaultInstance(rec.id)
  if not inst then return false, "bad default id" end
  local d = rec.d
  if type(d) ~= "table" then return false, "not a table" end
  for k in pairs(d) do if not DEF_FIELDS[k] then return false, "unknown default field" end end
  if d.instance ~= inst or parseId(d.id) ~= inst then return false, "bad default checklist" end
  local ok, err = stamped(rec)
  if not ok then return false, err end
  return authorCheck(config, rec, inst)
end

if ns.LbConfig and ns.LbConfig.AddRecordKind then
  ns.LbConfig.AddRecordKind("checklist:", { validate = Checklist.ValidateRecord, bucket = "c",
    floor = function(id) return parseId(id) ~= nil end })
  ns.LbConfig.AddRecordKind("checklistdefault:", { validate = Checklist.ValidateDefault, bucket = "c",
    floor = function(id) return defaultInstance(id) ~= nil end })
end

-- Observation validators -------------------------------------------------------------------

function Checklist.ValidatePrepcheck(d)
  for k in pairs(d) do if not PREPCHECK_FIELDS[k] then return false, "bad field: " .. tostring(k) end end
  if not ns.Instances.Get(d.instance) then return false, "bad instance" end
  if parseId(d.list) ~= d.instance then return false, "bad list" end
  if type(d.ok) ~= "boolean" then return false, "bad ok" end
  if not isInt(d.miss) or d.miss < 0 or d.miss > 12 then return false, "bad miss" end
  return true
end

function Checklist.ValidatePrepared(d)
  for k in pairs(d) do if not PREPARED_FIELDS[k] then return false, "bad field: " .. tostring(k) end end
  if type(d.raider) ~= "string" or d.raider == "" or #d.raider > RAIDER_MAX then return false, "bad raider" end
  if not ns.Instances.Get(d.instance) then return false, "bad instance" end
  if type(d.ok) ~= "boolean" then return false, "bad ok" end
  return true
end

if ns.Observations and ns.Observations.AddKind then
  ns.Observations.AddKind("prepcheck", Checklist.ValidatePrepcheck)
  ns.Observations.AddKind("prepared", Checklist.ValidatePrepared)
end

-- Deriver -----------------------------------------------------------------------------------

local function newer(a, b)
  if a.d.at ~= b.d.at then return a.d.at > b.d.at end
  local at, bt = finite(a.t) and a.t or 0, finite(b.t) and b.t or 0
  if at ~= bt then return at > bt end
  return tostring(a.id) > tostring(b.id)
end

function Checklist.DerivePrepared(list, ctx)
  ctx = ctx or {}
  local config = ctx.config
  local perms = ctx.perms or (config and config.perms)
  if not perms then return {} end
  local now = ctx.now
  if type(now) == "function" then now = now() end
  local tz = tzOf(config, ctx.compat, now)
  local credit = ns.Groups.Credit.new(ctx)
  local leadersOf, best, keys, dayOf = {}, {}, {}, {}
  for _, rec in ipairs(list or {}) do
    local d = type(rec) == "table" and rec.d
    if type(d) == "table" and d.kind == "prepared" and type(d.raider) == "string" and type(d.ok) == "boolean"
        and finite(d.at) and ns.Instances.Get(d.instance) and type(rec.char) == "string" then
      local kill = credit:AttendedNear(d.instance, d.raider, d.at)
      if kill then
        local day = ns.Scoring.DayKey(kill.at, tz)
        local lk = d.instance .. "|" .. day
        local set = leadersOf[lk]
        if not set then
          set = credit:RaidLeaders(d.instance, day)
          leadersOf[lk] = set
        end
        if perms:Can(rec.char, "prepared", { raidLeaders = set }) then
          local key = d.raider .. "|" .. lk
          local cur = best[key]
          if not cur then keys[#keys + 1] = key end
          if not cur or newer(rec, cur) then best[key], dayOf[key] = rec, day end
        end
      end
    end
  end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    local rec = best[key]
    local d = rec.d
    if d.ok == true then
      out[#out + 1] = { type = "groups.prepared", char = d.raider, value = 1, at = d.at, counted = true,
        ref = "prepared:" .. d.instance .. ":" .. dayOf[key] .. ":" .. d.raider }
    end
  end
  return out
end

ns.Activity.RegisterDeriver("prepared", Checklist.DerivePrepared)

-- Service ---------------------------------------------------------------------------------
-- ctx: { config (LbConfig), observations, compat, now, playerChar, perms?, db? }.

local L = {}
L.__index = L

function Checklist.new(ctx)
  local self = setmetatable({ ctx = ctx }, L)
  self.config, self.obs, self.compat, self.now = ctx.config, ctx.observations, ctx.compat, ctx.now
  self.perms = ctx.perms or (ctx.config and ctx.config.perms)
  self.playerChar = ctx.playerChar or (ctx.config and ctx.config.playerChar)
  if type(ctx.db) == "table" then
    ctx.db.lastCheck = type(ctx.db.lastCheck) == "table" and ctx.db.lastCheck or {}
    self.lastCheck = ctx.db.lastCheck
  else
    self.lastCheck = {}
  end
  return self
end

function L:_today()
  local now = self.now()
  return ns.Scoring.DayKey(now, tzOf(self.config, self.compat, now))
end

function L:_can(key, instance)
  return self.perms:Can(self.playerChar, key, { raidLeaders = leaders(instance, self:_today()) })
end

local function liveView(rec, now)
  if not rec or rec.del or type(rec.d) ~= "table" or rec.d.deleted == true or rec.exp <= now then return nil end
  local d = rec.d
  return { id = rec.id, instance = d.instance, name = d.name, lines = copy(d.lines), by = d.by, at = d.at }
end

-- A live checklist { id, instance, name, lines, by, at }, or nil (missing or deleted).
function L:Get(id)
  if not parseId(id) then return nil end
  return liveView(self.config.set:Get(id), self.now())
end

-- The live checklists of an instance, by name.
function L:List(instance)
  local out, now = {}, self.now()
  local prefix = "checklist:" .. tostring(instance) .. ":"
  for id, rec in pairs(self.config.set.store) do
    if type(id) == "string" and id:sub(1, #prefix) == prefix then
      local v = liveView(rec, now)
      if v then out[#out + 1] = v end
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  return out
end

function L:_defaultId(instance)
  local rec = self.config.set:Get("checklistdefault:" .. tostring(instance))
  if rec and not rec.del and type(rec.d) == "table" then return rec.d.id end
  return nil
end

-- The instance's default checklist, or nil (none set, or it was deleted).
function L:Default(instance)
  local id = self:_defaultId(instance)
  local c = id and self:Get(id)
  if c and c.instance == instance then return c end
  return nil
end

-- The checklist a post or event picked ({ checklist = id } or a record with d.checklist) when it
-- is a live checklist of this instance, otherwise the instance's default.
function L:Active(instance, pick)
  local want
  if type(pick) == "table" then
    want = pick.checklist
    if want == nil and type(pick.d) == "table" then want = pick.d.checklist end
  end
  if type(want) == "string" then
    local c = self:Get(want)
    if c and c.instance == instance then return c end
  end
  return self:Default(instance)
end

-- A fresh id for a checklist name: lower-case [a-z0-9_] slug, "list" when nothing is left, and a
-- numeric suffix while the id is taken (deleted ids count as taken).
function L:_newId(instance, name)
  local base = name:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", "")
  base = base:sub(1, SLUG_MAX):gsub("_+$", "")
  if base == "" then base = "list" end
  local slug, n = base, 1
  local function id(s) return "checklist:" .. instance .. ":" .. s end
  while self.config.set:Get(id(slug)) do
    n = n + 1
    local suffix = "_" .. n
    slug = base:sub(1, SLUG_MAX - #suffix):gsub("_+$", "") .. suffix
  end
  return id(slug)
end

function L:_publishDefault(instance, id, name)
  local t = self.now()
  local ok, err = self.config:PublishChecked("checklistdefault:" .. instance,
    { instance = instance, id = id, by = self.playerChar, at = t }, t + RETENTION, t)
  if not ok then return false, err end
  self.config:_safeLogHistory("checklist", id, { name = name, default = false }, { name = name, default = true })
  return true
end

-- Saves a checklist: d = { id?, instance, name, lines }. Without an id a new one is made from the
-- name. Returns true, id or false, reason. Saving what is already stored publishes nothing.
function L:Save(d)
  if type(d) ~= "table" then return false, "bad checklist" end
  local instance = d.instance
  if type(instance) ~= "string" or not ns.Instances.Get(instance) then return false, "bad instance" end
  if not self:_can("checklists", instance) then return false, REFUSED end
  local name = type(d.name) == "string" and ns.Util.Trim(d.name) or nil
  if not name or #name < 1 or #name > NAME_MAX then return false, "bad name" end
  if not validLines(d.lines) then return false, "bad lines" end
  local lines = copy(d.lines)
  local id = d.id
  if id ~= nil then
    if parseId(id) ~= instance then return false, "bad id" end
  else
    id = self:_newId(instance, name)
  end
  local raw = self.config.set:Get(id)
  local old = self:Get(id)
  -- The name rides on both sides so the history always reads with it.
  local before, after = {}, { name = name }
  if old then
    if old.name == name and deepEqual(old.lines, lines) then return true, id end
    before.name = old.name
    if not deepEqual(old.lines, lines) then before.lines, after.lines = old.lines, lines end
  else
    before.name = name
    if raw and type(raw.d) == "table" and raw.d.deleted == true then
      before.deleted, after.deleted = true, false
      before.name, before.lines = raw.d.name, copy(raw.d.lines)
    end
    after.lines = lines
  end
  local t = self.now()
  local ok, err = self.config:PublishChecked(id,
    { instance = instance, name = name, lines = copy(lines), by = self.playerChar, at = t }, t + RETENTION, t)
  if not ok then return false, err end
  self.config:_safeLogHistory("checklist", id, before, after)
  if not self:Default(instance) then self:_publishDefault(instance, id, name) end
  return true, id
end

-- Deletes a checklist (a new version with deleted = true). Deleting the default moves it to the
-- first remaining checklist of the instance.
function L:Delete(id)
  local instance = parseId(id)
  if not instance then return false, "bad id" end
  local cur = self:Get(id)
  if not cur then return false, "no such checklist" end
  if not self:_can("checklists", instance) then return false, REFUSED end
  local wasDefault = self:_defaultId(instance) == id
  local t = self.now()
  local ok, err = self.config:PublishChecked(id, { instance = instance, name = cur.name, lines = cur.lines,
    deleted = true, by = self.playerChar, at = t }, t + RETENTION, t)
  if not ok then return false, err end
  self.config:_safeLogHistory("checklist", id, { name = cur.name, deleted = false },
    { name = cur.name, deleted = true })
  if wasDefault or not self:Default(instance) then
    local first = self:List(instance)[1]
    if first then self:_publishDefault(instance, first.id, first.name) end
  end
  return true
end

-- Makes a live checklist of the instance its default.
function L:SetDefault(instance, id)
  if type(instance) ~= "string" or not ns.Instances.Get(instance) then return false, "bad instance" end
  if not self:_can("checklists", instance) then return false, REFUSED end
  local c = self:Get(id)
  if not c or c.instance ~= instance then return false, "no such checklist" end
  if self:_defaultId(instance) == id then return true end
  return self:_publishDefault(instance, id, c.name)
end

-- The player's own check: { ok, miss, known, lines = { { ok, have, need } or { ok, missing } or {} } }.
-- An item line is unknown (ok = nil) when the count can't be read; enchants likewise; manual lines
-- are always unknown. known counts the automatic lines that could be read; miss counts the lines
-- that failed. ok = (miss == 0) when known > 0, and nil when nothing could be read.
function L:SelfCheck(checklist)
  local out, miss, known = {}, 0, 0
  local compat = self.compat
  for i, l in ipairs(type(checklist) == "table" and type(checklist.lines) == "table" and checklist.lines or {}) do
    local r
    if l.kind == "item" then
      local have = compat and compat.ItemCount and compat:ItemCount(l.item) or nil
      if type(have) == "number" then
        r = { ok = have >= l.count, have = have, need = l.count }
      else
        r = { need = l.count }
      end
    elseif l.kind == "enchants" then
      local slots = compat and compat.UnenchantedSlots and compat:UnenchantedSlots() or nil
      if type(slots) == "table" then
        r = { ok = #slots == 0, missing = copy(slots) }
      else
        r = {}
      end
    else
      r = {}
    end
    if r.ok == false then miss = miss + 1 end
    if r.ok ~= nil then known = known + 1 end
    out[i] = r
  end
  local ok
  if known > 0 then ok = miss == 0 end
  return { ok = ok, miss = miss, known = known, lines = out }
end

local function pickInstance(pick)
  if type(pick) ~= "table" then return nil end
  local inst = pick.instance
  if inst == nil and type(pick.d) == "table" then inst = pick.d.instance end
  return type(inst) == "string" and ns.Instances.Get(inst) and inst or nil
end

-- The entry of the instance the player is in (a map shared by several wings is ambiguous: nil).
function L:_zoneEntry()
  local mapId = self.compat and self.compat.InstanceKey and self.compat:InstanceKey() or nil
  if type(mapId) ~= "number" then return nil end
  local found
  for _, e in ipairs(ns.Instances.LIST) do
    if e.instanceId == mapId then
      if found then return nil end
      found = e
    end
  end
  return found
end

-- Runs and publishes the self-check for an instance, at most once per server day.
-- Returns true, result or false, reason.
function L:RunCheck(instance, pick)
  if type(instance) ~= "string" or not ns.Instances.Get(instance) then return false, "bad instance" end
  local c = self:Active(instance, pick)
  if not c then return false, "no checklist" end
  local day = self:_today()
  if self.lastCheck[instance] == day then return false, "already checked" end
  local r = self:SelfCheck(c)
  if r.known == 0 then return false, "nothing to check" end
  local status = self.obs:Publish({ kind = "prepcheck", instance = instance, list = c.id, ok = r.ok,
    miss = r.miss, at = math.floor(self.now()) })
  if status ~= "accepted" then return false, status end
  self.lastCheck[instance] = day
  return true, r
end

-- READY_CHECK: the instance the post or event names, else the one the player is in.
function L:OnReadyCheck(pick)
  local instance = pickInstance(pick)
  if not instance then
    local e = self:_zoneEntry()
    instance = e and e.key
  end
  if not instance then return false, "no instance" end
  return self:RunCheck(instance, pick)
end

-- Zone change: entering a raid with an active checklist checks it (once per server day).
function L:OnZone(pick)
  local e = self:_zoneEntry()
  if not e or e.kind ~= "raid" then return false, "not in a raid" end
  return self:RunCheck(e.key, pickInstance(pick) == e.key and pick or nil)
end

-- Tonight (this server day) in `instance`, per raider char: { ok, miss } from the raider's newest
-- own check (prepcheck, by its char), and confirmed = ok of the newest leadership confirmation
-- (prepared), whoever sent it. For display only: credit is decided by the deriver.
function L:Night(instance)
  local out, today = {}, self:_today()
  local tz = tzOf(self.config, self.compat, self.now())
  local function entry(char)
    out[char] = out[char] or {}
    return out[char]
  end
  local newest = {}
  local function take(rec, key)
    local cur = newest[key]
    if cur and not newer(rec, cur) then return false end
    newest[key] = rec
    return true
  end
  for _, kind in ipairs({ "prepcheck", "prepared" }) do
    for _, rec in ipairs(self.obs and self.obs:List(kind) or {}) do
      local d = type(rec) == "table" and rec.d
      if type(d) == "table" and d.instance == instance and finite(d.at) and ns.Scoring.DayKey(d.at, tz) == today then
        if kind == "prepcheck" and type(rec.char) == "string" and take(rec, "c|" .. rec.char) then
          local e = entry(rec.char)
          e.ok, e.miss = d.ok, d.miss
        elseif kind == "prepared" and type(d.raider) == "string" and take(rec, "p|" .. d.raider) then
          entry(d.raider).confirmed = d.ok
        end
      end
    end
  end
  return out
end

-- "Confirm all checked": boxes = { [raiderChar] = { checked = bool, changed = bool } } (changed = the
-- leader ticked or unticked it here). Publishes a confirmation for each guild member (roster IsMember
-- true) whose box is checked or was changed, when it differs from tonight's newest confirmation.
-- Returns the number published, and the last refusal reason (nil when none).
function L:ConfirmTicks(instance, boxes)
  if type(instance) ~= "string" or not ns.Instances.Get(instance) then return 0, "bad instance" end
  if type(boxes) ~= "table" then return 0, "bad boxes" end
  local roster = self.config and self.config.roster
  local night = self:Night(instance)
  local chars = {}
  for char in pairs(boxes) do chars[#chars + 1] = char end
  table.sort(chars)
  local n, lastErr = 0, nil
  for _, char in ipairs(chars) do
    local box = boxes[char]
    local want = type(box) == "table" and box.checked == true
    local member = type(char) == "string" and roster ~= nil and roster.IsMember ~= nil and roster:IsMember(char) == true
    local cur = night[char] and night[char].confirmed
    if member and (want or (type(box) == "table" and box.changed == true)) and cur ~= want then
      local ok, err = self:Confirm(char, instance, want)
      if ok then n = n + 1 else lastErr = err end
    end
  end
  return n, lastErr
end

-- A leadership confirmation that raiderChar was (ok = true) or was not prepared tonight.
function L:Confirm(raiderChar, instance, ok)
  if type(raiderChar) ~= "string" or raiderChar == "" or #raiderChar > RAIDER_MAX then return false, "bad raider" end
  if type(instance) ~= "string" or not ns.Instances.Get(instance) then return false, "bad instance" end
  if type(ok) ~= "boolean" then return false, "bad ok" end
  if not self:_can("prepared", instance) then return false, REFUSED end
  local status, rec = self.obs:Publish({ kind = "prepared", raider = raiderChar, instance = instance, ok = ok,
    at = math.floor(self.now()) })
  if status ~= "accepted" then return false, status end
  return true, rec
end
