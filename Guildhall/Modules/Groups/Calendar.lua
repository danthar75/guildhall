local ADDON, ns = ...

-- Calendar: guild calendar raids for the board, and the "signed up and showed up" credit.
--
-- Observations (kind "signup", strict validator, exactly two shapes):
--   Groups signup   { post (<= 64), instance, from, to, status = "signedup"|"withdrawn", at }
--       published by the player's own client from Groups:SignUp / Groups:Withdraw; from..to is the post's
--       credit window (Now posts created..exp, scheduled posts start-1800..start+21600).
--   Calendar signup { title (<= 64), start, instance?, status = "accepted"|"signedup", at }
--       published by cal:Refresh, at most once per (title, start).
--   Both need to > from and to - from <= 30000 (the calendar window is start-1800..start+21600).
-- Deriver "signup" (observations only; the Groups records are purged with their post): per (char, post) or
-- (char, title, start) the latest observation by (at, id) wins; a withdrawn one counts nothing. A signup
-- counts when Credit's AttendedIn finds a verified kill crediting rec.char (named by at least 2 reports)
-- whose `at` falls in its window and not before the signup, of its instance (a calendar entry without an
-- instance: any raid). Non-final dungeon boss kills never count (they expire after 2 days). Credit goes
-- to rec.char (the player's own client). At most one groups.signedup per (char, instance, server day of
-- the kill), so a raid that is both posted and on the calendar counts once.
-- ref = "signup:<char>:<instance>:<dayKey>".
-- Uncounted rows ("no verified kill yet", "already credited tonight") go to the deriving client's own chars.
--
-- Wiring (Task 9): Calendar.new(ctx) with ctx { config, observations, compat, now, playerChar, profile, db };
-- call cal:Refresh() on login, CALENDAR_UPDATE_EVENT_LIST and on leaving an instance.
--
-- Globals: ns.Groups.Calendar.
ns.Groups = ns.Groups or {}
local Calendar = {}
ns.Groups.Calendar = Calendar

local MAX_STR = 64
local MAX_SPAN = 30000
local PRE, POST_WINDOW = 1800, 21600
local HORIZON = 14 * 86400
local KEEP = 30 * 86400
local MAX_T = 4000000000

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
local function isInt(x) return finite(x) and x == math.floor(x) end
local function inT(x) return isInt(x) and x >= 0 and x <= MAX_T end
local function str(x) return type(x) == "string" and x ~= "" and #x <= MAX_STR end

local GROUP_FIELDS = { kind = true, post = true, instance = true, from = true, to = true, status = true, at = true }
local CAL_FIELDS = { kind = true, title = true, start = true, instance = true, status = true, at = true }

function Calendar.ValidateSignup(d)
  if type(d) ~= "table" then return false, "not a table" end
  local fields = d.post ~= nil and GROUP_FIELDS or CAL_FIELDS
  for k in pairs(d) do
    if not fields[k] then return false, "bad field: " .. tostring(k) end
  end
  if not inT(d.at) then return false, "bad at" end
  if d.instance ~= nil and not (type(d.instance) == "string" and ns.Instances.Get(d.instance)) then
    return false, "bad instance"
  end
  if d.post ~= nil then
    if not str(d.post) then return false, "bad post" end
    if not ns.Instances.Get(d.instance) then return false, "bad instance" end
    if d.status ~= "signedup" and d.status ~= "withdrawn" then return false, "bad status" end
    if not (inT(d.from) and inT(d.to)) then return false, "bad window" end
    if d.to <= d.from or d.to - d.from > MAX_SPAN then return false, "bad window" end
  else
    if not str(d.title) then return false, "bad title" end
    if not inT(d.start) then return false, "bad start" end
    if d.status ~= "accepted" and d.status ~= "signedup" then return false, "bad status" end
  end
  return true
end

if ns.Observations and ns.Observations.AddKind then
  ns.Observations.AddKind("signup", Calendar.ValidateSignup)
end

local function tzOf(config, compat, now)
  return ns.Scoring.Clock(config, compat, finite(now) and now or 0).tz
end

-- Deriver -----------------------------------------------------------------------------------

-- A well-formed signup record: the item key, window and instance (nil = any raid).
local function parse(rec)
  local d = type(rec) == "table" and rec.d
  if type(d) ~= "table" or d.kind ~= "signup" or type(rec.char) ~= "string" or type(rec.id) ~= "string"
      or not Calendar.ValidateSignup(d) then
    return nil
  end
  if d.post ~= nil then
    return { post = true, key = "g|" .. d.post, from = d.from, to = d.to, instance = d.instance, withdrawn = d.status == "withdrawn" }
  end
  return { key = "c|" .. d.title .. "|" .. d.start, from = d.start - PRE, to = d.start + POST_WINDOW,
    instance = d.instance, withdrawn = false }
end

