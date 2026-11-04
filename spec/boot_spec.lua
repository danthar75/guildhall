-- Boot wiring: loads the real core + Exchange files under fake WoW globals and drives events.
describe("Boot", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, env, script, printed, sent, guild, restricted, inGuild
  local saved = {}
  local GLOBALS = { "CreateFrame", "C_Timer", "GuildhallDB", "print", "GetNormalizedRealmName" }

  local function fire(event, ...) script(nil, event, ...) end
  local function wait(s) clock.advance(s); timers.run(clock) end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    clock = fakes.clock(1000)
    timers = fakes.timers(clock)
    printed, sent, guild, restricted, inGuild = {}, {}, "GuildA", 0, nil
    _G.CreateFrame = function()
      return {
        RegisterEvent = function() end,
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
    for _, f in ipairs({ "Listing", "Format", "MailDrafts", "Exchange" }) do
      loadAddonFile(ns, "Guildhall/Modules/Exchange/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Boot.lua")
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
