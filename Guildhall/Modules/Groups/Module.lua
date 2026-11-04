local ADDON, ns = ...

-- Groups module: builds the group finder services at login and wires their events. Loads after the
-- Leaderboard module (its services use the Leaderboard observations and core.config, and the tabs read
-- Exchange, Leaderboard, Groups, Log, Settings, About) and before Boot, which registers the events.
--
-- Global: ns.groups = { svc, kills, credit, checklist, flex, calendar, reminders }, set at login, cleared
-- on halt. Without the Leaderboard (its login failed) Groups does not start.
-- Events fired: "GroupsChanged" (posts, signups or Ready now changed, or the party changed), coalesced.
-- The tab and settings builders (ns.Groups.View.Build, ns.Groups.SettingsView.Build) are looked up when
-- the tab is built, not at file load; until they exist a plain label shows.
ns.Groups = ns.Groups or {}

local KICK_EVERY = 60  -- a new verified kill restarts the core.config sync at most once a minute
local CAL_DELAY = 2    -- CALENDAR_UPDATE_EVENT_LIST bursts are read once

local function comingSoon(parent)
  local text = ns.UI.Text(parent, "GameFontDisable", "Groups coming soon")
  text:SetPoint("TOPLEFT", 0, 0)
  return {}
end

local function lazyBuild(name)
  return function(parent)
    local view = ns.Groups[name]
    if view and type(view.Build) == "function" then return view.Build(parent) end
    return comingSoon(parent)
  end
end

-- Coalesces bursts of fn into one call `delay` s later (on the guarded timer of g).
local function coalesce(g, key, delay, fn)
  if g.pending[key] then return end
  g.pending[key] = true
  g.after(delay, function()
    g.pending[key] = nil
    fn()
  end)
end

local function changed(g)
  coalesce(g, "changed", 1, function()
    if ns.Events then ns.Events:Fire("GroupsChanged") end
  end)
end

-- New verified kills ------------------------------------------------------------------------
-- core.config records from a raid leader (checklists) are checked against the raid leaders of
-- verified kills; one that arrived before its kill was verified was rejected. A newly verified kill
-- offers them again by restarting the config sync.

local function verifiedIds(observations)
  local ids = {}
  for _, k in ipairs(ns.Groups.Credit.Verified(observations:List("kill"))) do
    if k.id ~= nil then ids[k.id] = true end
  end
  return ids
end

local function kick(g)
  local now = g.now()
  if g.lastKick and now - g.lastKick < KICK_EVERY then
    if not g.kickQueued then
      g.kickQueued = true
      g.after(g.lastKick + KICK_EVERY - now, function()
        g.kickQueued = false
        kick(g)
      end)
    end
    return
  end
  g.lastKick = now
  g.config.sync:Start()
end

local function checkKills(g)
  local ids, new = verifiedIds(g.observations), false
  for id in pairs(ids) do
    if not g.verified[id] then new = true end
  end
  g.verified = ids
  if new then kick(g) end
end

ns.Events:On("ObservationsChanged", function()
  local g = ns.groups
  if g then coalesce(g, "kills", 1, function() checkKills(g) end) end
end)

-- Login -------------------------------------------------------------------------------------

