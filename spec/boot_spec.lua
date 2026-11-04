-- Boot wiring: loads the real core + Exchange files under fake WoW globals and drives events.
describe("Boot", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, env, script, printed, sent, guild, restricted, inGuild
  local saved = {}
  local GLOBALS = { "CreateFrame", "C_Timer", "GuildhallDB", "print", "GetNormalizedRealmName", "Enum" }
  local registered, probeCalls, probeEarly, spies

  local function fire(event, ...) script(nil, event, ...) end
  local function wait(s) clock.advance(s); timers.run(clock) end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    clock = fakes.clock(1000)
    timers = fakes.timers(clock)
    printed, sent, guild, restricted, inGuild = {}, {}, "GuildA", 0, nil
    registered, probeCalls, probeEarly = {}, {}, nil
    spies = { saveMonth = 0, refreshTz = 0, hooks = 0 }
    _G.Enum = { AddOnRestrictionType = { Chat = 1, Map = 2 }, AddOnRestrictionState = { Inactive = 0 } }
    _G.CreateFrame = function()
      return {
        RegisterEvent = function(_, event) registered[event] = true end,
        SetScript = function(_, name, fn) if name == "OnEvent" then script = fn end end,
      }
    end
    _G.C_Timer = { After = function(d, cb) timers.after(d, cb) end }
    _G.GuildhallDB = nil
    _G.print = function(msg) printed[#printed + 1] = tostring(msg) end
    _G.GetNormalizedRealmName = function() return "Realm" end

    local compat
    compat, env = fakes.compat({
      UnitName = function() return "Me" end,
      GetNormalizedRealmName = function() return "Realm" end,
      GetServerTime = clock.now,
      GetGuildInfo = function() return guild, "Member", 3, nil end,
      IsInGuild = function() if inGuild == nil then return guild ~= nil end return inGuild end,
      C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function(_, line) sent[#sent + 1] = line; return 0 end,
      },
      Enum = { AddOnRestrictionType = { Chat = 1, Map = 2 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function() return restricted end },
    })
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Init.lua")
    for _, f in ipairs({ "Util", "Serialize", "DB", "ReplicatedSet", "Comm", "Sync", "Log", "Roster", "Profile" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    ns.compat = compat
    ns.UI = {
      Launcher = { Init = function() end },
      Window = { Refresh = function() end },
      Consent = { Show = function() end },
      Personal = function() return GuildhallDB and GuildhallDB.personal end,
    }
    for _, f in ipairs({ "Activity", "Observations", "Ledger", "Scoring", "Bank", "Config" }) do
      loadAddonFile(ns, "Guildhall/Core/Leaderboard/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    for _, f in ipairs({ "Category", "Listing", "Format", "MailDrafts", "Exchange", "Deals", "DealWatch" }) do
      loadAddonFile(ns, "Guildhall/Modules/Exchange/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Module.lua")
    -- count the calls the ordering/hook rules are about, on the instances Module/Exchange build
    local cfgNew = ns.LbConfig.new
    ns.LbConfig.new = function(ctx)
      local c = cfgNew(ctx)
      c.MaybeSaveMonth = function() spies.saveMonth = spies.saveMonth + 1; return false end
      c.MaybeRefreshTz = function() spies.refreshTz = spies.refreshTz + 1; return false end
      return c
    end
    local dwNew = ns.Exchange.DealWatch.new
    ns.Exchange.DealWatch.new = function(ctx)
      local w = dwNew(ctx)
      w.InstallHooks = function() spies.hooks = spies.hooks + 1; return true end
      return w
    end
    ns.RegisterModule("Thrower", { events = { PROBE = function() error("boom") end } })
    ns.RegisterModule("Probe", { events = { PROBE = function(n, ...) probeCalls[#probeCalls + 1] = { n, ... } end } })
    loadAddonFile(ns, "Guildhall/Core/Boot.lua")
    fire("PROBE", "early") -- before ADDON_LOADED / login: module events must not fire yet
    probeEarly = #probeCalls
    fire("ADDON_LOADED", "Guildhall")
    -- consent already given for this character in GuildA, so login publishes and syncs
    GuildhallDB.personal.profile.consented = true
    GuildhallDB.personal.profile.chars["Me-Realm"] = { guild = "GuildA-Realm", included = true }
    fire("PLAYER_LOGIN")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function peerLine(payload)
    -- a REQ from a guildmate, encoded the way Comm sends it
    local body = ns.Serialize.Encode({ pv = 1, m = "exchange.listings", k = "REQ", p = payload })
    return "1:1/1:" .. body
  end

  it("a module's events fire after boot and not after halt", function()
    assert.equal(0, probeEarly)
    fire("PROBE", 1, 2)
    assert.equal(1, #probeCalls)
    assert.equal(ns, probeCalls[1][1])
    assert.equal(1, probeCalls[1][2])
    assert.is_not_nil(ns.leaderboard)
    guild = "GuildB"
    fire("PLAYER_GUILD_UPDATE")
    wait(3)
    fire("PROBE", 3)
    assert.equal(1, #probeCalls)
    assert.is_nil(ns.leaderboard)
  end)

  it("a restriction lift starts every sync in services.syncs", function()
    local syncs = ns.services.syncs
    assert.is_true(#syncs >= 4) -- profiles, listings, observations, config
    local started = {}
    for i, sync in ipairs(syncs) do sync.Start = function() started[i] = true end end
    fire("ADDON_RESTRICTION_STATE_CHANGED", 1, 0)
    wait(1)
    for i = 1, #syncs do assert.is_true(started[i], "sync " .. i) end
    local has = false
    for _, sync in ipairs(syncs) do if sync == ns.exchange.sync then has = true end end
    assert.is_true(has)
  end)

  it("the tab order is Exchange, Leaderboard, Log, Settings", function()
    -- Window appends Log and Settings after the module tabs, in registration order.
    local tabs = {}
    for _, name in ipairs(ns.Modules()) do
      local def = ns.GetModule(name)
      if type(def.tab) == "table" and type(def.tab.build) == "function" then tabs[#tabs + 1] = def.tab.title end
    end
    assert.same({ "Exchange", "Leaderboard" }, tabs)
    assert.equal("Leaderboard", ns.GetModule("Leaderboard").settings.title)
  end)

  it("the window's tabs read Exchange, Leaderboard, Log, Settings, About", function()
    local real = ns.UI
    ns.UI = nil
    loadAddonFile(ns, "Guildhall/Core/UI/Window.lua")
    local keys = ns.UI.Window:TabKeys()
    ns.UI = real
    assert.same({ "Exchange", "Leaderboard", "Log", "Settings", "About" }, keys)
  end)

  it("a profile change invalidates the ledger", function()
    local n = 0
    ns.leaderboard.ledger.Invalidate = function() n = n + 1 end
    ns.services.profileSet.onChange()
    ns.services.profileSet.onChange() -- a burst coalesces
    assert.equal(0, n)
    wait(2)
    assert.equal(1, n)
  end)

  it("opting out publishes the hidden flag even though the characters are unchanged", function()
    local sv = ns.services
    local id = sv.profile:Id()
    local before = sv.profileSet:Get(id)
    assert.is_not_nil(before)
    assert.is_nil(before.d.hidden)
    local sentBefore = #sent
    sv.profile:SetHidden(true)
    ns.Boot.PublishProfile()
    local after = sv.profileSet:Get(id)
    assert.is_true(after.d.hidden)
    assert.is_true(after.v > before.v)
    wait(5)
    assert.is_true(#sent > sentBefore) -- and it went out to guildmates
  end)

  it("one throwing module handler does not stop the next, and the error is reported", function()
    fire("PROBE", 1)
    assert.equal(1, #probeCalls)
    local found = false
    for _, m in ipairs(printed) do if m:find("boom", 1, true) then found = true end end
    assert.is_true(found)
  end)

  it("after a halt the witness and the bank tick do nothing", function()
    local ex, queries, lists = ns.exchange, 0, 0
    ns.services.compat.QueryBankLog = function() queries = queries + 1 end
    ns.services.compat.BankMoneyTab = function() return 9 end
    fire("GUILDBANKFRAME_OPENED")
    local q0 = queries
    local obs = ns.leaderboard.observations
    obs.List = function() lists = lists + 1; return {} end
    guild = "GuildB"
    fire("PLAYER_GUILD_UPDATE"); wait(3)
    assert.is_true(ns.services.halted)
    ex:_queueWitness(); ex:_witness()
    wait(120)
    assert.equal(0, lists)
    assert.equal(q0, queries)
  end)

  it("a failing Leaderboard login removes its appended syncs and reports", function()
    local lb = ns.GetModule("Leaderboard")
    local s = ns.services
    local before = #s.syncs
    ns.LbConfig.new = function() error("ctor boom") end
    ns.leaderboard = nil
    lb.OnLogin(ns)
    assert.equal(before, #s.syncs)
    assert.is_nil(ns.leaderboard)
    assert.is_nil(s.observations)
    local found = false
    for _, m in ipairs(printed) do if m:find("ctor boom", 1, true) then found = true end end
    assert.is_true(found)
  end)

  it("registers the DealWatch and bank events", function()
    for _, e in ipairs({ "TRADE_CLOSED", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE", "MAIL_SEND_SUCCESS",
      "MAIL_FAILED", "MAIL_INBOX_UPDATE", "MAIL_CLOSED", "PLAYER_MONEY",
      "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
      "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "GUILDBANKLOG_UPDATE" }) do
      assert.is_true(registered[e], e)
    end
  end)

  it("routes trade and mail events to DealWatch, and installs its hooks once", function()
    assert.equal(1, spies.hooks)
    local got
    ns.exchange.dealWatch.OnEvent = function(_, event) got = event end
    fire("TRADE_CLOSED")
    assert.equal("TRADE_CLOSED", got)
    assert.equal(ns.leaderboard.observations, ns.exchange.ctx.observations)
  end)

  it("routes guild bank events to the bank", function()
    local opened, closed, logs = 0, 0, 0
    local bank = ns.leaderboard.bank
    bank.OnOpen = function() opened = opened + 1 end
    bank.OnClose = function() closed = closed + 1 end
    bank.OnLogUpdate = function() logs = logs + 1 end
    fire("GUILDBANKFRAME_OPENED")
    assert.equal(1, opened)
    fire("GUILDBANKLOG_UPDATE")
    assert.equal(1, logs)
    fire("GUILDBANKFRAME_CLOSED")
    assert.equal(1, closed)
    fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 99) -- not the guild banker (no Enum kind): ignored
    assert.equal(1, opened)
  end)

  it("invalidates the ledger on observation and profile changes only (config and roster apply in Query)", function()
    local n = 0
    ns.leaderboard.ledger.Invalidate = function() n = n + 1 end
    ns.Events:Fire("ObservationsChanged")
    ns.Events:Fire("ProfilesChanged")
    assert.equal(2, n)
    ns.Events:Fire("LeaderboardConfigChanged")
    ns.Events:Fire("RosterRefreshed")
    assert.equal(2, n)
  end)

  it("the roster loading (no ranks -> ranks) restarts the config sync once", function()
    local cfg = ns.leaderboard.config
    local starts, has = 0, false
    cfg.sync.Start = function() starts = starts + 1 end
    ns.services.roster.HasRanks = function() return has end
    cfg.hadRanks = false
    ns.Events:Fire("RosterRefreshed")
    assert.equal(0, starts)
    has = true
    ns.Events:Fire("RosterRefreshed")
    assert.equal(1, starts)
    ns.Events:Fire("RosterRefreshed")
    assert.equal(1, starts)
  end)

  it("the officer work waits until observations have been quiet for 60 s", function()
    ns.services.roster.IsOfficer = function() return true end
    local obs = ns.leaderboard.observations
    wait(80)
    obs.changes = obs.changes + 1 -- still syncing
    wait(11)                       -- 91 s: changed 11 s ago
    assert.equal(0, spies.saveMonth)
    wait(30)                       -- 121 s: 41 s quiet
    assert.equal(0, spies.saveMonth)
    wait(30)                       -- 151 s: 71 s quiet
    assert.equal(1, spies.saveMonth)
    assert.equal(1, spies.refreshTz)
    for _ = 1, 40 do wait(30) end
    assert.equal(1, spies.saveMonth)
  end)

  it("the officer work waits for an empty send queue, and is skipped after 15 min of traffic", function()
    ns.services.roster.IsOfficer = function() return true end
    local pending = 3
    ns.services.comm.Pending = function() return pending end
    for _ = 1, 40 do wait(30) end -- 1200 s, never quiet
    assert.equal(0, spies.saveMonth)
    pending = 0
    for _ = 1, 10 do wait(30) end
    assert.equal(0, spies.saveMonth)
  end)

  it("the officer work runs once the queue empties within the window", function()
    ns.services.roster.IsOfficer = function() return true end
    local pending = 3
    ns.services.comm.Pending = function() return pending end
    wait(91)
    assert.equal(0, spies.saveMonth)
    pending = 0
    wait(30)
    assert.equal(1, spies.saveMonth)
  end)

  it("a weights holder below the officer threshold refreshes tz", function()
    ns.services.roster.IsOfficer = function() return false end
    ns.leaderboard.permissions.Can = function(_, _, key) return key == "weights" end
    wait(91)
    assert.equal(1, spies.refreshTz)
  end)

  it("saves months and refreshes tz only after the settle delay, and only as an officer", function()
    assert.equal(0, spies.saveMonth)
    assert.equal(0, spies.refreshTz)
    ns.services.roster.IsOfficer = function() return nil end -- roster unknown
    wait(91)
    assert.equal(0, spies.saveMonth)
  end)

  it("an officer saves the month and refreshes tz 90 s after login", function()
    ns.services.roster.IsOfficer = function() return true end
    wait(89)
    assert.equal(0, spies.saveMonth)
    wait(2)
    assert.equal(1, spies.saveMonth)
    assert.equal(1, spies.refreshTz)
  end)

  it("boots for the current guild", function()
    assert.equal("GuildA-Realm", ns.services.guildKey)
    assert.is_not_nil(ns.exchange)
    assert.is_true(#sent > 0)
  end)

  it("halts on a guild change: no answers, no stores touched, asks for /reload (I3)", function()
    local ok, rec = ns.exchange:Post({ kind = "WTS", item = "Linen Cloth", mats = false, cod = false })
    assert.is_true(ok)
    local storeA = GuildhallDB.guilds["GuildA-Realm"].modules.Exchange.listings
    guild = "GuildB"
    fire("PLAYER_GUILD_UPDATE")
    wait(3)
    assert.is_nil(ns.exchange)
    assert.truthy(printed[#printed]:find("/reload", 1, true))
    assert.truthy(printed[#printed]:find("GuildB", 1, true))
    local before = #sent
    fire("CHAT_MSG_ADDON", "Guildhall", peerLine({ have = {} }), "GUILD", "Peer-Realm")
    wait(10)
    assert.equal(before, #sent) -- A's listings are not served to B
    assert.is_not_nil(storeA[rec.id])
    assert.is_nil(GuildhallDB.guilds["GuildB-Realm"])
    local logs = #GuildhallDB.guilds["GuildA-Realm"].log
    fire("CHAT_MSG_ADDON", "Guildhall", "junk", "GUILD", "Peer-Realm")
    assert.equal(logs, #GuildhallDB.guilds["GuildA-Realm"].log)
    fire("GUILD_ROSTER_UPDATE"); wait(3)
    assert.equal(1, #printed) -- said once
  end)

  it("halts when the player leaves the guild (readable, unrestricted)", function()
    guild = nil
    fire("PLAYER_GUILD_UPDATE")
    wait(3)
    assert.is_nil(ns.exchange)
    assert.truthy(printed[#printed]:find("/reload", 1, true))
  end)

  it("does not halt on a nil guild while restricted (the name may just be secret)", function()
    guild, restricted = nil, 2
    fire("GUILD_ROSTER_UPDATE")
    wait(3)
    assert.is_not_nil(ns.exchange)
    assert.equal(0, #printed)
  end)

  it("does not halt while IsInGuild() still says true (N2: slow guild-info load)", function()
    guild, inGuild = nil, true
    fire("PLAYER_GUILD_UPDATE")
    wait(3)
    assert.is_not_nil(ns.exchange)
    assert.equal(0, #printed)
  end)

  it("does not halt when the guild info is only briefly empty", function()
    guild = nil
    fire("PLAYER_GUILD_UPDATE")
    guild = "GuildA"
    wait(3)
    assert.is_not_nil(ns.exchange)
    assert.equal(0, #printed)
  end)
end)
