local ADDON, ns = ...

-- Credit: turns "kill" observations (KillWatch) into leaderboard contributions for cleared
-- dungeons, raid bosses and full raid clears, and registers the six group activity types.
--
-- Reporters: a kill report counts only when its char is linked to the profile that sent it
-- (profile:OwnerOf(rec.char) == rec.by), so a made-up `by` or an unlinked char can't act as a
-- second reporter. Without a profile service no report counts.
-- Verification: kills are sorted by (at, id) and clustered greedily, oldest first. A report joins a
-- cluster's oldest report (the seed) when it comes from a profile not yet in the cluster, names the
-- same instance and encounter, has `at` within 600 s of the seed and shares at least 2 member names
-- with it. A cluster with two or more profiles is verified. Reports of one profile never verify
-- each other. A member is credited, and a leader or assistant counts for RaidLeaders, only when at
-- least 2 of the cluster's reporters list the name (one forged list can't add anyone).
-- Guild group (Ruling U1b, settings below): a raid kill on the guild calendar counts with any
-- group while "calendar" is on (the default). Any other kill counts only when EVERY report's own
-- member list passes "other": OFF (the default) every name on the list is a guild member
-- (Roster:IsMember == true; an unknown roster counts as non-guild); ON guild members are more than
-- half of the list's distinct names. Names a client couldn't read are absent and don't block. One
-- honest list therefore vetoes a forged list padded with guild names. A verified kill that isn't a
-- guild group gives uncounted rows, why = "not a guild group", to its reporters' own chars.
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
-- why = "not verified", for the reporter's own chars among the members only. Uncounted rows are
-- only emitted when that char has no row for the same key yet.
-- ref: "kill:<instance>:<encounter>:<server day (dungeon) or week start (raid)>:<char>:<type>",
-- from data every report of the cluster shares, so a late older report doesn't change it.
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

-- A kill observation this module can use: known instance, encounter of that instance, members,
-- and a reporter that owns the char it was sent from (a linked, consenting profile).
local function usable(rec, profile)
  if type(rec) ~= "table" or type(rec.by) ~= "string" or type(rec.char) ~= "string"
      or type(rec.d) ~= "table" then
    return false
  end
  local d = rec.d
  if d.kind ~= "kill" or not finite(d.at) or type(d.members) ~= "table" then return false end
  local entry = ns.Instances.Get(d.instance)
  if entry == nil or ns.Instances.ByEncounter(d.encounter) ~= entry then return false end
  return profile ~= nil and profile.OwnerOf ~= nil and profile:OwnerOf(rec.char) == rec.by
end

