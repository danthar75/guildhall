local ADDON, ns = ...

-- Event wiring. Loaded last. Every event handler runs inside pcall (errors go to ns.OnError),
-- all guild/roster data goes through Compat, and nothing here touches combat APIs.
local Boot = {}
ns.Boot = Boot

local PREFIX = "Guildhall"
local PROFILE_REFRESH = 7 * 86400 -- republish our profile when it expires within this window
local GUILD_RETRIES = 10           -- GuildKey retries, 1 s apart

local compat = ns.compat
local frame = CreateFrame("Frame")
local handlers = {}
local booted, resolving, noGuildNotified = false, false, false
local halted = false -- guild changed or left mid-session: services stopped until /reload
local profileSync

local function after(d, cb)
  if C_Timer and C_Timer.After then
    C_Timer.After(d, function()
      local ok, err = pcall(cb)
      if not ok then ns.OnError(err) end
    end)
  end
end

local function refreshUI()
  if ns.UI and ns.UI.Window then ns.UI.Window:Refresh() end
end

-- Tells modules the roster cache changed (the Leaderboard ledger resolves ranks from it).
local function rosterRefreshed()
  if ns.Events then ns.Events:Fire("RosterRefreshed") end
end

local function copy(t) return ns.Util.DeepCopy(t) end

local function charsOf(rec)
  local d = type(rec) == "table" and rec.d
  return type(d) == "table" and d.chars or nil
end

-- Profiles ---------------------------------------------------------------------

