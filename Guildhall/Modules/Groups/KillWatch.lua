local ADDON, ns = ...

-- KillWatch: publishes one "kill" observation per boss kill from ENCOUNTER_END (success == 1), with
-- BOSS_KILL as a fallback when no ENCOUNTER_END follows within 5 s. Wiring registers the events and
-- calls OnEncounterStart / OnEncounterEnd / OnBossKill / OnZone / OnSpecChanged.
-- ctx: { compat, observations, now, after }. A secret value means nothing is published.
ns.Groups = ns.Groups or {}
local KillWatch = {}
ns.Groups.KillWatch = KillWatch

local DEDUPE = 600
local FALLBACK = 5
local MAX_STR, MAX_NAMES = 64, 40

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
  ns.Observations.AddKind("kill", KillWatch.Validate)
end

local W = {}
W.__index = W

function KillWatch.new(ctx)
  return setmetatable({ ctx = ctx, started = {}, ended = {}, done = {}, mapId = nil }, W)
end

-- Records the first sighting of this instance this session.
function W:_mark(key)
  if key ~= nil and self.started[key] == nil then self.started[key] = self.ctx.now() end
end

function W:OnZone()
  self:_mark(self.ctx.compat:InstanceKey())
end

function W:OnSpecChanged() end   -- Task 7

function W:OnEncounterStart(encounterId)
  local id = self.ctx.compat:Safe(encounterId)
  if type(id) ~= "number" then return end
  self:_mark(self.ctx.compat:InstanceKey())
end

function W:_publish(id, entry, isFinal)
  local ctx = self.ctx
  local now = ctx.now()
  local last = self.done[id]
  if last and now - last < DEDUPE then return end
  local snap = ctx.compat:GroupSnapshot()
  if not snap then return end
  local d = { kind = "kill", instance = entry.key, encounter = id, members = snap.members,
    leader = snap.leader, assists = snap.assists, at = math.floor(now) }
  if isFinal then
    local t0 = self.started[entry.instanceId]
    if t0 then d.dur = math.max(1, math.min(86400, math.floor(now - t0))) end
  end
  self.done[id] = now
  ctx.observations:Publish(d)
end

function W:OnEncounterEnd(encounterId, name, difficulty, groupSize, success)
  local compat = self.ctx.compat
  local id, ok = compat:Safe(encounterId), compat:Safe(success)
  if type(id) ~= "number" then return end
  local entry, isFinal = ns.Instances.ByEncounter(id)
  if not entry then return end
  self.ended[id] = self.ctx.now()
  if ok ~= 1 then return end
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
