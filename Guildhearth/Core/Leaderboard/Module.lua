local ADDON, ns = ...

-- Leaderboard module: builds the Leaderboard objects at login from ns.services and wires their
-- events. Loads after the Exchange files (so the tab reads Exchange, Leaderboard, Log, Settings)
-- and before Boot, which registers the events declared here.
--
-- Global: ns.leaderboard = { observations, ledger, config, bank, permissions }, set at login,
-- cleared on halt. permissions is the ns.Permissions object Config checks weights and retakes with.
-- Also sets ns.services.observations (Exchange and DealWatch read it).
-- The tab and settings builders (ns.Leaderboard.View.Build, ns.Leaderboard.SettingsView.Build)
-- are looked up when the tab is built, not at file load; until they exist a plain label shows.
ns.Leaderboard = ns.Leaderboard or {}

-- The officer work waits for sync to go quiet: first check SETTLE s after login, then every
-- QUIET_STEP s for up to QUIET_WINDOW s. It runs once observations have not changed for QUIET s
-- and Comm's send queue is empty; if that never happens, it is skipped this session.
local SETTLE, QUIET_STEP, QUIET_WINDOW, QUIET = 90, 30, 900, 60

local function comingSoon(parent)
  local text = ns.UI.Text(parent, "GameFontDisable", "Leaderboard coming soon")
  text:SetPoint("TOPLEFT", 0, 0)
  return {}
end

local function lazyBuild(name)
  return function(parent)
    local view = ns.Leaderboard[name]
    if view and type(view.Build) == "function" then return view.Build(parent) end
    return comingSoon(parent)
  end
end

local function invalidate()
  local lb = ns.leaderboard
  if lb then
    lb.ledger:Invalidate()
    if lb.realLedger then lb.realLedger:Invalidate() end
  end
end
-- The cached Contributions depend on observations and profiles (the Deals and Bank derivers read
-- ctx.observations and ctx.profile), and, for the group kill deriver, on guild membership (the
-- majority rule) and the server tz (server day and week). Ranks, tabs, profile links and
-- exclusions are applied in Ledger:Query.
ns.Events:On("ObservationsChanged", invalidate)
ns.Events:On("ProfilesChanged", invalidate)
ns.Events:On("RosterRefreshed", invalidate)
ns.Events:On("LeaderboardConfigChanged", invalidate)

-- Once the roster loads, records rejected as "roster unknown" are asked for again.
ns.Events:On("RosterRefreshed", function()
  local lb = ns.leaderboard
  local config = lb and (lb.realConfig or lb.config)
  if config and config.OnRosterRefreshed then config:OnRosterRefreshed() end
end)

-- Lets an officer or weights-holder client refresh the tz and freeze finished months (each
-- method checks its own condition).
-- Always runs on the real config and ledger: while /gh lbdemo is on, ns.leaderboard holds the
-- demo ones (lb.realConfig / lb.realLedger are the real ones), and demo data must never be saved.
function ns.Leaderboard.RunOfficerWork(s)
  local lb = ns.leaderboard
  if not lb or ns.services ~= s then return end
  local perms = lb.realPermissions or lb.permissions
  local allowed = s.roster:IsOfficer(s.playerChar) == true
    or (perms ~= nil and perms:Can(s.playerChar, "weights") == true)
  if not allowed then return end
  local config, ledger = lb.realConfig or lb.config, lb.realLedger or lb.ledger
  local ok, err = pcall(config.MaybeRefreshTz, config)
  if not ok then ns.OnError(err) end
  ok, err = pcall(config.MaybeSaveMonth, config, ledger, s.now())
  if not ok then ns.OnError(err) end
end

