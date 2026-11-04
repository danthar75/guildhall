local ADDON, ns = ...

-- Credit: turns "kill" observations (KillWatch) into leaderboard contributions for cleared
-- dungeons, raid bosses and full raid clears, and registers the six group activity types.
--
-- Verification: kills are sorted by (at, id) and clustered greedily, oldest first. A report joins a
-- cluster's oldest report (the seed) when it comes from a profile not yet in the cluster, names the
-- same instance and encounter, has `at` within 600 s of the seed and shares at least 2 member names
-- with it. A cluster with two or more profiles is verified. Reports of one profile never verify
-- each other.
-- Majority: a verified kill counts only when guild members (Roster:IsMember == true; an unknown
-- roster counts as non-guild) are more than half of the union of its members.
-- Credit (char = member Name-Realm; the Ledger resolves the profile), deduplicated at derivation
-- time, keeping the first in time order:
--   groups.dungeon   per guild member at a counted final dungeon kill, once per
--                    (char, instance, server day).
--   groups.raidboss  per guild member at a counted raid boss kill, once per (char, encounter, week).
--   groups.raidclear when the counted kills of a raid in one weekly reset period cover every boss in
--                    its table: the guild members at the completing kill, once per
--                    (char, instance, week). The covered set then starts again, so a second group
--                    clearing later the same week can complete it too.
-- Unverified kills (final dungeon bosses and raid bosses) emit counted = false rows with
-- why = "not verified", for the reporter's own chars among the members only, and only when that
-- char has no row for the same key yet.
-- ref: "kill:<seed obs id>:<char>:<type>".
--
-- Globals: ns.Groups.Credit.
ns.Groups = ns.Groups or {}
local Credit = {}
ns.Groups.Credit = Credit

local WINDOW = 600

for _, def in ipairs({
  { id = "groups.dungeon", label = "Dungeons cleared", unit = "count", verify = "paired", weight = 5, order = 80 },
  { id = "groups.raidboss", label = "Raid bosses killed", unit = "count", verify = "paired", weight = 3, order = 90 },
  { id = "groups.raidclear", label = "Full raid clears", unit = "count", verify = "paired", weight = 5, order = 100 },
  { id = "groups.prepared", label = "Raids prepared", unit = "count", verify = "confirmed", weight = 2, order = 110 },
  { id = "groups.flex", label = "Spec switches when asked", unit = "count", verify = "confirmed", weight = 1,
    order = 120 },
  { id = "groups.signedup", label = "Signed up and showed up", unit = "count", verify = "paired", weight = 1,
    order = 130 },
}) do
  ns.Activity.Register(def)
end

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end

-- A kill observation this module can use: known instance, encounter of that instance, members.
local function usable(rec)
  if type(rec) ~= "table" or type(rec.by) ~= "string" or type(rec.d) ~= "table" then return false end
  local d = rec.d
  if d.kind ~= "kill" or not finite(d.at) or type(d.members) ~= "table" then return false end
  local entry = ns.Instances.Get(d.instance)
  return entry ~= nil and ns.Instances.ByEncounter(d.encounter) == entry
end

local function sharedNames(a, b)
  local set, n = {}, 0
  for _, name in ipairs(a) do set[name] = true end
  for _, name in ipairs(b) do
    if set[name] then n, set[name] = n + 1, nil end
  end
  return n
end

