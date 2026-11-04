local ADDON, ns = ...

-- LbConfig: the small replicated set of officer-controlled Leaderboard settings.
--   "weights"       { weights = {[typeId]=0..1000}, tz = server offset seconds }  (newest version wins)
--   "month:YYYY-MM" frozen top-5 record of a finished month (first accepted wins; an officer
--                   retake, d.retake = true with a Greater version, replaces it)
--   "perms"         guild-rank permissions (ns.Permissions validates it: the author must be rank 0)
--   "history:<profile>:<t>:<n>"  append-only log of one decision (a weights change, a month
--                   retake or a permissions change): { what, key, before, after, by = char, at }.
--                   Never replaced (a second version is rejected); expires after 2 years. n is a
--                   per-session counter.
-- Weights and retakes need the "weights" / "retake" permission (guild master only by default); the
-- automatic month save stays an officer action. Other record kinds (exclude:) join later through
-- the id-prefix dispatch in validateRecord. A record is checked against the roster and permissions
-- only when it arrives, so a demoted author's earlier record stays in effect. An unknown roster
-- rejects it for now; the next sync offers it again.
ns.LbConfig = ns.LbConfig or {}
local Config = ns.LbConfig

local SET_NAME = "core.config"
local MONTH_RETENTION = 34560000 * 10
local GRACE = 259200          -- a month is saved 3 days after it ends
local TZ_STEP = 900           -- republish tz when the local offset moves this much
local MAX_WEIGHT = 1000
local TOP_N = 5
local MAX_CATCHUP = 13
local MAX_ID, MAX_NAME, MAX_BOARDS, MAX_WEIGHTS = 16, 48, 16, 32
local MAX_VALUE = 1e12
local RETENTION = 34560000
local HISTORY_RETENTION = 63072000 -- 2 years
-- What a history record may describe. Task 17 adds "bank".
local HISTORY_WHAT = { weights = true, month = true, perms = true }
local REFUSED = "no permission"

local C = {}
C.__index = C

local function copy(t) return t ~= nil and ns.Util.DeepCopy(t) or nil end

local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- Officer check for the automatic month save. true only when the roster is known and says so.
local function canAdminister(roster, char)
  return type(char) == "string" and roster ~= nil and roster:IsOfficer(char) == true
end

-- Whether char may still make the change a history entry describes. Used only to mark an entry
-- at display time ("no permission now").
local function canWriteHistory(self, char, what)
  if what == "weights" then return self.perms:Can(char, "weights") end
  if what == "month" then return self.perms:Can(char, "retake") end
  if what == "perms" then return self.perms:IsGuildMaster(char) end
  return canAdminister(self.roster, char)
end

-- History is a log of what happened, so a later demotion must not erase it. A record is accepted
-- when the roster is not loaded yet, or its author is (still) a guild member.
local function historyAuthorKnown(self, char)
  if type(char) ~= "string" then return false end
  local r = self.roster
  if r == nil or r.RankIndex == nil or (r.HasRanks and r:HasRanks() ~= true) then return true end
  return r:RankIndex(char) ~= nil
end

local function deepEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function validWeights(w)
  if type(w) ~= "table" then return false, "bad weights" end
  local n = 0
  for id, v in pairs(w) do
    n = n + 1
    if n > MAX_WEIGHTS then return false, "too many weights" end
    if type(id) ~= "string" or #id > MAX_NAME then return false, "bad weight id" end
    if not finite(v) or v < 0 or v > MAX_WEIGHT then return false, "bad weight value" end
  end
  return true
end

local function validTz(tz)
  return tz == nil or (finite(tz) and tz >= -86400 and tz <= 86400)
end

local function validTop5(list)
  if type(list) ~= "table" or #list > TOP_N then return false end
  local n = 0
  for _ in pairs(list) do n = n + 1 end
  if n ~= #list then return false end
  for _, e in ipairs(list) do
    if type(e) ~= "table" or type(e.profile) ~= "string" or #e.profile > MAX_ID
      or type(e.name) ~= "string" or #e.name > MAX_NAME
      or not finite(e.value) or e.value < 0 or e.value > MAX_VALUE
      or not finite(e.rank) or e.rank ~= math.floor(e.rank) or e.rank < 1 or e.rank > TOP_N then
      return false
    end
  end
  return true
