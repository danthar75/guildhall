local ADDON, ns = ...

-- KillWatch: publishes one "kill" observation per boss kill from ENCOUNTER_END (success == 1), with
-- BOSS_KILL as a fallback when no ENCOUNTER_END follows within 5 s. Wiring registers the events and
-- calls OnEncounterStart / OnEncounterEnd / OnBossKill / OnZone / OnSpecChanged.
-- ctx: { compat, observations, now, after, random?, profile?, playerChar?, db? }. A secret value means
-- nothing is published.
-- Pending reports (Ruling F9): a report waiting out its random delay is also kept in
-- db.killPending[encounter] = { t = kill time, d, final, short }, so a logout or reload doesn't lose it.
-- Wiring calls Flush() on PLAYER_LOGOUT (publishes them at once) and Restore() at login (publishes
-- those under 600 s old that aren't covered yet, drops the rest).
--
-- Volume: every client of a 40-man raid would otherwise publish every boss. So
--   * a non-final dungeon boss kill expires after 2 days (Observations per-record exp): nothing
--     derives credit from it later; it only serves today's boss count and raid-leader checks;
--   * the group is snapshotted at the kill, but the report waits a random 0-30 s (ctx.random, on
--     ctx.after) and is then skipped when the store already holds, in one Credit cluster of that
--     kill, at least 3 reports from other linked profiles that list this player, and Credit's own
--     >= 2-report rule already confirms every member, the leader and every assistant this client
--     saw. Skipping then can't cost anyone credit. Without a profile service it always publishes.
ns.Groups = ns.Groups or {}
local KillWatch = {}
ns.Groups.KillWatch = KillWatch

local DEDUPE = 600
local FALLBACK = 5
local MAX_DUR = 21600
local MAX_STR, MAX_NAMES = 64, 40
local JITTER = 30          -- s, the longest random wait before publishing
local ENOUGH = 3           -- other reports that make ours unnecessary
local SHORT_EXP = 172800   -- 2 days, for non-final dungeon boss kills

local function isInt(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge and x == math.floor(x)
end

local function names(v, min)
  if type(v) ~= "table" then return false end
  local count = 0
  for _ in pairs(v) do count = count + 1 end
  if count ~= #v or count > MAX_NAMES or count < min then return false end
  for _, n in ipairs(v) do
    if type(n) ~= "string" or n == "" or #n > MAX_STR then return false end
  end
  return true
end

function KillWatch.Validate(d)
  local Instances = ns.Instances
  local entry = Instances and Instances.Get(d.instance)
  if not entry then return false, "bad instance" end
  if not isInt(d.encounter) then return false, "bad encounter" end
  local e, isFinal = Instances.ByEncounter(d.encounter)
  if e ~= entry then return false, "encounter not in instance" end
  if not names(d.members, 2) then return false, "bad members" end
  if d.leader ~= nil and (type(d.leader) ~= "string" or #d.leader > MAX_STR) then return false, "bad leader" end
  if d.assists ~= nil and not names(d.assists, 0) then return false, "bad assists" end
  if d.dur ~= nil then
    if not isInt(d.dur) or d.dur < 1 or d.dur > 86400 then return false, "bad dur" end
    if not isFinal then return false, "dur on non-final" end
  end
  for k in pairs(d) do
    if k ~= "kind" and k ~= "instance" and k ~= "encounter" and k ~= "members" and k ~= "leader"
      and k ~= "assists" and k ~= "dur" and k ~= "at" then
      return false, "bad field: " .. k
    end
  end
  return true
end

if ns.Observations and ns.Observations.AddKind then
  ns.Observations.AddKind("kill", KillWatch.Validate, { fields = { members = true, assists = true } })
end

local W = {}
W.__index = W

function KillWatch.new(ctx)
  local self = setmetatable({ ctx = ctx, started = {}, ended = {}, done = {}, pending = {}, mapId = nil }, W)
  if type(ctx.db) == "table" then
    ctx.db.killPending = type(ctx.db.killPending) == "table" and ctx.db.killPending or {}
    self.saved = ctx.db.killPending
  else
    self.saved = {}
  end
  return self
end

-- Records the first sighting of this instance this session.
function W:_mark(key)
  if key ~= nil and self.started[key] == nil then self.started[key] = self.ctx.now() end
end

function W:OnZone()
  local key = self.ctx.compat:InstanceKey()
  if key ~= self.curKey then
    if self.curKey ~= nil then self.started[self.curKey] = nil end
    self.curKey = key
  end
  self:_mark(key)
end

function W:OnSpecChanged() end   -- spec switches are handled by Flex:OnSpecChanged

function W:OnEncounterStart(encounterId)
  local id = self.ctx.compat:Safe(encounterId)
  if type(id) ~= "number" then return end
  local key = self.ctx.compat:InstanceKey()
  if key ~= nil and key ~= self.curKey then
    if self.curKey ~= nil then self.started[self.curKey] = nil end
    self.curKey = key
  end
  self:_mark(key)
end

local function setOf(list)
  local set = {}
  for _, n in ipairs(list or {}) do set[n] = true end
  return set
end

-- The random wait before publishing, 0..JITTER s.
function W:_jitter()
  local r = self.ctx.random or math.random
  local v = r(0, JITTER)
  if type(v) ~= "number" or v ~= v or v < 0 then return 0 end
  return math.min(v, JITTER)
end

-- True when the store already holds a Credit cluster of this kill (seed within 600 s) with at least
-- ENOUGH reports from other profiles listing this player, whose confirmed names include every member
-- of d and whose confirmed leaders include d's leader and assists: publishing d would add nothing.
function W:_covered(d)
  local ctx = self.ctx
  local profile, me = ctx.profile, ctx.playerChar
  local Credit = ns.Groups.Credit
  if type(me) ~= "string" or not (profile and profile.Id and profile.OwnerOf) or not (Credit and Credit.Clusters)
      or not (ctx.observations and ctx.observations.List) then
    return false
  end
  local myId = profile:Id()
  local recs = {}
  for _, rec in ipairs(ctx.observations:List("kill")) do
    local o = type(rec) == "table" and rec.d
    if type(o) == "table" and o.instance == d.instance and o.encounter == d.encounter and rec.by ~= myId then
      recs[#recs + 1] = rec
    end
  end
  if #recs < ENOUGH then return false end
  local want = { d.leader }
  for _, n in ipairs(d.assists or {}) do want[#want + 1] = n end
  for _, k in ipairs(Credit.Clusters(recs, profile)) do
    if math.abs(k.at - d.at) <= DEDUPE then
      local listing = 0
      for _, r in ipairs(k.reports) do
        if setOf(r.d.members)[me] then listing = listing + 1 end
      end
      if listing >= ENOUGH then
        local confirmed, leaders, all = setOf(k.confirmed), setOf(k.leaders), true
        for _, n in ipairs(d.members) do
          if not confirmed[n] then all = false; break end
        end
        for _, n in ipairs(want) do
          if not leaders[n] then all = false; break end
        end
        if all then return true end
      end
    end
  end
  return false
end

function W:_publish(id, entry, isFinal)
  local ctx = self.ctx
  local now = ctx.now()
  local last = self.done[id]
  if self.pending[id] or (last and now - last < DEDUPE) then return end
  local snap = ctx.compat:GroupSnapshot()
  if not snap then return end
  local d = { kind = "kill", instance = entry.key, encounter = id, members = snap.members,
    leader = snap.leader, assists = snap.assists, at = math.floor(now) }
  if isFinal then
    local t0 = self.started[entry.instanceId]
    local dur = t0 and math.floor(now - t0)
    if dur and dur >= 1 and dur <= MAX_DUR then d.dur = dur end
  end
  local entry_ = { t = now, d = d, final = isFinal == true, short = entry.kind == "dungeon" and not isFinal }
  self.saved[id] = entry_
  local token = {}
  self.pending[id] = token
  ctx.after(self:_jitter(), function()
    if self.pending[id] ~= token then return end -- flushed or restored meanwhile
    self:_finish(id, entry_)
  end)
end

-- Publishes one pending report unless it is covered, and clears it.
function W:_finish(id, p)
  local ctx = self.ctx
  self.pending[id], self.saved[id] = nil, nil
  local status
  if self:_covered(p.d) then
    status = "accepted"
  else
    local opts
    if p.short then opts = { exp = math.floor(ctx.now()) + SHORT_EXP } end
    status = ctx.observations:Publish(p.d, opts)
  end
  if status == "accepted" then
    self.done[id] = p.t
    local entry = ns.Instances.ByEncounter(id)
    if p.final and entry then self.started[entry.instanceId] = nil end
  end
  return status
end

-- PLAYER_LOGOUT: publishes every pending report now. Returns how many were sent.
function W:Flush()
  local n = 0
  local ids = {}
  for id in pairs(self.saved) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do
    local p = self.saved[id]
    if type(p) == "table" and type(p.d) == "table" and self:_finish(id, p) == "accepted" then n = n + 1 end
  end
  return n
end

-- At login: reports a previous session left pending are published when under 600 s old and not
-- covered; older or malformed ones are dropped. Returns how many were published.
function W:Restore()
  local now, n, ids = self.ctx.now(), 0, {}
  for id in pairs(self.saved) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do
    local p = self.saved[id]
    local ok = type(id) == "number" and type(p) == "table" and type(p.t) == "number" and type(p.d) == "table"
      and p.d.kind == "kill" and p.d.encounter == id and KillWatch.Validate(p.d) and now - p.t >= 0
      and now - p.t < DEDUPE
    if ok then
      local covered = self:_covered(p.d)
      if self:_finish(id, p) == "accepted" and not covered then n = n + 1 end
    else
      self.saved[id] = nil
    end
  end
  return n
end

function W:OnEncounterEnd(encounterId, name, difficulty, groupSize, success)
  local compat = self.ctx.compat
  local id, ok = compat:Safe(encounterId), compat:Safe(success)
  if type(id) ~= "number" then return end
  local entry, isFinal = ns.Instances.ByEncounter(id)
  if not entry then return end
  if ok ~= 1 then return end
  self.ended[id] = self.ctx.now()
  self:_publish(id, entry, isFinal)
end

function W:OnBossKill(encounterId)
  local ctx = self.ctx
  local id = ctx.compat:Safe(encounterId)
  if type(id) ~= "number" then return end
  local entry, isFinal = ns.Instances.ByEncounter(id)
  if not entry then return end
  local t = ctx.now()
  ctx.after(FALLBACK, function()
    local e = self.ended[id]
    if e and e >= t - FALLBACK then return end   -- ENCOUNTER_END handled it
    self:_publish(id, entry, isFinal)
  end)
end