local function addUnique(list, seen, v)
  if type(v) == "string" and not seen[v] then seen[v] = true; list[#list + 1] = v end
end

local function build(reports)
  local seed = reports[1].d
  local members, mseen, leaders, lseen, reporters = {}, {}, {}, {}, {}
  for _, r in ipairs(reports) do
    reporters[#reporters + 1] = r.by
    for _, n in ipairs(r.d.members) do addUnique(members, mseen, n) end
    addUnique(leaders, lseen, r.d.leader)
    if type(r.d.assists) == "table" then
      for _, n in ipairs(r.d.assists) do addUnique(leaders, lseen, n) end
    end
  end
  return { id = reports[1].id, instance = seed.instance, encounter = seed.encounter, at = seed.at,
    members = members, leaders = leaders, reporters = reporters, reports = reports,
    verified = #reports >= 2 }
end

-- Every cluster (verified or not), in time order of its seed.
function Credit.Clusters(kills)
  local recs = {}
  for _, rec in ipairs(kills or {}) do
    if usable(rec) then recs[#recs + 1] = rec end
  end
  table.sort(recs, function(a, b)
    if a.d.at ~= b.d.at then return a.d.at < b.d.at end
    return tostring(a.id) < tostring(b.id)
  end)
  local used, out = {}, {}
  for i, seed in ipairs(recs) do
    if not used[i] then
      used[i] = true
      local sd, reports, by = seed.d, { seed }, { [seed.by] = true }
      for j = i + 1, #recs do
        local r = recs[j]
        local d = r.d
        if d.at - sd.at > WINDOW then break end
        if not used[j] and not by[r.by] and d.instance == sd.instance and d.encounter == sd.encounter
            and sharedNames(sd.members, d.members) >= 2 then
          used[j], by[r.by] = true, true
          reports[#reports + 1] = r
        end
      end
      out[#out + 1] = build(reports)
    end
  end
  return out
end

-- Verified kills: { id, instance, encounter, at, members, leaders, reporters, reports }.
function Credit.Verified(kills)
  local out = {}
  for _, k in ipairs(Credit.Clusters(kills)) do
    if k.verified then out[#out + 1] = k end
  end
  return out
end

-- The guild members of a kill, and whether they are more than half of its members.
function Credit.GuildMembers(kill, roster)
  local list = {}
  for _, n in ipairs(kill.members) do
    if roster and roster.IsMember and roster:IsMember(n) == true then list[#list + 1] = n end
  end
  return list, #list > #kill.members / 2
end

local function clockOf(ctx)
  local now = ctx and ctx.now
  if type(now) == "function" then now = now() end
  return ns.Scoring.Clock(ctx and ctx.config, ctx and ctx.compat, finite(now) and now or 0)
end

function Credit.Derive(list, ctx)
  local clock = clockOf(ctx)
  local roster, profile = ctx and ctx.roster, ctx and ctx.profile
  local Scoring, Instances = ns.Scoring, ns.Instances
  local out, seen = {}, {}

  local function emit(typ, char, key, k, counted)
    local dk = typ .. "|" .. char .. "|" .. key
    if seen[dk] then return end
    seen[dk] = true
    out[#out + 1] = { type = typ, char = char, value = 1, at = k.at, counted = counted,
      why = (not counted) and "not verified" or nil,
      ref = "kill:" .. tostring(k.id) .. ":" .. char .. ":" .. typ }
  end

  local clusters = Credit.Clusters(list)
  local covered = {}
  -- Pass 1: verified kills with a guild majority, in time order.
  for _, k in ipairs(clusters) do
    if k.verified then
      local guild, majority = Credit.GuildMembers(k, roster)
      if majority then
        local entry, isFinal = Instances.ByEncounter(k.encounter)
        if entry.kind == "dungeon" then
          if isFinal then
            local key = k.instance .. "|" .. Scoring.DayKey(k.at, clock.tz)
            for _, ch in ipairs(guild) do emit("groups.dungeon", ch, key, k, true) end
          end
        else
          local week = Scoring.WeekStart(k.at, clock)
          for _, ch in ipairs(guild) do emit("groups.raidboss", ch, k.encounter .. "|" .. week, k, true) end
          local ck = k.instance .. "|" .. week
          local set = covered[ck] or {}
          covered[ck] = set
          set[k.encounter] = true
          local all = true
          for _, id in ipairs(entry.bosses) do
            if not set[id] then all = false; break end
          end
          if all then
            covered[ck] = {}
            for _, ch in ipairs(guild) do emit("groups.raidclear", ch, ck, k, true) end
          end
        end
      end
    end
  end
  -- Pass 2: unverified kills, for the reporter's own chars only.
  for _, k in ipairs(clusters) do
    if not k.verified then
      local rec = k.reports[1]
      local entry, isFinal = Instances.ByEncounter(k.encounter)
      local own = {}
      if type(rec.char) == "string" then own[rec.char] = true end
      if profile and profile.CharsOf then
        for _, ch in ipairs(profile:CharsOf(rec.by) or {}) do own[ch] = true end
      end
      for _, ch in ipairs(k.members) do
        if own[ch] then
          if entry.kind == "dungeon" then
            if isFinal then
              emit("groups.dungeon", ch, k.instance .. "|" .. Scoring.DayKey(k.at, clock.tz), k, false)
            end
          else
            emit("groups.raidboss", ch, k.encounter .. "|" .. Scoring.WeekStart(k.at, clock), k, false)
          end
        end
      end
    end
  end
  return out
end

ns.Activity.RegisterDeriver("kill", Credit.Derive)

-- Reads the kill observations of ctx.observations; ctx: { observations, config?, compat?, now }.
local C = {}
C.__index = C

function Credit.new(ctx)
  return setmetatable({ ctx = ctx }, C)
end

-- Set of chars that were leader or assistant in a verified kill of `instance` on server day dayKey.
function C:RaidLeaders(instance, dayKey)
  local ctx = self.ctx
  local clock = clockOf(ctx)
  local out = {}
  local kills = ctx.observations and ctx.observations:List("kill") or {}
  for _, k in ipairs(Credit.Verified(kills)) do
    if k.instance == instance and ns.Scoring.DayKey(k.at, clock.tz) == dayKey then
      for _, ch in ipairs(k.leaders) do out[ch] = true end
    end
  end
  return out
end

-- Module-level RaidLeaders(instance, dayKey) answers from the ctx last attached (wiring calls
-- Credit.Attach); before that it returns an empty set.
local attached

function Credit.Attach(ctx)
  attached = ctx and Credit.new(ctx) or nil
end

function Credit.RaidLeaders(instance, dayKey)
  if not attached then return {} end
  return attached:RaidLeaders(instance, dayKey)
end