end

local function validMonth(ym, d)
  if type(d) ~= "table" then return false, "not a table" end
  if d.month ~= ym then return false, "month mismatch" end
  if not finite(d.from) or not finite(d.to) or d.to <= d.from then return false, "bad range" end
  if not validTz(d.tz) then return false, "bad tz" end
  if not finite(d.goldKept) or d.goldKept < 0 then return false, "bad goldKept" end
  if not validTop5(d.overall) then return false, "bad overall" end
  if type(d.boards) ~= "table" then return false, "bad boards" end
  local n = 0
  for id, list in pairs(d.boards) do
    n = n + 1
    if type(id) ~= "string" or #id > MAX_ID * 2 or n > MAX_BOARDS or not validTop5(list) then
      return false, "bad board"
    end
  end
  local ok, err = validWeights(d.weights)
  if not ok then return false, err end
  if type(d.savedBy) ~= "string" or #d.savedBy > MAX_NAME or not finite(d.savedAt) then
    return false, "bad saver"
  end
  if d.retake ~= nil and type(d.retake) ~= "boolean" then return false, "bad retake" end
  return true
end

local function validSummary(x)
  return x == nil or (type(x) == "table" and type(x.savedBy) == "string" and #x.savedBy <= MAX_NAME
    and finite(x.savedAt))
end