-- Sync exposes no completion signal, so "quiet" stands in for it: an officer back from a break
-- must not freeze a month (the earliest save wins) before the missing observations arrive.
function ns.Leaderboard.ScheduleOfficerWork(s, observations)
  local start = s.now()
  local lastChanges, quietSince = observations.changes, start
  local function check()
    if s.halted or ns.services ~= s or not ns.leaderboard then return end
    local now = s.now()
    if observations.changes ~= lastChanges then lastChanges, quietSince = observations.changes, now end
    local pending = s.comm and s.comm.Pending and s.comm:Pending() or 0
    if now - quietSince >= QUIET and pending == 0 then
      ns.Leaderboard.RunOfficerWork(s)
      return
    end
    if now - start + QUIET_STEP <= SETTLE + QUIET_WINDOW then s.after(QUIET_STEP, check) end
  end
  s.after(SETTLE, check)
end

local function build(n, s)
  local db = n.DB.Module(GuildhearthDB, s.guildKey, "Leaderboard")
  db.observations = db.observations or {}
  db.config = db.config or {}
  db.configSeen = db.configSeen or {} -- core.config version floor (LbConfig seenV)

  local observations = n.Observations.New({
    comm = s.comm, profile = s.profile, log = s.log, now = s.now, after = s.after, random = s.random,
    playerChar = s.playerChar, db = db.observations, syncs = s.syncs,
  })
  local permissions = n.Permissions.new({ roster = s.roster, profile = s.profile, now = s.now, compat = s.compat })
  local config = n.LbConfig.new({
    comm = s.comm, compat = s.compat, roster = s.roster, profile = s.profile, log = s.log, now = s.now,
    after = s.after, random = s.random, playerChar = s.playerChar, db = db.config, syncs = s.syncs,
    perms = permissions, seenV = db.configSeen,
  })
  -- config: the ledger reads the bank review's exclusions from it on every Query
  -- compat: derivers build the server clock (Scoring.Clock) from config and compat
  local ledger = n.Ledger.new({ observations = observations, profile = s.profile, roster = s.roster, now = s.now,
    config = config, compat = s.compat })
  local bank = n.Bank.new({
    compat = s.compat, observations = observations, profile = s.profile, roster = s.roster,
    now = s.now, moduleDb = db,
    -- the bank's re-read tick must not outlive a halt
    after = function(delay, cb)
      s.after(delay, function() if n.leaderboard and not s.halted then cb() end end)
    end,
  })
  s.observations = observations
  n.leaderboard = { observations = observations, ledger = ledger, config = config, bank = bank,
    permissions = permissions }

  observations:Start()
  config:Start()
  if n.exchange then n.exchange:AttachObservations(observations) end
  ns.Leaderboard.ScheduleOfficerWork(s, observations)
end

-- Bank open/close events go through Compat, which says whether one was a guild bank event.
local events = {}
for event, opens in pairs({ PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_HIDE = false,
  GUILDBANKFRAME_OPENED = true, GUILDBANKFRAME_CLOSED = false }) do
  events[event] = function(n, ...)
    local lb = n.leaderboard
    if not lb or not n.services.compat:HandleBankEvent(event, ...) then return end
    if opens then lb.bank:OnOpen() else lb.bank:OnClose() end
  end
end
events.GUILDBANKLOG_UPDATE = function(n)
  if n.leaderboard then n.leaderboard.bank:OnLogUpdate() end
end

-- If a constructor throws midway, drop the syncs already appended (a restriction lift would
-- otherwise start orphans) and report the error.
local function onLogin(n)
  local s = n.services
  if not s then return end
  local count = #s.syncs
  local ok, err = pcall(build, n, s)
  if ok then return end
  for i = #s.syncs, count + 1, -1 do s.syncs[i] = nil end
  n.leaderboard, s.observations = nil, nil
  n.OnError(err)
end

ns.RegisterModule("Leaderboard", {
  OnLogin = onLogin,
  events = events,
  about = { title = "Leaderboard", order = 30, lines = {
    "The gold your guild kept, plus who's contributing, from verified Exchange deals and guild bank donations.",
  } },
  tab = { title = "Leaderboard", build = lazyBuild("View") },
  settings = { title = "Leaderboard", build = lazyBuild("SettingsView") },
})