-- The profile service of a ctx (ctx.profile, else the config's).
local function profileOf(ctx)
  if type(ctx) ~= "table" then return nil end
  return ctx.profile or (type(ctx.config) == "table" and ctx.config.profile) or nil
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

-- Names listed by at least 2 of the reports (each report is a different profile), in order of
-- first appearance. listOf(report) -> array of names.
local function confirmedNames(reports, listOf)
  local order, seen, votes = {}, {}, {}
  for _, r in ipairs(reports) do
    local mine = {}
    for _, n in ipairs(listOf(r)) do
      if type(n) == "string" and not mine[n] then
        mine[n] = true
        votes[n] = (votes[n] or 0) + 1
        addUnique(order, seen, n)
      end
    end
  end
  local out = {}
  for _, n in ipairs(order) do
    if votes[n] >= 2 then out[#out + 1] = n end
  end
  return out
end

local function leadersOf(r)
  local list = {}
  if type(r.d.leader) == "string" then list[1] = r.d.leader end
  if type(r.d.assists) == "table" then
    for _, n in ipairs(r.d.assists) do list[#list + 1] = n end
  end
  return list
end

local function build(reports)
  local seed = reports[1].d
  local members, mseen, reporters = {}, {}, {}
  for _, r in ipairs(reports) do
    reporters[#reporters + 1] = r.by
    for _, n in ipairs(r.d.members) do addUnique(members, mseen, n) end
  end
  return { id = reports[1].id, instance = seed.instance, encounter = seed.encounter, at = seed.at,
    members = members, reporters = reporters, reports = reports, verified = #reports >= 2,
    confirmed = confirmedNames(reports, function(r) return r.d.members end),
    leaders = confirmedNames(reports, leadersOf) }
end

-- Every cluster (verified or not), in time order of its seed. profile: the profile service
-- (OwnerOf); reports whose char it doesn't link to their sender are left out.
function Credit.Clusters(kills, profile)
  local recs = {}
  for _, rec in ipairs(kills or {}) do
    if usable(rec, profile) then recs[#recs + 1] = rec end
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

-- Verified kills: { id, instance, encounter, at, members (union), confirmed, leaders, reporters,
-- reports }. confirmed and leaders hold only names that at least 2 reporters list (a single
-- forged list can't add anyone). profile: as Clusters.
function Credit.Verified(kills, profile)
  local out = {}
  for _, k in ipairs(Credit.Clusters(kills, profile)) do
    if k.verified then out[#out + 1] = k end
  end
  return out
end

-- Guild settings (Ruling U1b) -------------------------------------------------------------
-- core.config record "groupsettings" { calendar = bool, other = bool, by = author char, at = rec.t },
-- exp = t + 10 years, sync bucket "c", version floor. Only the guild master (rank 0) may change it;
-- on arrival an unknown roster rejects for now and an author who left the guild is accepted (the
-- Leaderboard's model, as for perms). Without a record: calendar ON, other OFF.
--   calendar  "Raids on the guild calendar count with non-guild players": a verified raid kill that
--             matches a guild calendar raid (synced "guildraid" notices of that instance from 2
--             linked profiles, start - 1800 <= kill.at <= start + 21600) needs no guild share; pugs earn nothing
--             anyway (they aren't Guildhearth users). OFF: calendar raids follow `other`.
--   other     "Other runs count with non-guild players" (dungeons, and raids not on the calendar):
--             OFF = every name on every report is a guild member; ON = a guild majority on every
--             report (I1).
-- A change writes a history entry what = "groups", key = "settings", before/after
-- { calendar, other }.
local SETTINGS_ID = "groupsettings"
local SETTINGS_RETENTION = 345600000 -- 10 years
local SETTINGS_FIELDS = { calendar = true, other = true, by = true, at = true }
local DEFAULTS = { calendar = true, other = false }
local CAL_BEFORE, CAL_AFTER = 1800, 21600

function Credit.ValidateSettings(config, rec)
  if rec.id ~= SETTINGS_ID then return false, "bad settings id" end
  local d = rec.d
  if type(d) ~= "table" then return false, "not a table" end
  for k in pairs(d) do if not SETTINGS_FIELDS[k] then return false, "unknown settings field" end end
  if type(d.calendar) ~= "boolean" or type(d.other) ~= "boolean" then return false, "bad setting" end
  if d.by ~= rec.char then return false, "settings author mismatch" end
  if not finite(d.at) or d.at ~= rec.t then return false, "bad settings time" end
  if rec.exp ~= rec.t + SETTINGS_RETENTION then return false, "bad settings expiry" end
  local Config = ns.LbConfig
  local status = Config.AuthorStatus(config.roster, rec.char)
  if status == "unknown" or status == "bad" then return false, "roster unknown" end
  if status == "left" then return true, Config.LEFT end
  if not config.perms:IsGuildMaster(rec.char) then return false, "author not the guild master" end
  return true
end

if ns.LbConfig and ns.LbConfig.AddRecordKind then
  ns.LbConfig.AddRecordKind(SETTINGS_ID, { validate = Credit.ValidateSettings, bucket = "c", floor = true })
end

-- The guild settings { calendar, other } (the defaults without a record or config).
function Credit.Settings(config)
  local set = type(config) == "table" and config.set
  local rec = type(set) == "table" and set.Get and set:Get(SETTINGS_ID) or nil
  local d = type(rec) == "table" and rec.del ~= true and type(rec.d) == "table" and rec.d or {}
  local out = {}
  for k, v in pairs(DEFAULTS) do
    if type(d[k]) == "boolean" then out[k] = d[k] else out[k] = v end
  end
  return out
end

-- Whether this client's player may change the settings (the guild master).
function Credit.CanSetSettings(config)
  return type(config) == "table" and config.perms ~= nil and config.perms:IsGuildMaster(config.playerChar) == true
end

-- Sets one setting ("calendar" or "other"). Returns true (also when unchanged) or false, reason.
function Credit.SetSetting(config, key, on)
  if DEFAULTS[key] == nil or type(on) ~= "boolean" then return false, "bad value" end
  if not Credit.CanSetSettings(config) then return false, "no permission" end
  local before = Credit.Settings(config)
  if before[key] == on then return true end
  local after = { calendar = before.calendar, other = before.other }
  after[key] = on
  local t = config.now()
  local ok, err = config:PublishChecked(SETTINGS_ID, { calendar = after.calendar, other = after.other,
    by = config.playerChar, at = t }, t + SETTINGS_RETENTION, t)
  if not ok then return false, err end
  config:_safeLogHistory("groups", "settings", before, after)
  return true
end

-- The rules a derivation uses: the settings plus the guild calendar raids seen in the synced
-- "guildraid" observations, by instance (start times). A raid counts only once notices of it come
-- from at least 2 distinct linked profiles (profile:OwnerOf(rec.char) == rec.by, Ruling F7), so one
-- member can't put a raid on the calendar alone. observations: anything with List(kind).
function Credit.Rules(config, observations, profile)
  local rules = Credit.Settings(config)
  local raids, by = {}, {}
  local list = observations and observations.List and observations:List("guildraid") or {}
  for _, rec in ipairs(list) do
    local d = type(rec) == "table" and rec.d
    if type(d) == "table" and d.kind == "guildraid" and finite(d.start) and type(d.instance) == "string"
        and type(rec.by) == "string" and type(rec.char) == "string"
        and profile ~= nil and profile.OwnerOf ~= nil and profile:OwnerOf(rec.char) == rec.by then
      local key = d.instance .. "|" .. d.start
      local set = by[key] or { n = 0 }
      by[key] = set
      if not set[rec.by] then
        set[rec.by] = true
        set.n = set.n + 1
        if set.n == 2 then
          raids[d.instance] = raids[d.instance] or {}
          raids[d.instance][#raids[d.instance] + 1] = d.start
        end
      end
    end
  end
  rules.raids = raids
  return rules
end

-- Whether a raid kill matches a guild calendar raid of its instance in rules.raids.
function Credit.OnCalendar(rules, kill)
  local starts = type(rules) == "table" and type(rules.raids) == "table" and rules.raids[kill.instance]
  if not starts then return false end
  local entry = ns.Instances.Get(kill.instance)
  if not entry or entry.kind ~= "raid" then return false end
  for _, start in ipairs(starts) do
    if kill.at >= start - CAL_BEFORE and kill.at <= start + CAL_AFTER then return true end
  end
  return false
end

local function isGuild(roster, n)
  return roster ~= nil and roster.IsMember ~= nil and roster:IsMember(n) == true
end

-- Whether one list is a guild group: mixed (the guild setting on) = guild members are more than
-- half of its distinct names; otherwise every name is a guild member. Names a client couldn't read
-- are simply not in the list.
local function guildList(names, roster, mixed)
  local seen, n, g = {}, 0, 0
  for _, name in ipairs(names or {}) do
    if type(name) == "string" and not seen[name] then
      seen[name] = true
      n = n + 1
      if isGuild(roster, name) then g = g + 1 end
    end
  end
  if n == 0 then return false end
  if mixed then return g > n / 2 end
  return g == n
end

-- The guild members a kill credits (confirmed names only), and whether it is a guild group. rules
-- (Credit.Rules; nil = the defaults with no calendar raids): a raid kill on the guild calendar
-- with rules.calendar needs no guild share; otherwise every report's own member list passes
-- guildList with mixed = rules.other (a kill without reports: its member list).
function Credit.GuildMembers(kill, roster, rules)
  rules = type(rules) == "table" and rules or DEFAULTS
  local list = {}
  for _, n in ipairs(kill.confirmed or {}) do
    if isGuild(roster, n) then list[#list + 1] = n end
  end
  if rules.calendar and Credit.OnCalendar(rules, kill) then return list, true end
  local mixed = rules.other == true
  local majority = true
  if type(kill.reports) == "table" and #kill.reports > 0 then
    for _, r in ipairs(kill.reports) do
      if not guildList(r.d and r.d.members, roster, mixed) then majority = false; break end
    end
  else
    majority = guildList(kill.members, roster, mixed)
  end
  return list, majority
end

local function clockOf(ctx)
  local now = ctx and ctx.now
  if type(now) == "function" then now = now() end
  return ns.Scoring.Clock(ctx and ctx.config, ctx and ctx.compat, finite(now) and now or 0)
end

function Credit.Derive(list, ctx)
  local clock = clockOf(ctx)
  local roster, profile = ctx and ctx.roster, profileOf(ctx)
  local rules = Credit.Rules(ctx and ctx.config, ctx and ctx.observations, profile)
  local Scoring, Instances = ns.Scoring, ns.Instances
  local out, seen = {}, {}

  -- key: "<instance or encounter>|<day or week>". The ref is built from data every report of the
  -- cluster shares, so it doesn't change when a late, older report joins the cluster.
  local function emit(typ, char, key, k, why, period)
    local dk = typ .. "|" .. char .. "|" .. key
    if seen[dk] then return end
    seen[dk] = true
    out[#out + 1] = { type = typ, char = char, value = 1, at = k.at, counted = why == nil, why = why,
      ref = "kill:" .. k.instance .. ":" .. tostring(k.encounter) .. ":" .. tostring(period) .. ":" .. char
        .. ":" .. typ }
  end

  -- dungeon or raidboss row (no row for a non-final dungeon boss)
  local function emitKill(char, k, why)
    local entry, isFinal = Instances.ByEncounter(k.encounter)
    if entry.kind == "dungeon" then
      if isFinal then
        local day = Scoring.DayKey(k.at, clock.tz)
        emit("groups.dungeon", char, k.instance .. "|" .. day, k, why, day)
      end
    else
      local week = Scoring.WeekStart(k.at, clock)
      emit("groups.raidboss", char, k.encounter .. "|" .. week, k, why, week)
    end
  end

  -- the reporters' own chars among the kill's members
  local function ownChars(k)
    local own, list = {}, {}
    for _, rec in ipairs(k.reports) do
      if type(rec.char) == "string" then own[rec.char] = true end
      if profile and profile.CharsOf then
        for _, ch in ipairs(profile:CharsOf(rec.by) or {}) do own[ch] = true end
      end
    end
    for _, ch in ipairs(k.members) do
      if own[ch] then list[#list + 1] = ch end
    end
    return list
  end

  local clusters = Credit.Clusters(list, profile)
  local covered = {}
  -- Pass 1: verified kills with a guild majority, in time order.
  for _, k in ipairs(clusters) do
    if k.verified then
      local guild, majority = Credit.GuildMembers(k, roster, rules)
      if majority then
        local entry = Instances.ByEncounter(k.encounter)
        for _, ch in ipairs(guild) do emitKill(ch, k, nil) end
        if entry.kind == "raid" then
          local week = Scoring.WeekStart(k.at, clock)
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
            for _, ch in ipairs(guild) do emit("groups.raidclear", ch, ck, k, nil, week) end
          end
        end
      end
    end
  end
  -- Pass 2: uncounted rows, for the reporters' own chars only: verified kills without a guild
  -- majority ("not a guild group") and unverified kills ("not verified").
  for _, k in ipairs(clusters) do
    local why
    if not k.verified then
      why = "not verified"
    elseif not select(2, Credit.GuildMembers(k, roster, rules)) then
      why = "not a guild group"
    end
    if why then
      for _, ch in ipairs(ownChars(k)) do emitKill(ch, k, why) end
    end
  end
  return out
end

ns.Activity.RegisterDeriver("kill", Credit.Derive)

-- Reads the kill observations of ctx.observations; ctx: { observations, profile, config?, compat?, now }.
local C = {}
C.__index = C

-- Bumped on ProfilesChanged: a newly linked char can verify a kill without a new observation.
local profileGen = 0
local RUN_GAP = 21600 -- kills of one instance less than 6 h apart are one run

function Credit.ProfilesChanged()
  profileGen = profileGen + 1
end

if ns.Events and ns.Events.On then ns.Events:On("ProfilesChanged", Credit.ProfilesChanged) end

function Credit.new(ctx)
  return setmetatable({ ctx = ctx }, C)
end

-- Index of verified kills by "<instance>|<server day>": leaders (leader or assistant) and members
-- (confirmed names), each named by at least 2 of the kill's reporters. Cached per
-- observations.changes, tz and ProfilesChanged; a store without a numeric `changes` is re-read on
-- every call.
function C:_dayIndex()
  local ctx = self.ctx
  local obs = ctx.observations
  local tz = clockOf(ctx).tz
  local changes = obs and obs.changes
  local cache = self.cache
  if not (cache and type(changes) == "number" and cache.changes == changes and cache.tz == tz
      and cache.gen == profileGen) then
    local byDay, members, bosses, runs = {}, {}, {}, {}
    for _, k in ipairs(Credit.Verified(obs and obs:List("kill") or {}, profileOf(ctx))) do
      -- attendance (AttendedIn) uses only kills that last: a non-final dungeon boss kill expires
      -- after 2 days, so credit derived from it would vanish
      local entry, isFinal = ns.Instances.ByEncounter(k.encounter)
      if entry.kind == "raid" or isFinal then
        local cset = {}
        for _, ch in ipairs(k.confirmed) do cset[ch] = true end
        runs[#runs + 1] = { kill = k, raid = entry.kind == "raid", confirmed = cset }
      end
      local key = k.instance .. "|" .. ns.Scoring.DayKey(k.at, tz)
      local set = byDay[key] or {}
      byDay[key] = set
      for _, ch in ipairs(k.leaders) do set[ch] = true end
      local mset = members[key] or {}
      members[key] = mset
      for _, ch in ipairs(k.confirmed) do mset[ch] = true end
      local bset = bosses[key] or {}
      bosses[key] = bset
      bset[k.encounter] = true
    end
    -- runs: an instance's kills chained with gaps under 6 h; r.first = the run's first kill
    local last = {}
    for _, r in ipairs(runs) do
      local k, prev = r.kill, last[r.kill.instance]
      r.first = (prev and k.at - prev.kill.at < RUN_GAP) and prev.first or k
      last[k.instance] = r
    end
    cache = { changes = changes, tz = tz, gen = profileGen, byDay = byDay, members = members, bosses = bosses,
      runs = runs }
    self.cache = cache
  end
  return cache
end

-- Cleared runs for the history (Ruling T10c), newest first: { instance, encounter, at, names, dur? }.
-- Only verified kills with a guild majority count. A dungeon is cleared by its last-boss kill (dur
-- = the longest `dur` its reports carry). A raid is cleared when every encounter in its bosses table
-- has such a kill within one weekly reset period (Scoring.WeekStart); the entry is the kill that
-- completed the set (its time and its guild members), and the set then starts again.
-- clock: a Scoring clock ({ tz, weekStart? }); defaults to { tz = 0 }. profile: as Clusters.
-- rules: Credit.Rules (nil = the defaults, no calendar raids).
function Credit.Clears(kills, roster, clock, profile, rules)
  clock = clock or { tz = 0 }
  local out, covered = {}, {}
  for _, k in ipairs(Credit.Verified(kills, profile)) do
    local entry, isFinal = ns.Instances.ByEncounter(k.encounter)
    local guild, majority = Credit.GuildMembers(k, roster, rules)
    if majority and entry.kind == "dungeon" and isFinal then
      local dur
      for _, r in ipairs(k.reports) do
        local v = r.d.dur
        if type(v) == "number" and v >= 1 and (dur == nil or v > dur) then dur = v end
      end
      out[#out + 1] = { instance = k.instance, encounter = k.encounter, at = k.at, names = guild, dur = dur }
    elseif majority and entry.kind == "raid" then
      local ck = k.instance .. "|" .. ns.Scoring.WeekStart(k.at, clock)
      local set = covered[ck] or {}
      covered[ck] = set
      set[k.encounter] = true
      local all = true
      for _, id in ipairs(entry.bosses) do
        if not set[id] then all = false; break end
      end
      if all then
        covered[ck] = {}
        out[#out + 1] = { instance = k.instance, encounter = k.encounter, at = k.at, names = guild }
      end
    end
  end
  table.sort(out, function(a, b) return a.at > b.at end)
  return out
end

local function copySet(src)
  local out = {}
  for ch in pairs(src or {}) do out[ch] = true end
  return out
end

-- Set of chars that were leader or assistant in a verified kill of `instance` on server day dayKey
-- (named so by at least 2 of its reporters). Returns a new table each call.
function C:RaidLeaders(instance, dayKey)
  return copySet(self:_dayIndex().byDay[tostring(instance) .. "|" .. tostring(dayKey)])
end

-- Set of chars credited as members (named by at least 2 reporters) of a verified kill of
-- `instance` on server day dayKey. Returns a new table each call.
function C:Attendees(instance, dayKey)
  return copySet(self:_dayIndex().members[tostring(instance) .. "|" .. tostring(dayKey)])
end

-- Attendance window around a confirmation, ask or event start: from 30 min before to 6 h after.
local ATTEND_BEFORE, ATTEND_AFTER = 1800, 21600

-- The earliest verified kill (Credit.Verified's table; read-only) of `instance` (nil = any raid) with
-- from <= kill.at <= to that credits `char` (named by at least 2 of its reporters), and the first
-- kill of its run (that instance's verified kills chained with gaps under 6 h), or nil.
-- Non-final dungeon boss kills never count (they expire after 2 days).
function C:AttendedIn(instance, char, from, to)
  if type(char) ~= "string" or not finite(from) or not finite(to) then return nil end
  for _, r in ipairs(self:_dayIndex().runs) do   -- in time order
    local k = r.kill
    if k.at > to then break end
    if k.at >= from and r.confirmed[char] and (k.instance == instance or (instance == nil and r.raid)) then
      return k, r.first
    end
  end
  return nil
end

-- The earliest verified kill of `instance` crediting `char` with kill.at in [at - 1800, at + 21600],
-- and the first kill of its run, or nil: a raider counts as present for a confirmation, ask or
-- signup at `at` when this returns a kill. Prepared and flex key "one per night" on the run (its
-- first kill, credited on that kill's server day, Ruling F4), so a raid that forms before midnight
-- and kills on both sides of it is one night.
function C:AttendedNear(instance, char, at)
  if not finite(at) then return nil end
  return self:AttendedIn(instance, char, at - ATTEND_BEFORE, at + ATTEND_AFTER)
end

-- How many different bosses of `instance` have a verified kill on server day dayKey.
function C:Bosses(instance, dayKey)
  local n = 0
  for _ in pairs(self:_dayIndex().bosses[tostring(instance) .. "|" .. tostring(dayKey)] or {}) do n = n + 1 end
  return n
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

-- Ruling F5, for local permission checks only (Flex:Ask, Checklist:Confirm and their buttons):
-- RaidLeaders(instance, dayKey) plus playerChar when the current group snapshot (Compat, nil- and
-- secret-safe) shows them as leader or assistant, so a raidlead-only assistant can act before the
-- night's first kill. The derivers still require a verified kill the author led.
function Credit.LiveLeaders(compat, playerChar, instance, dayKey)
  local set = Credit.RaidLeaders(instance, dayKey) or {}
  local snap = compat and compat.GroupSnapshot and compat:GroupSnapshot() or nil
  if type(playerChar) == "string" and type(snap) == "table" then
    local lead = snap.leader == playerChar
    for _, n in ipairs(type(snap.assists) == "table" and snap.assists or {}) do
      if n == playerChar then lead = true end
    end
    if lead then set[playerChar] = true end
  end
  return set
end
