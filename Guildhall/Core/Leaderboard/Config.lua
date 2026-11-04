local ADDON, ns = ...

-- LbConfig: the small replicated set of officer-controlled Leaderboard settings.
--   "weights"       { weights = {[typeId]=0..1000}, tz = server offset seconds }  (newest version wins)
--   "month:YYYY-MM" frozen top-5 record of a finished month (first accepted wins; an officer
--                   retake, d.retake = true with a Greater version, replaces it)
--   "perms"         guild-rank permissions (ns.Permissions validates it: the author must be rank 0)
--   "exclude:<ref>" whether one bank contribution (ref "bank:<oldest observation id>") counts
--                   toward its member's score: { ref, excluded = bool, reason?, by = char, at }.
--                   Newest version wins (re-ticking publishes excluded = false); expires after 2
--                   years, which outlives the 400-day observations it points to.
--   "history:<profile>:<t>:<n>"  append-only log of one decision (a weights change, a month
--                   retake, a permissions change or a bank review): { what, key, before, after,
--                   by = char, at }. Never replaced (a second version is rejected); expires after
--                   2 years. n is a per-session counter.
-- Weights, retakes and bank reviews need the "weights" / "retake" / "bankreview" permission (guild
-- master only by default); the automatic month save stays an officer action. Record kinds are told
-- apart by the id-prefix dispatch in validateRecord. A record is checked against the roster and permissions
-- when it arrives, so a demoted author's earlier record stays in effect where it was already held.
-- An author missing from a loaded roster has left the guild: their weights, month, exclusion and
-- perms records are accepted ("author left the guild"), which is what clients that saw them earlier
-- already hold. An unknown roster rejects for now; Config re-syncs once the roster loads and
-- whenever a peer's perms record is accepted, so peers offer it again.
-- Version floor: seenV[id] is the highest version seen for an id, whatever the outcome, and a
-- publish uses at least seenV + 1, so a successor's record outranks a rejected one on every client.
-- Residual: an automatic month save (always v1) or an exclusion by a demoted author still in the
-- guild, that nobody re-saves, stays divergent; a retake or re-tick fixes it through the floor.
-- Sync buckets (bucket below): "c" for weights, perms and months; "x<YYYY-MM>" for exclusions and
-- "h<YYYY-MM>" for history, from the time in the id.
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
-- What a history record may describe.
local HISTORY_WHAT = { weights = true, month = true, perms = true, bank = true }
local MAX_REF, MAX_REASON = 48, 80
local EXCLUDE_FIELDS = { ref = true, excluded = true, reason = true, by = true, at = true }
local REFUSED = "no permission"
local LEFT = "author left the guild"
local MAX_SEEN = 512          -- version-floor entries kept
local MAX_V = 2 ^ 31          -- versions above this are not recorded in the floor

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
  if what == "bank" then return self.perms:Can(char, "bankreview") end
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

-- "unknown" while the roster is not loaded, "left" when a loaded roster does not list char,
-- "member" otherwise ("bad" for a non-string char).
local function authorStatus(roster, char)
  if type(char) ~= "string" then return "bad" end
  if roster == nil or roster.RankIndex == nil or (roster.HasRanks and roster:HasRanks() ~= true) then
    return "unknown"
  end
  if roster:RankIndex(char) == nil then return "left" end
  return "member"
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

-- "bank:" plus an observation id ("<profile hex>:o<time>_<n>", Observations _nextId).
local function validRef(ref)
  return type(ref) == "string" and #ref <= MAX_REF and ref:match("^bank:[%w:_]+$") ~= nil
end