local function sameChars(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then return false end
  local seen = {}
  for _, c in ipairs(a) do seen[c] = true end
  for _, c in ipairs(b) do if not seen[c] then return false end end
  return true
end

local function logProfileApplied(log, now)
  return function(rec, status, old, sender, reason)
    local e = { t = now(), set = "profiles", id = rec.id, v = rec.v, author = rec.by,
      authorChar = rec.char, relayer = sender }
    if status == "accepted" then
      e.result, e.reason = "accepted", reason
      e.after = copy(charsOf(rec))
      if old then
        e.action, e.before = "profile-update", copy(charsOf(old))
      else
        e.action = "profile-link"
      end
    elseif status == "stale" then
      e.action, e.result = "ignored", "stale"
    else
      e.action, e.result, e.reason = "invalid", "rejected", reason or status
    end
    log:Add(e)
  end
end

-- A profile record is authored by itself (by == id) and carries a list of names.
local function validateProfile(rec)
  if rec.by ~= rec.id then return false, "author mismatch" end
  local chars = charsOf(rec)
  if type(chars) ~= "table" then return false, "malformed" end
  for _, c in ipairs(chars) do
    if type(c) ~= "string" then return false, "malformed" end
  end
  return true
end

-- Publishes our profile when it changed or is close to expiring. Requires consent.
function Boot.PublishProfile()
  local s = ns.services
  if not (s and profileSync) then return end
  local rec = s.profile:Record()
  if not rec then return end
  local stored = s.profileSet:Get(rec.id)
  if stored and not stored.del and sameChars(charsOf(stored), charsOf(rec))
    and type(stored.exp) == "number" and stored.exp - s.now() > PROFILE_REFRESH then
    return
  end
  profileSync:Publish(rec)
end

local function onConsentDone(excluded)
  ns.services.profile:Consent(excluded)
  Boot.PublishProfile()
  refreshUI()
end

-- Shows the consent dialog for characters not yet decided (used at login and by the
-- Exchange form when posting is blocked on consent).
function Boot.ShowConsent()
  local s = ns.services
  if not s or not s.profile:NeedsConsent() then return end
  ns.UI.Consent:Show(s.profile:PendingChars(), function(excluded) onConsentDone(excluded) end, nil, s.guildKey)
end

-- Re-asks for every known character in this guild (Settings "Change…").
function Boot.ChangeConsent()
  local s, p = ns.services, ns.UI.Personal()
  if not (s and p and p.profile and type(p.profile.chars) == "table") then return end
  local chars, names, excludedNow = p.profile.chars, s.profile:GuildChars(), {}
  for _, name in ipairs(names) do
    if chars[name].included == false then excludedNow[name] = true end
  end
  ns.UI.Consent:Show(names, function(excluded)
    -- Profile:Consent only decides pending characters, so mark them all pending first.
    for _, name in ipairs(names) do
      if type(chars[name]) == "table" then chars[name].included = nil end
    end
    onConsentDone(excluded)
  end, excludedNow, s.guildKey)
end

-- Services ---------------------------------------------------------------------

-- Roster:Refresh() always asks the server for a fresh roster; when we refresh *because*
-- GUILD_ROSTER_UPDATE fired, that request would trigger another update. This proxy lets
-- Boot suppress the request for event-driven refreshes.
local suppressRosterRequest = false
local rosterCompat = setmetatable({
  RequestRoster = function()
    if not suppressRosterRequest then compat:RequestRoster() end
  end,
}, { __index = compat })

local function buildServices(guildKey)
  local sv = GuildhallDB
  local now = function() return compat:Now() end
  local random = fastrandom or math.random
  local playerChar = compat:PlayerFullName()
  local g = ns.DB.Guild(sv, guildKey)
  local log = ns.Log.new(g.log, now)

  local comm = ns.Comm.new({
    compat = compat, now = now, after = after, playerName = playerChar, prefix = PREFIX,
    onIgnored = function(sender, reason)
      log:Add({ action = "ignored", result = "ignored", relayer = sender, reason = reason })
    end,
  })
  compat:RegisterPrefix(PREFIX)

  local roster = ns.Roster.new(rosterCompat, g.cache)
  g.sets.profiles = g.sets.profiles or {}
  -- Profile links decide who earns credit, so the Leaderboard ledger must rebuild when they change.
  -- Syncs apply records in bursts: coalesce to one event.
  local profilesChangedPending = false
  local profileSet = ns.ReplicatedSet.new("profiles", g.sets.profiles, { now = now, onChange = function()
    if profilesChangedPending then return end
    profilesChangedPending = true
    after(1, function()
      profilesChangedPending = false
      if ns.Events then ns.Events:Fire("ProfilesChanged") end
    end)
  end })
  local profile = ns.Profile.new({
    personal = sv.personal, set = profileSet, roster = roster, now = now, random = random,
    playerChar = playerChar, guildKey = guildKey,
    defaultRealm = GetNormalizedRealmName and GetNormalizedRealmName() or nil,
  })
  profileSync = ns.Sync.new({
    comm = comm, set = profileSet, module = "core.profiles", after = after, random = random,
    playerName = playerChar, validate = validateProfile, onApplied = logProfileApplied(log, now),
  })

  ns.services = {
    compat = compat, comm = comm, now = now, after = after, random = random, log = log,
    roster = roster, profile = profile, playerChar = playerChar, guildKey = guildKey,
    profileSet = profileSet, profileSync = profileSync,
    -- Every sync in the addon, the core profile sync first. Modules append theirs when they
    -- build it; restriction lifts walk this list.
    syncs = { profileSync },
    -- Only Exchange exists today, so Boot builds its DB here. A later refactor could hand
    -- each module its own ns.DB.Module(...) table instead of a shared field.
    moduleDb = ns.DB.Module(sv, guildKey, "Exchange"),
    templates = sv.personal.templates,
  }
end

-- Guild change -----------------------------------------------------------------------

-- Compares the current guild with the one we booted for. Returns "same", "changed" (with the
-- new key), "left" (no guild, readable) or "unknown" (no guild while restricted: the name
-- may just be secret, so never act on it).
function Boot.GuildState(c, bootedKey)
  local key = c:GuildKey()
  if key == bootedKey then return "same" end
  if key ~= nil then return "changed", key end
  if c:IsRestricted("Chat") or c:IsRestricted("Map") then return "unknown" end
  -- Guild info can take a while to load after a zone-in; only treat it as "left" once the
  -- client also says we're not in a guild.
  local inGuild = c.env and c.env.IsInGuild
  if inGuild and c:Safe(inGuild()) ~= false then return "unknown" end
  return "left"
end

-- Stops serving the old guild: no sync, no answers, no writes into its stores. A full rebuild
-- for the new guild is left to /reload.
local function halt(state, newKey)
  if halted then return end
  halted = true
  local s = ns.services
  if s then s.halted = true end
  if s and s.comm then s.comm:Halt() end
  profileSync = nil
  ns.exchange = nil
  ns.leaderboard = nil
  if state == "changed" then
    print("|cffffd200Guildhall|r: you changed guild. Type /reload to switch Guildhall to "
      .. ns.Util.DisplayName(newKey) .. ".")
  else
    print("|cffffd200Guildhall|r: you left your guild, so Guildhall has stopped. Type /reload to reset it.")
  end
  refreshUI()
end

-- Guild info can be briefly empty while it reloads, so a mismatch is confirmed 2 s later.
local guildCheckPending = false
local function checkGuild()
  if halted or not booted or guildCheckPending then return end
  local bootedKey = ns.services.guildKey
  local state = Boot.GuildState(compat, bootedKey)
  if state == "same" or state == "unknown" then return end
  guildCheckPending = true
  after(2, function()
    guildCheckPending = false
    local again, key = Boot.GuildState(compat, bootedKey)
    if again == "changed" or again == "left" then halt(again, key) end
  end)
end

-- Restriction lift -----------------------------------------------------------------

local liftPending = false
local function onRestrictionLifted()
  if liftPending or halted then return end
  liftPending = true
  after(0.5, function()
    liftPending = false
    local s = ns.services
    if not s or halted then return end
    s.comm:Pump()
    for _, sync in ipairs(s.syncs) do
      local ok, err = pcall(sync.Start, sync)
      if not ok then ns.OnError(err) end
    end
    s.roster:Refresh()
    rosterRefreshed()
    refreshUI()
  end)
end

local function watchRestrictions()
  if not C_RestrictedActions then return end -- Classic Era: no restrictions
  local ok = pcall(frame.RegisterEvent, frame, "ADDON_RESTRICTION_STATE_CHANGED")
  if ok then return end
  -- Event missing on this client: poll the Chat restriction instead.
  if not (C_Timer and C_Timer.NewTicker) then return end
  local was = compat:IsRestricted("Chat")
  C_Timer.NewTicker(5, function()
    local ok2, err = pcall(function()
      local is = compat:IsRestricted("Chat")
      if was and not is then onRestrictionLifted() end
      was = is
    end)
    if not ok2 then ns.OnError(err) end
  end)
end

-- Login --------------------------------------------------------------------------

local function start(guildKey)
  buildServices(guildKey)
  booted = true
  local s = ns.services
  -- Each core step is isolated so a failure in one still lets modules and sync start.
  local function step(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then ns.OnError(err) end
  end
  step(s.roster.Refresh, s.roster) -- Refresh also requests the roster from the server
  step(s.profile.SeeCharacter, s.profile, s.playerChar)
  step(function()
    if s.profile:NeedsConsent() then Boot.ShowConsent() else Boot.PublishProfile() end
  end)
  for _, name in ipairs(ns.Modules()) do
    local def = ns.GetModule(name)
    if type(def) == "table" and type(def.OnLogin) == "function" then
      local ok, err = pcall(def.OnLogin, ns)
      if not ok then ns.OnError(err) end
    end
  end
  step(profileSync.Start, profileSync)
  step(refreshUI)
end

-- One lookup. Returns true when there is nothing left to wait for.
local function attemptNow()
  if booted then return true end
  if type(GuildhallDB) ~= "table" then return false end
  local key = compat:GuildKey()
  if not key then return false end
  start(key)
  return true
end

-- Guild info loads late, so retry every second for up to GUILD_RETRIES seconds.
local function retryLoop(attempt)
  local ok, done = pcall(attemptNow)
  if not ok then
    resolving = false
    ns.OnError(done)
    return
  end
  if done then resolving = false; return end
  if attempt >= GUILD_RETRIES then
    resolving = false
    -- In an instance the guild name may just be secret: stay quiet; PLAYER_ENTERING_WORLD
    -- and roster updates keep retrying.
    if not noGuildNotified and not compat:IsRestricted("Map") and not compat:IsRestricted("Chat") then
      noGuildNotified = true
      print("|cffffd200Guildhall|r: you're not in a guild, so Guildhall is resting. Join a guild to use it.")
    end
    return
  end
  after(1, function() retryLoop(attempt + 1) end)
end

local function tryResolve()
  if booted or resolving then return end
  resolving = true
  retryLoop(1)
end

-- Roster updates are coalesced (they can fire in bursts).
local rosterPending = false
local function onRosterUpdate()
  if not booted then
    if resolving then attemptNow() else tryResolve() end
    return
  end
  if halted then return end
  checkGuild()
  if rosterPending then return end
  rosterPending = true
  after(1, function()
    rosterPending = false
    if halted then return end
    suppressRosterRequest = true
    local ok, err = pcall(ns.services.roster.Refresh, ns.services.roster)
    suppressRosterRequest = false
    if not ok then ns.OnError(err) end
    rosterRefreshed()
    refreshUI()
  end)
end

-- Mail -----------------------------------------------------------------------------

if StaticPopupDialogs then StaticPopupDialogs["GUILDHALL_MAIL_DRAFT"] = {
  text = "Fill in your Guildhall mail draft to %s?",
  button1 = "Fill in",
  button2 = "Later",
  button3 = "Dismiss",
  OnAccept = function(_, draft)
    local ok, err = pcall(function() if ns.exchange and draft then ns.exchange:FillDraft(draft) end end)
    if not ok then ns.OnError(err) end
  end,
  OnAlt = function(_, draft)
    local ok, err = pcall(function() if ns.exchange and draft then ns.exchange:DismissDraft(draft.id) end end)
    if not ok then ns.OnError(err) end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
} end

-- Event handlers -----------------------------------------------------------------

handlers.ADDON_LOADED = function(name)
  if name ~= ADDON then return end
  GuildhallDB = ns.DB.Init(GuildhallDB)
end

handlers.PLAYER_LOGIN = function()
  ns.UI.Launcher:Init()
  watchRestrictions()
  tryResolve()
end

handlers.PLAYER_ENTERING_WORLD = function()
  -- Zoning (e.g. leaving an instance): refresh the roster; or retry the guild lookup.
  if halted then return end
  if booted then
    checkGuild()
    ns.services.roster:Refresh()
    rosterRefreshed()
    refreshUI()
  else
    tryResolve()
  end
end

handlers.GUILD_ROSTER_UPDATE = onRosterUpdate
handlers.PLAYER_GUILD_UPDATE = onRosterUpdate

handlers.CHAT_MSG_ADDON = function(prefix, msg, channel, sender)
  if not booted or halted then return end
  ns.services.comm:Receive(prefix, msg, channel, sender)
end

handlers.MAIL_SHOW = function()
  compat:SetMailboxOpen(true)
  if not ns.exchange then return end
  local draft = ns.exchange:OnMailShow()
  if draft and StaticPopup_Show then
    StaticPopup_Show("GUILDHALL_MAIL_DRAFT", tostring(draft.to), nil, draft)
  end
end

handlers.MAIL_CLOSED = function()
  compat:SetMailboxOpen(false)
end

handlers.ADDON_RESTRICTION_STATE_CHANGED = function(kind, state)
  kind, state = compat:Safe(kind), compat:Safe(state)
  local types = Enum and Enum.AddOnRestrictionType
  local states = Enum and Enum.AddOnRestrictionState
  if not types then return end
  local inactive = states and states.Inactive or 0
  if (kind == types.Chat or kind == types.Map) and state == inactive then
    onRestrictionLifted()
  end
end

-- Module events: a module may declare def.events = { EVENT = fn(ns, ...) }. Boot loads last, so
-- every module is registered by now. Handlers run only while booted and not halted.
local moduleHandlers = {}
for _, name in ipairs(ns.Modules()) do
  local def = ns.GetModule(name)
  if type(def) == "table" and type(def.events) == "table" then
    for event, fn in pairs(def.events) do
      if type(fn) == "function" then
        moduleHandlers[event] = moduleHandlers[event] or {}
        table.insert(moduleHandlers[event], fn)
        -- Not every client has every event (e.g. the Classic bank pair): pcall tolerates that.
        pcall(frame.RegisterEvent, frame, event)
      end
    end
  end
end

frame:SetScript("OnEvent", function(_, event, ...)
  local h = handlers[event]
  if h then
    local ok, err = pcall(h, ...)
    if not ok then ns.OnError(err) end
  end
  local list = moduleHandlers[event]
  if list and booted and not halted then
    for _, fn in ipairs(list) do
      local ok, err = pcall(fn, ns, ...)
      if not ok then ns.OnError(err) end
    end
  end
end)

for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "GUILD_ROSTER_UPDATE",
  "PLAYER_GUILD_UPDATE", "CHAT_MSG_ADDON", "MAIL_SHOW", "MAIL_CLOSED" }) do
  pcall(frame.RegisterEvent, frame, event)
end