local function validHistory(self, rec)
  local profile, at = rec.id:match("^history:([^:]+):(%d+):%d+$")
  if not profile or #profile > MAX_ID then return false, "bad history id" end
  -- Append-only: a new id starts at version 1. A re-delivery of the very same record is not an
  -- error (Apply files it as stale); any other second version is.
  local old = self.set:Get(rec.id)
  if old then
    local same = rec.v == old.v and rec.t == old.t and rec.char == old.char
      and (rec.del == true) == (old.del == true) and deepEqual(rec.d, old.d)
    if not same then return false, "history is append-only" end
  elseif rec.v ~= 1 then
    return false, "bad history version"
  end
  if rec.by ~= profile then return false, "history author mismatch" end
  local d = rec.d
  if type(d) ~= "table" then return false, "not a table" end
  if not historyAuthorKnown(self, rec.char) then return false, "author not a guild member" end
  if not HISTORY_WHAT[d.what] then return false, "unknown history kind" end
  if d.by ~= rec.char then return false, "history author mismatch" end
  if not finite(d.at) or d.at ~= rec.t or tonumber(at) ~= rec.t then
    return false, "bad history time"
  end
  if rec.exp ~= rec.t + HISTORY_RETENTION then return false, "bad history expiry" end
  if d.key ~= nil and (type(d.key) ~= "string" or #d.key > MAX_NAME) then return false, "bad key" end
  if d.what == "weights" then
    local ok, err = validWeights(d.before)
    if not ok then return false, err end
    return validWeights(d.after)
  end
  if d.what == "perms" then
    local ok, err = ns.Permissions.ValidGrants(d.before)
    if not ok then return false, err end
    return ns.Permissions.ValidGrants(d.after)
  end
  if not validSummary(d.before) or not validSummary(d.after) then return false, "bad summary" end
  return true
end

-- Dispatch by id prefix. Returns ok, reason.
local function validateRecord(self, rec)
  local id = rec.id
  if rec.del == true then return false, "deletions not allowed" end
  if id:sub(1, 8) == "history:" then return validHistory(self, rec) end
  if id == "perms" then return self.perms:Validate(rec) end
  if id == "weights" then
    if not self.perms:Can(rec.char, "weights") then return false, "author lacks permission" end
    if type(rec.d) ~= "table" then return false, "not a table" end
    if not validTz(rec.d.tz) then return false, "bad tz" end
    if rec.d.changedBy ~= nil and (type(rec.d.changedBy) ~= "string" or #rec.d.changedBy > MAX_NAME) then
      return false, "bad changedBy"
    end
    if rec.d.changedAt ~= nil and not finite(rec.d.changedAt) then return false, "bad changedAt" end
    return validWeights(rec.d.weights)
  end
  local ym = id:match("^month:(%d%d%d%d%-%d%d)$")
  if ym then
    if type(rec.d) == "table" and rec.d.retake == true then
      if not self.perms:Can(rec.char, "retake") then return false, "author lacks permission" end
    elseif not canAdminister(self.roster, rec.char) then
      return false, "author not an officer"
    end
    local m = tonumber(ym:sub(6, 7))
    if m < 1 or m > 12 then return false, "bad month id" end
    local ok, err = validMonth(ym, rec.d)
    if not ok then return false, err end
    local old = self.set:Get(id)
    if old and rec.v > old.v and rec.d.retake ~= true then
      return false, "month already saved"
    end
    return true
  end
  return false, "unknown record kind"
end

function Config.new(ctx)
  local self = setmetatable({}, C)
  self.ctx = ctx
  self.profile, self.log, self.now = ctx.profile, ctx.log, ctx.now
  self.roster, self.compat = ctx.roster, ctx.compat
  self.playerChar = ctx.playerChar
  self.historySeq = 0
  -- Permissions come through ctx (the Module builds them); a bare ctx gets its own.
  self.perms = ctx.perms or ns.Permissions.new({ roster = ctx.roster, profile = ctx.profile, now = ctx.now,
    compat = ctx.compat })
  if self.perms.config == nil then self.perms:Attach(self) end
  self.set = ns.ReplicatedSet.new(SET_NAME, ctx.db, {
    now = ctx.now, maxFuture = 86400,
    onChange = function() if ns.Events then ns.Events:Fire("LeaderboardConfigChanged") end end,
  })

  local function logApplied(rec, status, old, sender, reason)
    local e = { t = self.now(), set = SET_NAME, id = rec.id, v = rec.v, author = rec.by,
      authorChar = rec.char, relayer = sender }
    if status == "accepted" then
      e.result, e.reason = "accepted", reason
      e.action = (type(rec.d) == "table" and rec.d.retake) and "retake" or "config"
      e.detail = copy(rec.d)
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
    validate = function(rec) return validateRecord(self, rec) end,
    onApplied = logApplied,
  })
  ctx.syncs = ctx.syncs or {}
  ctx.syncs[#ctx.syncs + 1] = self.sync
  return self
end

function C:Start()
  self.set:Purge()
  self.sync:Start()
end

function C:_isOfficer() return canAdminister(self.roster, self.playerChar) end
function C:_can(key) return self.perms:Can(self.playerChar, key) end

function C:_publish(id, d, exp, t)
  t = t or self.now()
  local rec = { id = id, v = self.set:NextVersion(id), t = t, exp = exp or (t + MONTH_RETENTION),
    by = self.profile:Id(), char = self.playerChar, d = d }
  return self.sync:Publish(rec) == "accepted", rec
end

-- Records an officer decision next to the change it describes, in the same call as the publish.
-- The id carries a per-session counter so two changes in one second don't collide; a counter
-- that restarts after a reload skips ids already taken.
function C:_logHistory(what, key, before, after)
  local at = self.now()
  local id
  repeat
    self.historySeq = self.historySeq + 1
    id = string.format("history:%s:%d:%d", self.profile:Id(), at, self.historySeq)
  until not self.set:Get(id)
  local d = { what = what, key = key, before = before, after = after, by = self.playerChar, at = at }
  local rec = { id = id, v = 1, t = at, exp = at + HISTORY_RETENTION, by = self.profile:Id(),
    char = self.playerChar, d = d }
  local ok, reason = validateRecord(self, rec)
  if not ok then
    self.log:Add({ t = at, set = SET_NAME, id = id, v = 1, author = rec.by, authorChar = rec.char,
      action = "invalid", result = "rejected", reason = reason })
    return false
  end
  return self.sync:Publish(rec) == "accepted"
end

-- Never lets a history problem escape after the change it records has been sent.
function C:_safeLogHistory(...)
  local ok, err = pcall(self._logHistory, self, ...)
  if not ok and ns.OnError then ns.OnError(err) end
end

-- Whether an entry's author could still make that change now (for the "no permission now" mark).
function C:HistoryAuthorPermitted(entry)
  return type(entry) == "table" and canWriteHistory(self, entry.by, entry.what) == true
end

-- Change history, newest first: { id, what, key, before, after, by, at }.
function C:History()
  local out = {}
  for _, rec in ipairs(self.set:List(false)) do
    if rec.id:match("^history:") and type(rec.d) == "table" and rec.exp > self.now() then
      local e = copy(rec.d)
      e.id = rec.id
      e.seq = tonumber(rec.id:match(":(%d+)$")) or 0
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    if a.seq ~= b.seq then return a.seq > b.seq end
    return a.id > b.id
  end)
  for _, e in ipairs(out) do e.seq = nil end
  return out
