local ADDON, ns = ...

-- Leaderboard module: builds the Leaderboard objects at login from ns.services and wires their
-- events. Loads after the Exchange files (so the tab reads Exchange, Leaderboard, Log, Settings)
-- and before Boot, which registers the events declared here.
--
-- Global: ns.leaderboard = { observations, ledger, config, bank }, set at login, cleared on halt.
-- Also sets ns.services.observations (Exchange and DealWatch read it).
-- The tab and settings builders (ns.Leaderboard.View.Build, ns.Leaderboard.SettingsView.Build)
-- are looked up when the tab is built, not at file load; until they exist a plain label shows.
ns.Leaderboard = ns.Leaderboard or {}

local SETTLE = 90 -- seconds after login before the first sync exchange can be assumed done

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
  if lb then lb.ledger:Invalidate() end
end
-- Observations, config (weights, months, exclusions) and the roster all feed the ledger.
ns.Events:On("ObservationsChanged", invalidate)
ns.Events:On("LeaderboardConfigChanged", invalidate)
ns.Events:On("RosterRefreshed", invalidate)

-- Waits for the first sync exchange (Sync exposes no completion signal, so a fixed delay), then
-- lets an officer client refresh the tz and freeze finished months.
local function scheduleOfficerWork(s)
  s.after(SETTLE, function()
    local lb = ns.leaderboard
    if not lb or ns.services ~= s or s.roster:IsOfficer(s.playerChar) ~= true then return end
    local ok, err = pcall(lb.config.MaybeRefreshTz, lb.config)
    if not ok then ns.OnError(err) end
    ok, err = pcall(lb.config.MaybeSaveMonth, lb.config, lb.ledger, s.now())
    if not ok then ns.OnError(err) end
  end)
end

local function onLogin(n)
  local s = n.services
  if not s then return end
  local db = n.DB.Module(GuildhallDB, s.guildKey, "Leaderboard")
  db.observations = db.observations or {}
  db.config = db.config or {}

  local observations = n.Observations.New({
    comm = s.comm, profile = s.profile, log = s.log, now = s.now, after = s.after, random = s.random,
    playerChar = s.playerChar, db = db.observations, syncs = s.syncs,
  })
  s.observations = observations
  local config = n.LbConfig.new({
    comm = s.comm, compat = s.compat, roster = s.roster, profile = s.profile, log = s.log, now = s.now,
    after = s.after, random = s.random, playerChar = s.playerChar, db = db.config, syncs = s.syncs,
  })
  local ledger = n.Ledger.new({ observations = observations, profile = s.profile, roster = s.roster, now = s.now })
  local bank = n.Bank.new({
    compat = s.compat, observations = observations, profile = s.profile, roster = s.roster,
    now = s.now, after = s.after, moduleDb = db,
  })
  n.leaderboard = { observations = observations, ledger = ledger, config = config, bank = bank }

  observations:Start()
  config:Start()
  if n.exchange then n.exchange:AttachObservations(observations) end
  scheduleOfficerWork(s)
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

ns.RegisterModule("Leaderboard", {
  OnLogin = onLogin,
  events = events,
  tab = { title = "Leaderboard", build = lazyBuild("View") },
  settings = { title = "Leaderboard", build = lazyBuild("SettingsView") },
})