-- A stored reason: nil, or 1..80 bytes with no surrounding whitespace.
local function validReason(r)
  return r == nil or (type(r) == "string" and #r >= 1 and #r <= MAX_REASON and ns.Util.Trim(r) == r)
end

-- A bank history side: only `excluded` and `reason`, each optional.
local function validBankState(x)
  if type(x) ~= "table" then return false end
  for k in pairs(x) do
    if k ~= "excluded" and k ~= "reason" then return false end
  end
  if x.excluded ~= nil and type(x.excluded) ~= "boolean" then return false end
  return validReason(x.reason)
end

local function validExclusion(self, rec)
  local ref = rec.id:match("^exclude:(.*)$")
  if not validRef(ref) then return false, "bad exclusion id" end
  local d = rec.d
  if type(d) ~= "table" then return false, "not a table" end
  for k in pairs(d) do
    if not EXCLUDE_FIELDS[k] then return false, "unknown exclusion field" end
  end
  if d.ref ~= ref then return false, "exclusion ref mismatch" end
  if type(d.excluded) ~= "boolean" then return false, "bad excluded" end
  if not validReason(d.reason) then return false, "bad reason" end
  if d.by ~= rec.char then return false, "exclusion author mismatch" end
  if not finite(d.at) or d.at ~= rec.t then return false, "bad exclusion time" end
  if rec.exp ~= rec.t + HISTORY_RETENTION then return false, "bad exclusion expiry" end
  -- Checked when the record arrives. An unknown roster rejects for now (a re-sync offers it again);
  -- an author a loaded roster does not list has left the guild and is accepted.
  local status = authorStatus(self.roster, rec.char)
  if status == "unknown" or status == "bad" then return false, "roster unknown" end
  if status == "left" then return true, LEFT end
  if not self.perms:Can(rec.char, "bankreview") then return false, "author lacks permission" end
  return true
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
  if d.what == "bank" then
    if not validRef(d.key) then return false, "bad key" end
    if not validBankState(d.before) or not validBankState(d.after) then return false, "bad bank change" end
    return true
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
  if id:sub(1, 8) == "exclude:" then return validExclusion(self, rec) end
  if id == "weights" then
    local status = authorStatus(self.roster, rec.char)
    if status == "unknown" or status == "bad" then return false, "roster unknown" end
    if status == "member" and not self.perms:Can(rec.char, "weights") then return false, "author lacks permission" end
    if type(rec.d) ~= "table" then return false, "not a table" end
    if not validTz(rec.d.tz) then return false, "bad tz" end
    if rec.d.changedBy ~= nil and (type(rec.d.changedBy) ~= "string" or #rec.d.changedBy > MAX_NAME) then
      return false, "bad changedBy"
    end
    if rec.d.changedAt ~= nil and not finite(rec.d.changedAt) then return false, "bad changedAt" end
    local ok, err = validWeights(rec.d.weights)
    if not ok then return false, err end
    return true, status == "left" and LEFT or nil
  end
  local ym = id:match("^month:(%d%d%d%d%-%d%d)$")
  if ym then
    local status = authorStatus(self.roster, rec.char)
    if status == "unknown" or status == "bad" then return false, "roster unknown" end
    local left = status == "left" and LEFT or nil
    if left then
      -- accepted below once the payload checks pass
    elseif type(rec.d) == "table" and rec.d.retake == true then
      if not self.perms:Can(rec.char, "retake") then return false, "author lacks permission" end
    elseif not canAdminister(self.roster, rec.char) then
      return false, "author not an officer"
    end
    local m = tonumber(ym:sub(6, 7))
    if m < 1 or m > 12 then return false, "bad month id" end
    local ok, err = validMonth(ym, rec.d)
    if not ok then return false, err end
    local old = self.set:Get(id)
    if rec.d.retake == true then
      -- A retake replaces a saved month, so it is never the first version.
      if rec.v < 2 then return false, "bad retake version" end
      return true, left
    end
    -- An automatic save is always version 1, and never replaces a retake.
    if rec.v ~= 1 or (old and type(old.d) == "table" and old.d.retake == true) then
      return false, "month already saved"
    end
    -- MaybeSaveMonth stamps t = 2 * anchor - now with now >= anchor (anchor = d.to + GRACE, and
    -- d.to is the month end it computed from the same tz), so an honest save has t <= anchor.
    if rec.t > rec.d.to + GRACE then return false, "bad save time" end
    return true, left
  end
  return false, "unknown record kind"
end

-- The ids the version floor tracks (history ids are fixed at v1 and exempt).
local function floorTracked(id)
  if id == "weights" or id == "perms" then return true end
  if id:match("^month:%d%d%d%d%-%d%d$") then return true end
  return validRef(id:match("^exclude:(.*)$")) == true
end

-- Sync bucket, deterministic per id (rec.t of a month changes between versions, so it is not
-- used). The time an exclusion or history id carries picks its month; anything malformed is "c".
local function monthOfIdTime(s)
  local T = tonumber(s)
  if not T or T < 0 or T >= MAX_V or not (ns.Scoring and ns.Scoring.MonthKey) then return nil end
  local ok, key = pcall(ns.Scoring.MonthKey, T, 0)
  return ok and type(key) == "string" and key or nil
end

function Config.Bucket(rec)
  local id = type(rec) == "table" and rec.id
  if type(id) ~= "string" then return "c" end
  local T = id:match("^exclude:bank:[^:]+:o(%d+)_%d+$")
  if T then
    local key = monthOfIdTime(T)
    return key and ("x" .. key) or "c"
  end
  T = id:match("^history:[^:]+:(%d+):%d+$")
  if T then
    local key = monthOfIdTime(T)
    return key and ("h" .. key) or "c"
  end
  return "c"
end

function Config.new(ctx)
  local self = setmetatable({}, C)
  self.ctx = ctx
  self.profile, self.log, self.now = ctx.profile, ctx.log, ctx.now
  self.roster, self.compat = ctx.roster, ctx.compat
  self.playerChar = ctx.playerChar
  self.historySeq = 0
  -- Version floor: id -> highest version seen and not held (persisted when ctx.seenV is given).
  self.seenV = ctx.seenV or {}
  self.rejectLogged = {} -- record identity -> true: a rejection is logged once per session
  self.hadRanks = ctx.roster ~= nil and ctx.roster.HasRanks ~= nil and ctx.roster:HasRanks() == true
  -- Permissions come through ctx (the Module builds them); a bare ctx gets its own.
  self.perms = ctx.perms or ns.Permissions.new({ roster = ctx.roster, profile = ctx.profile, now = ctx.now,
    compat = ctx.compat })
  if self.perms.config == nil then self.perms:Attach(self) end
  self.set = ns.ReplicatedSet.new(SET_NAME, ctx.db, {
    now = ctx.now, maxFuture = 86400,
    onChange = function() if ns.Events then ns.Events:Fire("LeaderboardConfigChanged") end end,
  })

  local function logApplied(rec, status, old, sender, reason)
    self:_noteVersion(rec)
    if status == "invalid" then
      -- the same record (id, v, t, author) re-offered at every sync is logged once
      local key = table.concat({ tostring(rec.id), tostring(rec.v), tostring(rec.t), tostring(rec.char) }, "\0")
      if self.rejectLogged[key] then return end
      self.rejectLogged[key] = true
    end
    local fromPeer = sender ~= (ctx.playerChar or "self")
    if status == "accepted" and rec.id == "perms" and fromPeer and self.sync then
      -- records rejected for lack of a permission this record grants are offered again
      self.sync:Start()
    end
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
    bucket = Config.Bucket,
    validate = function(rec) return validateRecord(self, rec) end,
    onApplied = logApplied,
  })
  ctx.syncs = ctx.syncs or {}
  ctx.syncs[#ctx.syncs + 1] = self.sync
  return self
end

function C:Start()
  self.set:Purge()
  self:_pruneSeen()
  self.sync:Start()
end

-- Records rec.v in the version floor when it is above what the set holds for that id.
function C:_noteVersion(rec)
  local id, v = rec.id, rec.v
  if type(id) ~= "string" or not finite(v) or v ~= math.floor(v) or v < 1 or v > MAX_V then return end
  if not floorTracked(id) then return end
  local held = self.set:Get(id)
  local seen = self.seenV
  if held and held.v >= v then
    if seen[id] ~= nil and seen[id] <= held.v then seen[id] = nil end
    return
  end
  if seen[id] ~= nil then
    if v > seen[id] then seen[id] = v end
    return
  end
  -- weights and perms are always tracked (two ids); the cap only bounds months and exclusions.
  if id == "weights" or id == "perms" then seen[id] = v return end
  local n = 0
  for k in pairs(seen) do if k ~= "weights" and k ~= "perms" then n = n + 1 end end
  if n < MAX_SEEN then seen[id] = v end
end

-- The publish time an exclusion id carries (from its observation id), or nil.
local function excludeIdTime(id)
  local t = id:match("^exclude:bank:.*:o(%d+)_%d+$")
  return t and tonumber(t) or nil
end

-- Drops floor entries the set has caught up with, or that are no longer tracked or valid.
function C:_pruneSeen()
  for id, v in pairs(self.seenV) do
    local held = type(id) == "string" and self.set:Get(id)
    local xt = type(id) == "string" and excludeIdTime(id)
    if type(id) ~= "string" or not floorTracked(id) or not finite(v) or (held and held.v >= v)
      or (xt and xt + HISTORY_RETENTION < self.now()) then
      self.seenV[id] = nil
    end
  end
end

-- The roster finished loading: records rejected as "roster unknown" are offered again.
function C:OnRosterRefreshed()
  local r = self.roster
  local has = r ~= nil and r.HasRanks ~= nil and r:HasRanks() == true
  local was = self.hadRanks
  self.hadRanks = has
  if has and not was then self.sync:Start() end
end

function C:_isOfficer() return canAdminister(self.roster, self.playerChar) end
function C:_can(key) return self.perms:Can(self.playerChar, key) end

-- exactV: publish at NextVersion without the version floor (automatic month saves are always v1).
function C:_publish(id, d, exp, t, exactV)
  t = t or self.now()
  local v = self.set:NextVersion(id)
  if not exactV then v = math.max(v, (self.seenV[id] or 0) + 1) end
  local rec = { id = id, v = v, t = t, exp = exp or (t + MONTH_RETENTION),
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
    -- a hidden profile's name is not written into the synced record; the View shows "(hidden)"
    local hidden = self.profile.IsHidden ~= nil and self.profile:IsHidden(e.profile) == true
    out[i] = { profile = e.profile, name = hidden and "" or Config._displayName(self.profile, e.profile),
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
      if self:_publish("month:" .. e.ym, d, nil, 2 * e.anchor - now, true) then saved = true end
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

-- Bank review --------------------------------------------------------------------------

-- The first n bytes of s, never ending inside a UTF-8 sequence.
local function cutBytes(s, n)
  if #s <= n then return s end
  local i = n
  -- a continuation byte at i + 1 means byte i's character goes on past the cut
  while i > 0 and (s:byte(i + 1) or 0) >= 128 and (s:byte(i + 1) or 0) < 192 do i = i - 1 end
  return s:sub(1, i)
end

local function exclusionData(self, ref)
  local d = liveData(self, "exclude:" .. ref)
  if d and d.excluded == true then return d end
  return nil
end

-- Excludes (excluded = true) or counts again one bank contribution, and logs the change.
-- reason is trimmed and cut to 80 bytes; an empty one, or any reason when counting again, is nil.
-- Setting what is already stored publishes nothing and returns true.
function C:SetExcluded(ref, excluded, reason)
  if not self:_can("bankreview") then return false, REFUSED end
  if not validRef(ref) then return false, "bad ref" end
  if type(excluded) ~= "boolean" then return false, "bad excluded" end
  if excluded and type(reason) == "string" then
    reason = ns.Util.Trim(cutBytes(ns.Util.Trim(reason), MAX_REASON))
    if reason == "" then reason = nil end
  else
    reason = nil
  end
  local cur = exclusionData(self, ref)
  local was = { excluded = cur ~= nil, reason = cur and cur.reason or nil }
  if was.excluded == excluded and was.reason == reason then return true end
  local t = self.now()
  local good = self:_publish("exclude:" .. ref,
    { ref = ref, excluded = excluded, reason = reason, by = self.playerChar, at = t },
    t + HISTORY_RETENTION, t)
  if good then
    local b, a = {}, {}
    if was.excluded ~= excluded then b.excluded, a.excluded = was.excluded, excluded end
    if was.reason ~= reason then b.reason, a.reason = was.reason, reason end
    self:_safeLogHistory("bank", ref, b, a)
  end
  return good, (not good) and "not accepted" or nil
end

-- The bank contributions currently excluded: { [ref] = { excluded = true, reason, by, at } }.
-- The Ledger calls this on every Query, so it walks the store unsorted.
function C:Exclusions()
  local out, now = {}, self.now()
  for id, rec in pairs(self.set.store) do
    local ref = type(id) == "string" and id:match("^exclude:(.+)$")
    local d = rec.d
    if ref and not rec.del and type(d) == "table" and d.excluded == true and rec.exp > now then
      out[ref] = { excluded = true, reason = d.reason, by = d.by, at = d.at }
    end
  end
  return out
end
