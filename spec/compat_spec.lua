describe("Compat", function()
  local fakes = require("spec.helpers.fakes")
  local Compat

  before_each(function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Compat.lua")
    Compat = ns.Compat
  end)

  local function sendEnv(result, extra)
    local env = { sent = 0 }
    env.C_ChatInfo = { SendAddonMessage = function() env.sent = env.sent + 1; return result end }
    env.Enum = { SendAddonMessageResult = { Success = 0 } }
    for k, v in pairs(extra or {}) do env[k] = v end
    return env
  end

  it("loads and creates ns.compat without WoW APIs", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Compat.lua")
    assert.is_table(ns.compat)
  end)

  it("Safe hides secret/inaccessible values and passes through when APIs are absent", function()
    local c = Compat.new({ issecretvalue = function(v) return v == "s" end })
    assert.is_nil(c.Safe(c, "s"))
    assert.equal("x", c:Safe("x"))
    local c2 = Compat.new({ canaccessvalue = function(v) return v ~= "n" end })
    assert.is_nil(c2:Safe("n"))
    assert.equal("x", Compat.new({}):Safe("x"))
  end)

  it("IsRestricted is false without C_RestrictedActions, true when active", function()
    assert.is_false(Compat.new({}):IsRestricted("Chat"))
    local state = 0
    local env = {
      Enum = { AddOnRestrictionType = { Chat = 5 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function(t) assert.equal(5, t); return state end },
    }
    local c = Compat.new(env)
    assert.is_false(c:IsRestricted("Chat"))
    state = 1; assert.is_true(c:IsRestricted("Chat"))
    state = 2; assert.is_true(c:IsRestricted("Chat"))
  end)

  it("SendAddon maps results", function()
    assert.equal("ok", Compat.new(sendEnv(0)):SendAddon("P", "m"))
    assert.equal("ok", Compat.new(sendEnv(true)):SendAddon("P", "m"))
    assert.equal("lockdown", Compat.new(sendEnv(11)):SendAddon("P", "m"))
    assert.equal("throttle", Compat.new(sendEnv(3)):SendAddon("P", "m"))
    assert.equal("throttle", Compat.new(sendEnv(8)):SendAddon("P", "m"))
    assert.equal("error", Compat.new(sendEnv(2)):SendAddon("P", "m"))
    assert.equal("error", Compat.new(sendEnv(false)):SendAddon("P", "m"))
  end)

  it("SendAddon returns lockdown without calling the API when Chat is restricted", function()
    local env = sendEnv(0, {
      Enum = { AddOnRestrictionType = { Chat = 5 }, SendAddonMessageResult = { Success = 0 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function() return 2 end },
    })
    assert.equal("lockdown", Compat.new(env):SendAddon("P", "m"))
    assert.equal(0, env.sent)
  end)

  it("RegisterPrefix, Now, IsTrial", function()
    local got
    local c = Compat.new({
      C_ChatInfo = { RegisterAddonMessagePrefix = function(p) got = p end },
      GetServerTime = function() return 42 end,
      IsVeteranTrialAccount = function() return true end,
    })
    c:RegisterPrefix("GH")
    assert.equal("GH", got)
    assert.equal(42, c:Now())
    assert.is_true(c:IsTrial())
    assert.is_false(Compat.new({}):IsTrial())
  end)

  it("GuildKey is nil when not in a guild or secret, else full name", function()
    assert.is_nil(Compat.new({ GetGuildInfo = function() return nil end }):GuildKey())
    assert.is_nil(Compat.new({}):GuildKey())
    local env = {
      GetGuildInfo = function() return "Emergence", "Rank", 1, "Argent Dawn" end,
      GetNormalizedRealmName = function() return "Home" end,
    }
    assert.equal("Emergence-ArgentDawn", Compat.new(env):GuildKey())
    env.GetGuildInfo = function() return "Emergence" end
    assert.equal("Emergence-Home", Compat.new(env):GuildKey())
    env.issecretvalue = function() return true end
    assert.is_nil(Compat.new(env):GuildKey())
  end)

  it("GuildName returns the guild's name, or nil when absent, empty or secret", function()
    local name
    local env = { GetGuildInfo = function() return name, "Member", 3 end,
      issecretvalue = function(v) return v == "SECRET" end }
    local c = Compat.new(env)
    name = "Emergence"; assert.equal("Emergence", c:GuildName())
    name = nil; assert.is_nil(c:GuildName())
    name = ""; assert.is_nil(c:GuildName())
    name = "SECRET"; assert.is_nil(c:GuildName())
    assert.is_nil(Compat.new({}):GuildName())
  end)

  it("PlayerFullName", function()
    local env = { UnitName = function() return "Thalwyn" end, GetNormalizedRealmName = function() return "ArgentDawn" end }
    assert.equal("Thalwyn-ArgentDawn", Compat.new(env):PlayerFullName())
  end)

  it("OpenChat prefers ChatFrameUtil.OpenChat, falls back to ChatFrame_OpenChat", function()
    local a, b
    Compat.new({ ChatFrameUtil = { OpenChat = function(t) a = t end }, ChatFrame_OpenChat = function(t) b = t end }):OpenChat("/w X hi")
    assert.equal("/w X hi", a); assert.is_nil(b)
    Compat.new({ ChatFrame_OpenChat = function(t) b = t end }):OpenChat("/w Y")
    assert.equal("/w Y", b)
    assert.has_no.errors(function() Compat.new({}):OpenChat("x") end)
  end)

  it("mailbox flag", function()
    local c = Compat.new({})
    assert.is_false(c:MailboxOpen())
    c:SetMailboxOpen(true); assert.is_true(c:MailboxOpen())
    c:SetMailboxOpen(false); assert.is_false(c:MailboxOpen())
  end)

  it("FillSendMail fills the fields, never sends", function()
    local function box() local b = {}; function b:SetText(t) self.text = t end; return b end
    local env
    env = {
      MailFrameTab_OnClick = function(_, tab) env.tab = tab end,
      SendMailNameEditBox = box(), SendMailSubjectEditBox = box(), SendMailBodyEditBox = box(),
      SendMail = function() error("must not send") end,
    }
    assert.is_true(Compat.new(env):FillSendMail("Bob-Realm", "Subj", "Body"))
    assert.equal(2, env.tab)
    assert.equal("Bob-Realm", env.SendMailNameEditBox.text)
    assert.equal("Subj", env.SendMailSubjectEditBox.text)
    assert.equal("Body", env.SendMailBodyEditBox.text)
  end)

  it("FillSendMail returns false when a frame is missing", function()
    local function box() local b = {}; function b:SetText(t) self.text = t end; return b end
    local env = { MailFrameTab_OnClick = function() end, SendMailNameEditBox = box(), SendMailSubjectEditBox = box() }
    assert.is_false(Compat.new(env):FillSendMail("a", "b", "c"))
    assert.is_false(Compat.new({}):FillSendMail("a", "b", "c"))
  end)

  it("fakes.compat returns a real Compat over a fake env", function()
    local c, env = fakes.compat({ GetServerTime = function() return 7 end })
    assert.equal(7, c:Now())
    assert.equal(0, env.sent)
  end)

  it("ServerOffset rounds to 15 minutes and is nil when missing or secret", function()
    assert.is_nil(Compat.new({}):ServerOffset())
    local function env(localT, extra)
      local e = { GetServerTime = function() return 1000 end,
        C_DateAndTime = { GetServerTimeLocal = function() return localT end } }
      for k, v in pairs(extra or {}) do e[k] = v end
      return e
    end
    assert.equal(-28800, Compat.new(env(1000 - 28800 + 200)):ServerOffset())
    assert.equal(3600, Compat.new(env(1000 + 3600)):ServerOffset())
    assert.is_nil(Compat.new(env(5, { issecretvalue = function(v) return v == 5 end })):ServerOffset())
  end)

  it("GuildRanks reads rank names in order, nil when missing or any name is secret", function()
    assert.is_nil(Compat.new({}):GuildRanks())
    local names = { "Guild Master", "Officer", "Member" }
    local e = { GuildControlGetNumRanks = function() return 3 end,
      GuildControlGetRankName = function(i) return names[i] end }
    assert.same({ "Guild Master", "Officer", "Member" }, Compat.new(e):GuildRanks())
    e.issecretvalue = function(v) return v == "Officer" end
    assert.is_nil(Compat.new(e):GuildRanks())
    e.issecretvalue = function(v) return v == 3 end
    assert.is_nil(Compat.new(e):GuildRanks())
  end)

  it("SecondsUntilWeeklyReset reads the API, nil when missing or secret", function()
    assert.is_nil(Compat.new({}):SecondsUntilWeeklyReset())
    local e = { C_DateAndTime = { GetSecondsUntilWeeklyReset = function() return 12345 end } }
    assert.equal(12345, Compat.new(e):SecondsUntilWeeklyReset())
    e.issecretvalue = function() return true end
    assert.is_nil(Compat.new(e):SecondsUntilWeeklyReset())
  end)
  describe("trade", function()
    local function tradeEnv(extra)
      local e = {
        GetTradePlayerItemLink = function(i) if i == 1 then return "|Hitem:2589::|h[Linen Cloth]|h" end end,
        GetTradePlayerItemInfo = function(i) if i == 1 then return "Linen Cloth", 1, 20 end end,
        GetTradeTargetItemLink = function(i) if i == 2 then return "|Hitem:2592::|h[Wool Cloth]|h" end end,
        GetTradeTargetItemInfo = function(i) if i == 2 then return "Wool Cloth", 1, 5 end end,
        GetPlayerTradeMoney = function() return 0 end,
        GetTargetTradeMoney = function() return 12345 end,
        UnitName = function(u) if u == "NPC" then return "Bob", "Argent Dawn" end end,
      }
      for k, v in pairs(extra or {}) do e[k] = v end
      return e
    end

    it("TradeSnapshot reads both sides, items and money", function()
      local snap = Compat.new(tradeEnv()):TradeSnapshot()
      assert.same({ { id = 2589, n = 20 } }, snap.give)
      assert.same({ { id = 2592, n = 5 } }, snap.get)
      assert.equal(0, snap.giveCopper)
      assert.equal(12345, snap.getCopper)
    end)

    it("TradeSnapshot is nil when the APIs are missing or any value is secret", function()
      assert.is_nil(Compat.new({}):TradeSnapshot())
      assert.is_nil(Compat.new(tradeEnv({ issecretvalue = function(v) return v == 12345 end })):TradeSnapshot())
      assert.is_nil(Compat.new(tradeEnv({ issecretvalue = function(v) return v == 20 end })):TradeSnapshot())
    end)

    it("TradeSnapshot is nil when an item link is secret, but an empty slot is fine", function()
      local LINK = "|Hitem:2589::|h[Linen Cloth]|h"
      assert.is_nil(Compat.new(tradeEnv({ issecretvalue = function(v) return v == LINK end })):TradeSnapshot())
      assert.is_not_nil(Compat.new(tradeEnv({ issecretvalue = function() return false end })):TradeSnapshot())
    end)

    it("TradePartner is the NPC unit as a full name, nil when absent or secret", function()
      assert.equal("Bob-ArgentDawn", Compat.new(tradeEnv()):TradePartner())
      assert.is_nil(Compat.new({}):TradePartner())
      assert.is_nil(Compat.new(tradeEnv({ issecretvalue = function(v) return v == "Bob" end })):TradePartner())
    end)
  end)

  describe("group reads", function()
    local function secretIf(set)
      return function(v) return set[v] == true end
    end

    local function raidEnv(rows, extra)
      local e = {
        IsInRaid = function() return true end,
        GetNumGroupMembers = function() return #rows end,
        UnitName = function() return "Me" end,
        GetNormalizedRealmName = function() return "Realm" end,
        GetRaidRosterInfo = function(i) return rows[i][1], rows[i][2] end,
      }
      for k, v in pairs(extra or {}) do e[k] = v end
      return e
    end

    it("a snapshot with secret names publishes only readable members, or nothing", function()
      local rows = { { "Me", 2 }, { "Bob", 0 }, { "Hidden", 1 }, { nil, 0 } }
      local snap = Compat.new(raidEnv(rows, { issecretvalue = secretIf({ Hidden = true }) })):GroupSnapshot()
      assert.same({ "Me-Realm", "Bob-Realm" }, snap.members)
      assert.equal("Me-Realm", snap.leader)
      assert.same({}, snap.assists)
      assert.equal(4, snap.size)
      -- only one readable name: nothing is published
      assert.is_nil(Compat.new(raidEnv(rows, { issecretvalue = secretIf({ Hidden = true, Bob = true }) })):GroupSnapshot())
      -- a secret member count: nothing
      assert.is_nil(Compat.new(raidEnv(rows, { issecretvalue = secretIf({ [4] = true }) })):GroupSnapshot())
      -- solo, or no group API (Classic fallbacks missing)
      assert.is_nil(Compat.new(raidEnv({ { "Me", 2 } })):GroupSnapshot())
      assert.is_nil(Compat.new({}):GroupSnapshot())
    end)

    it("leader and assists read from raid rank", function()
      local rows = { { "Me", 1 }, { "Bob-Other", 2 }, { "Cat", 1 }, { "Dan", 0 } }
      local snap = Compat.new(raidEnv(rows)):GroupSnapshot()
      assert.same({ "Me-Realm", "Bob-Other", "Cat-Realm", "Dan-Realm" }, snap.members)
      assert.equal("Bob-Other", snap.leader)
      assert.same({ "Me-Realm", "Cat-Realm" }, snap.assists)
      -- a secret rank: still a member, but neither leader nor assist
      snap = Compat.new(raidEnv(rows, { issecretvalue = secretIf({ [2] = true }) })):GroupSnapshot()
      assert.is_nil(snap.leader)
      assert.equal(4, #snap.members)
    end)

    it("a party snapshot reads unit names and UnitIsGroupLeader", function()
      local names = { player = { "Me" }, party1 = { "Bob", "Other Realm" }, party2 = { "Hidden" } }
      local e = {
        IsInRaid = function() return false end,
        GetNumGroupMembers = function() return 3 end,
        GetNormalizedRealmName = function() return "Realm" end,
        UnitName = function(u) local n = names[u]; if n then return n[1], n[2] end end,
        UnitIsGroupLeader = function(u) return u == "party1" end,
        issecretvalue = secretIf({ Hidden = true }),
      }
      local snap = Compat.new(e):GroupSnapshot()
      assert.same({ "Me-Realm", "Bob-OtherRealm" }, snap.members)
      assert.equal("Bob-OtherRealm", snap.leader)
      assert.same({}, snap.assists)
      assert.equal(3, snap.size)
      e.UnitIsGroupLeader = nil -- missing API: no leader, still a snapshot
      assert.is_nil(Compat.new(e):GroupSnapshot().leader)
    end)

    it("InstanceKey is GetInstanceInfo return 8, nil when missing or secret", function()
      local id = 409
      local e = { GetInstanceInfo = function() return "Molten Core", "raid", 9, "40 Player", 40, 0, false, id end }
      assert.equal(409, Compat.new(e):InstanceKey())
      e.issecretvalue = secretIf({ [409] = true })
      assert.is_nil(Compat.new(e):InstanceKey())
      assert.is_nil(Compat.new({}):InstanceKey())
    end)

    it("ActiveSpecGroup is nil without dual spec", function()
      assert.is_nil(Compat.new({}):ActiveSpecGroup())
      assert.is_nil(Compat.new({ GetActiveTalentGroup = function() return 1 end,
        GetNumTalentGroups = function() return 1 end }):ActiveSpecGroup())
      assert.equal(2, Compat.new({ GetActiveTalentGroup = function() return 2 end }):ActiveSpecGroup())
      assert.equal(1, Compat.new({ C_SpecializationInfo = { GetActiveSpecGroup = function() return 1 end } }):ActiveSpecGroup())
      assert.is_nil(Compat.new({ GetActiveTalentGroup = function() return 2 end,
        issecretvalue = function() return true end }):ActiveSpecGroup())
      assert.is_nil(Compat.new({ GetActiveTalentGroup = function() return 3 end }):ActiveSpecGroup())
    end)

    it("ItemCount reads GetItemCount or C_Item, nil when missing or secret", function()
      assert.is_nil(Compat.new({}):ItemCount(13444))
      assert.equal(5, Compat.new({ GetItemCount = function(id) return id == 13444 and 5 or 0 end }):ItemCount(13444))
      assert.equal(7, Compat.new({ C_Item = { GetItemCount = function() return 7 end } }):ItemCount(13444))
      assert.is_nil(Compat.new({ GetItemCount = function() return 5 end,
        issecretvalue = function(v) return v == 5 end }):ItemCount(13444))
    end)

    describe("UnenchantedSlots", function()
      local function gearEnv(links, info, extra)
        local e = {
          GetInventoryItemLink = function(unit, slot) assert.equal("player", unit); return links[slot] end,
          GetItemInfoInstant = function(link)
            local c = info[link]
            if c then return 1, "t", "s", "loc", 0, c[1], c[2] end
          end,
        }
        for k, v in pairs(extra or {}) do e[k] = v end
        return e
      end

      it("UnenchantedSlots finds 'Legs' for item:123:0 and skips an empty off hand", function()
        local links = {
          [1] = "|cff|Hitem:100:1503:0:0|h[Helm]|h|r",
          [7] = "|cff|Hitem:123:0:0:0|h[Legs]|h|r",
          [16] = "|cff|Hitem:200:2564|h[Sword]|h|r",
        }
        assert.same({ "Legs" }, Compat.new(gearEnv(links, {})):UnenchantedSlots())
      end)

      it("treats an empty enchant field as unenchanted, and counts the off hand only for a weapon or shield", function()
        local links = {
          [5] = "item:300::0",
          [17] = "item:400:0",
        }
        local env = gearEnv(links, { ["item:400:0"] = { 4, 0 } }) -- an off-hand frill (armor, misc)
        assert.same({ "Chest" }, Compat.new(env):UnenchantedSlots())
        env = gearEnv(links, { ["item:400:0"] = { 4, 6 } }) -- a shield
        assert.same({ "Chest", "Off hand" }, Compat.new(env):UnenchantedSlots())
        env = gearEnv(links, { ["item:400:0"] = { 2, 7 } }) -- a weapon
        assert.same({ "Chest", "Off hand" }, Compat.new(env):UnenchantedSlots())
        env = gearEnv(links, {})
        env.GetItemInfoInstant = nil -- no way to tell: off hand skipped
        assert.same({ "Chest" }, Compat.new(env):UnenchantedSlots())
      end)

      it("is nil when the API is missing or any link is secret", function()
        assert.is_nil(Compat.new({}):UnenchantedSlots())
        local links = { [7] = "item:123:0" }
        assert.is_nil(Compat.new(gearEnv(links, {}, { issecretvalue = secretIf({ ["item:123:0"] = true }) })):UnenchantedSlots())
        assert.same({}, Compat.new(gearEnv({}, {})):UnenchantedSlots())
      end)
    end)
  end)
end)