function Calendar.Derive(list, ctx)
  ctx = ctx or {}
  local config = ctx.config
  local now = ctx.now
  if type(now) == "function" then now = now() end
  local tz = tzOf(config, ctx.compat, now)
  local profile = ctx.profile or (config and config.profile)
  local credit = ns.Groups.Credit.new(ctx)

  local own = {}
  if ctx.playerChar or (config and config.playerChar) then own[ctx.playerChar or config.playerChar] = true end
  if profile and profile.Id and profile.CharsOf then
    for _, ch in ipairs(profile:CharsOf(profile:Id()) or {}) do own[ch] = true end
  end

  -- latest observation per (char, item)
  local latest = {}
  for _, rec in ipairs(list or {}) do
    local p = parse(rec)
    if p then
      local lk = rec.char .. "|" .. p.key
      local cur = latest[lk]
      if not cur or rec.d.at > cur.at or (rec.d.at == cur.at and rec.id > cur.id) then
        p.char, p.at, p.id, p.lk = rec.char, rec.d.at, rec.id, lk
        latest[lk] = p
      end
    end
  end
  local items = {}
  for _, p in pairs(latest) do
    if not p.withdrawn then items[#items + 1] = p end
  end
  table.sort(items, function(a, b) return a.lk < b.lk end)

  -- candidate credits: (char, instance, kill day) -> earliest kill, then item key
  -- A signup must come before the kill (and, for a post, inside its own window): a self-declared
  -- window around a kill that already happened earns nothing.
  local best, rows = {}, {}
  for _, p in ipairs(items) do
    local found
    if not p.post or p.at <= p.to then
      local kill = credit:AttendedIn(p.instance, p.char, math.max(p.from, p.at), p.to)
      if kill then found = { kill = kill, day = ns.Scoring.DayKey(kill.at, tz) } end
    end
    if found then
      local ck = p.char .. "|" .. found.kill.instance .. "|" .. found.day
      local cur = best[ck]
      if not cur then
        best[ck] = { p = p, kill = found.kill, day = found.day }
      elseif own[p.char] then
        rows[#rows + 1] = { type = "groups.signedup", char = p.char, value = 1, at = found.kill.at, counted = false,
          why = "already credited tonight",
          ref = "signup:" .. p.char .. ":" .. found.kill.instance .. ":" .. found.day .. ":dup:" .. p.lk }
      end
    elseif own[p.char] then
      local day = ns.Scoring.DayKey(p.from + PRE, tz)
      rows[#rows + 1] = { type = "groups.signedup", char = p.char, value = 1, at = p.from + PRE, counted = false,
        why = "no verified kill yet", ref = "signup:" .. p.char .. ":" .. tostring(p.instance or "any") .. ":" .. day
          .. ":pending:" .. p.lk }
    end
  end
  local out = {}
  local keys = {}
  for ck in pairs(best) do keys[#keys + 1] = ck end
  table.sort(keys)
  for _, ck in ipairs(keys) do
    local b = best[ck]
    out[#out + 1] = { type = "groups.signedup", char = b.p.char, value = 1, at = b.kill.at, counted = true,
      ref = "signup:" .. b.p.char .. ":" .. b.kill.instance .. ":" .. b.day }
  end
  for _, r in ipairs(rows) do out[#out + 1] = r end
  return out
end

ns.Activity.RegisterDeriver("signup", Calendar.Derive)

-- Service ---------------------------------------------------------------------------------
-- ctx: { config, observations, compat, now, playerChar, profile?, db? }.

local C = {}
C.__index = C

function Calendar.new(ctx)
  local self = setmetatable({ ctx = ctx }, C)
  self.config, self.obs, self.compat, self.now = ctx.config, ctx.observations, ctx.compat, ctx.now
  self.profile = ctx.profile or (ctx.config and ctx.config.profile)
  if type(ctx.db) == "table" then
    ctx.db.calSent = type(ctx.db.calSent) == "table" and ctx.db.calSent or {}
    self.sent = ctx.db.calSent
  else
    self.sent = {}
  end
  self.events = {}
  return self
end

-- Reads the guild calendar (today + 14 days) and publishes the player's own accepted/signed-up events,
-- once per (title, start). A nil reading (instance, restricted, secret) changes nothing.
function C:Refresh()
  local now = math.floor(self.now())
  for k, start in pairs(self.sent) do
    if type(start) ~= "number" or start < now - KEEP then self.sent[k] = nil end
  end
  local list = self.compat and self.compat.GuildEvents and self.compat:GuildEvents(now, now + HORIZON) or nil
  if type(list) ~= "table" then return false end
  self.events = list
  local p = self.profile
  if p and p.NeedsConsent and p:NeedsConsent() then return true end
  for _, ev in ipairs(list) do
    if ev.myStatus == "accepted" or ev.myStatus == "signedup" then
      local title = ev.title:sub(1, MAX_STR)
      local key = title .. "|" .. ev.start
      if not self.sent[key] then
        local status = self.obs:Publish({ kind = "signup", title = title, start = ev.start, instance = ev.instance,
          status = ev.myStatus, at = now })
        if status == "accepted" then self.sent[key] = ev.start end
      end
    end
  end
  return true
end

-- The chars whose own signup observation for the event (title, start) exists, sorted.
function C:Attendees(title, start)
  local seen, out = {}, {}
  local t = type(title) == "string" and title:sub(1, MAX_STR) or nil
  for _, rec in ipairs(self.obs and self.obs:List("signup") or {}) do
    local d = rec.d
    if type(d) == "table" and d.post == nil and d.title == t and d.start == start and type(rec.char) == "string"
        and not seen[rec.char] then
      seen[rec.char] = true
      out[#out + 1] = rec.char
    end
  end
  table.sort(out)
  return out
end

-- Calendar raids for the board: read-only, marked "Calendar". accepted = guild members (profiles) whose
-- own signup observation for the event exists.
function C:Events()
  local by = {}
  for _, rec in ipairs(self.obs and self.obs:List("signup") or {}) do
    local d = rec.d
    if type(d) == "table" and d.title ~= nil and d.start ~= nil and d.post == nil and type(rec.by) == "string" then
      local k = d.title .. "|" .. tostring(d.start)
      by[k] = by[k] or {}
      by[k][rec.by] = true
    end
  end
  local out = {}
  for _, ev in ipairs(self.events) do
    local n = 0
    for _ in pairs(by[ev.title:sub(1, MAX_STR) .. "|" .. ev.start] or {}) do n = n + 1 end
    out[#out + 1] = { title = ev.title, start = ev.start, instance = ev.instance, myStatus = ev.myStatus,
      source = "Calendar", accepted = n }
  end
  return out
end