end

local function liveData(self, id)
  local rec = self.set:Get(id)
  if rec and not rec.del and type(rec.d) == "table" then return rec.d end
  return nil
end

-- Defaults merged with the record's weights.
function C:Weights()
  local out = {}
  for _, def in ipairs(ns.Activity.Types()) do out[def.id] = def.weight end
  local d = liveData(self, "weights")
  if d and type(d.weights) == "table" then
    for id, v in pairs(d.weights) do
      if finite(v) and v >= 0 and v <= MAX_WEIGHT then out[id] = v end
    end
  end
  return out
end

-- Who last changed the weights and when: { char, at }, or nil while only defaults apply. A tz
-- refresh republishes the record but carries the original d.changedBy / d.changedAt over;
-- records from before those existed fall back to the record's own author and time.
function C:WeightsInfo()
  local rec = self.set:Get("weights")
  if not rec or rec.del or type(rec.d) ~= "table" then return nil end
  local d = rec.d
  if type(d.changedBy) == "string" and finite(d.changedAt) then return { char = d.changedBy, at = d.changedAt } end
  if type(rec.char) ~= "string" or not finite(rec.t) then return nil end
  return { char = rec.char, at = rec.t }
end

function C:Tz()
  local d = liveData(self, "weights")
  return d and finite(d.tz) and d.tz or nil
end

function C:PublishWeights(map)
  if not self:_can("weights") then return false, REFUSED end
  local ok, err = validWeights(map)
  if not ok then return false, err end
  local tz = self.compat:ServerOffset()
  if tz == nil then tz = self:Tz() end
  local before = self:Weights()
  local good = self:_publish("weights", { weights = copy(map), tz = tz,
    changedBy = self.playerChar, changedAt = self.now() })
  if good then
    local after = self:Weights() -- as now stored, defaults merged in
    local b, a = {}, {}
    for id, v in pairs(before) do if after[id] ~= v then b[id] = v end end
    for id, v in pairs(after) do if before[id] ~= v then a[id] = v end end
    self:_safeLogHistory("weights", nil, b, a)
  end
  return good, (not good) and "not accepted" or nil
end

-- Republishes the weights record, so it needs the "weights" permission. Without it the tz is
-- left alone and clients use their own offset.
function C:MaybeRefreshTz()
  if not self:_can("weights") then return false end
  local offset = self.compat:ServerOffset()
  if offset == nil then return false end
  -- Only an existing record is refreshed. A client that has not synced yet must not publish
  -- one: it would hold defaults only and win by version over the guild's real weights.
  local d = liveData(self, "weights")
  if not d then return false end
  if finite(d.tz) and math.abs(offset - d.tz) < TZ_STEP then return false end
  local weights = type(d.weights) == "table" and copy(d.weights) or {}
  local info = self:WeightsInfo() -- an older record without the fields is stamped from its own author
  return (self:_publish("weights", { weights = weights, tz = offset,
    changedBy = info and info.char, changedAt = info and info.at }))
end

function C:Month(ym)
  return copy(liveData(self, "month:" .. tostring(ym)))
end