local function build(n, s)
  local lb = n.leaderboard
  if not lb then return end
  local G = n.Groups
  local observations, config = lb.observations, lb.realConfig or lb.config
  local perms = lb.realPermissions or lb.permissions
  local personal = GuildhallDB.personal
  G.Reminders.Defaults(personal)
  local db = n.DB.Module(GuildhallDB, s.guildKey, "Groups")

  local g = { pending = {}, now = s.now, observations = observations, config = config }
  -- timers of this module stop with a halt (or a rebuilt ns.groups)
  g.after = function(delay, cb)
    s.after(delay, function() if n.groups == g and not s.halted then cb() end end)
  end

  local svc = G.Create({
    compat = s.compat, comm = s.comm, now = s.now, after = s.after, random = s.random, log = s.log,
    profile = s.profile, roster = s.roster, playerChar = s.playerChar, moduleDb = db, syncs = s.syncs,
    observations = observations, onChange = function() changed(g) end,
  })
  local kills = G.KillWatch.new({ compat = s.compat, observations = observations, now = s.now, after = g.after })
  local creditCtx = { observations = observations, config = config, compat = s.compat, now = s.now }
  local credit = G.Credit.new(creditCtx)
  G.Credit.Attach(creditCtx)
  local svcCtx = { config = config, observations = observations, compat = s.compat, now = s.now,
    playerChar = s.playerChar, profile = s.profile, perms = perms, db = db }
  local checklist = G.Checklist.new(svcCtx)
  local flex = G.Flex.new(svcCtx)
  local calendar = G.Calendar.new(svcCtx)
  local reminders = G.Reminders.new({
    groups = svc, profile = s.profile, now = s.now, after = g.after, personal = personal, db = db,
    playSound = function() s.compat:PlayReadyCheckSound() end,
  })
  g.svc, g.kills, g.credit, g.checklist, g.flex, g.calendar, g.reminders =
    svc, kills, credit, checklist, flex, calendar, reminders
  g.verified = verifiedIds(observations)
  g.instance = s.compat:InstanceKey()
  n.groups = g

  svc:Start()
  kills:OnZone()
  calendar:Refresh()
  reminders:Start()
end

-- If a constructor throws midway, drop the syncs already appended and report the error.
local function onLogin(n)
  local s = n.services
  if not s then return end
  local count = #s.syncs
  local ok, err = pcall(build, n, s)
  if ok then return end
  for i = #s.syncs, count + 1, -1 do s.syncs[i] = nil end
  if n.groups and n.groups.reminders then n.groups.reminders:Stop() end
  n.groups = nil
  n.Groups.Credit.Attach(nil)
  n.OnError(err)
end

-- Events ------------------------------------------------------------------------------------

local events = {}

events.ENCOUNTER_START = function(n, encounterId)
  if n.groups then n.groups.kills:OnEncounterStart(encounterId) end
end

events.ENCOUNTER_END = function(n, ...)
  if n.groups then n.groups.kills:OnEncounterEnd(...) end
end

events.BOSS_KILL = function(n, encounterId)
  if n.groups then n.groups.kills:OnBossKill(encounterId) end
end

-- Zoning: the kill watch notes the instance, entering a raid runs the checklist, and leaving an
-- instance re-reads the calendar (it can't be read inside one).
events.PLAYER_ENTERING_WORLD = function(n)
  local g = n.groups
  if not g then return end
  g.kills:OnZone()
  g.checklist:OnZone()
  local key = n.services.compat:InstanceKey()
  local was = g.instance
  g.instance = key
  if was ~= nil and key == nil then g.calendar:Refresh() end
end

events.READY_CHECK = function(n)
  if n.groups then n.groups.checklist:OnReadyCheck() end
end

-- Both are registered (Boot tolerates one missing on a client). One switch can fire both; Flex
-- answers only when the active group differs from the one it last read, so the second is a no-op.
local function specChanged(n)
  if n.groups then n.groups.flex:OnSpecChanged() end
end
events.ACTIVE_TALENT_GROUP_CHANGED = specChanged
events.PLAYER_TALENT_UPDATE = specChanged

events.CALENDAR_UPDATE_EVENT_LIST = function(n)
  local g = n.groups
  if g then coalesce(g, "calendar", CAL_DELAY, function() g.calendar:Refresh() end) end
end

events.GROUP_ROSTER_UPDATE = function(n)
  if n.groups then changed(n.groups) end
end

ns.RegisterModule("Groups", {
  OnLogin = onLogin,
  events = events,
  about = { title = "Group finder", order = 35, lines = {
    "Post or join guild runs, now or scheduled. Finished runs and raid nights count on the leaderboard.",
  } },
  tab = { title = "Groups", build = lazyBuild("View") },
  settings = { title = "Groups", build = lazyBuild("SettingsView") },
})