function C:Months()
  local out = {}
  for _, rec in ipairs(self.set:List(false)) do
    local ym = rec.id:match("^month:(%d%d%d%d%-%d%d)$")
    if ym then out[#out + 1] = ym end
  end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- Profile's display character: online, else the character that last published its record.
function Config._displayName(profile, profileId)
  local char = profile:OnlineChar(profileId)
  if not char and profile.set then
    local rec = profile.set:Get(profileId)
    char = rec and rec.char
  end
  if not char then char = profile:CharsOf(profileId)[1] end
  return ns.Util.DisplayName(char or profileId)
end

local function top5(self, entries)
  local out = {}
  for i = 1, math.min(TOP_N, #entries) do
    local e = entries[i]
    out[i] = { profile = e.profile, name = Config._displayName(self.profile, e.profile),
      value = e.value, rank = e.rank }
  end
  return out
end

-- The record payload for a month, from the ledger and the current weights.
function C:_monthData(ym, ledger, now)
  local tz = self:Tz() or self.compat:ServerOffset() or 0
  local from, to = ns.Scoring.MonthRange(ym, tz)
  local result = ledger:Query({ from = from, to = to })
  local weights = self:Weights()
  local boards = {}
  for _, def in ipairs(ns.Activity.Types()) do
    if def.verify ~= "self" then boards[def.id] = top5(self, ns.Scoring.Board(result, def.id, weights)) end
  end
  return { month = ym, from = from, to = to, tz = tz, goldKept = result.goldKept or 0,
    overall = top5(self, ns.Scoring.Board(result, "overall", weights)), boards = boards,
    weights = weights, savedBy = self.playerChar, savedAt = now }
end

-- Saves every unsaved finished month (oldest first, at most MAX_CATCHUP per call) whose grace
-- has passed and whose whole range is still inside the observation retention.
--
-- Concurrent first saves: the earliest save must win on every client, but the set keeps the
-- Greater (v, t). So a v1 record is stamped with an inverted time, t = 2 * (monthEnd + GRACE)
-- - savedAt: an earlier save has a larger t. Retakes (v >= 2) carry the real t, so the newest
-- retake wins. Nothing may read a month record's rec.t as a time; use d.savedAt. Two saves in
-- the same second with the same char tie on (v, t, char) and can still diverge briefly.
function C:MaybeSaveMonth(ledger, now)
  if not self:_isOfficer() then return false end
  local tz = self:Tz() or self.compat:ServerOffset() or 0
  local y, m = ns.Scoring.MonthKey(now, tz):match("^(%d+)-(%d+)$")
  y, m = tonumber(y), tonumber(m)
  local due = {}
  for _ = 1, MAX_CATCHUP do
    m = m - 1
    if m < 1 then y, m = y - 1, 12 end
    local ym = string.format("%04d-%02d", y, m)
    local from, monthEnd = ns.Scoring.MonthRange(ym, tz)
    if from < now - RETENTION or self.set:Get("month:" .. ym) then break end
    if now >= monthEnd + GRACE then table.insert(due, 1, { ym = ym, anchor = monthEnd + GRACE }) end
  end
  local saved = false
  for _, e in ipairs(due) do
    local d = self:_monthData(e.ym, ledger, now)
    -- A month with no activity is not frozen: the ledger may simply not have synced yet.
    if #d.overall > 0 or d.goldKept > 0 then
      if self:_publish("month:" .. e.ym, d, nil, 2 * e.anchor - now) then saved = true end
    end
  end
  return saved
end

-- Deliberate re-save of a stored month; the caller confirms with the officer first.
function C:RetakeMonth(ym, ledger)
  if not self:_can("retake") then return false, REFUSED end
  if not self:Month(ym) then return false, "no such month" end
  local old = self:Month(ym)
  local d = self:_monthData(ym, ledger, self.now())
  d.retake = true
  local good = self:_publish("month:" .. ym, d)
  if good then
    self:_safeLogHistory("month", ym, { savedBy = old.savedBy, savedAt = old.savedAt },
      { savedBy = d.savedBy, savedAt = d.savedAt })
  end
  return good
end
