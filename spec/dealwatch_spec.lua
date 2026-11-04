describe("Exchange DealWatch", function()
  local ns, published, timers, env, snap, partner, listings, now
  local LINK = "|Hitem:2589::|h[Linen Cloth]|h"

  local function build()
    local fakeCompat = {
      TradeSnapshot = function() local c = {}; for k, v in pairs(snap) do c[k] = v end; return c end,
      TradePartner = function() return partner end,
      Safe = function(_, v) return v end,
    }
    return ns.Exchange.DealWatch.new({
      compat = fakeCompat,
      exchange = { listings = { List = function(_, withTombstones)
        assert.is_true(withTombstones)
        return listings
      end } },
      observations = { Publish = function(_, d) published[#published + 1] = d; return "ok", {} end },
      profile = { Id = function() return "ann" end,
        OwnerOf = function(_, c) return ({ ["Bob-R"] = "bob" })[c] end },
      roster = { Norm = function(_, n) return n end },
      now = function() return now end,
      after = function(s, fn) timers[#timers + 1] = { s = s, fn = fn } end,
      env = env,
    })
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Deals.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/DealWatch.lua")
    published, timers, now = {}, {}, 5000
    env = { ERR_TRADE_COMPLETE = "Trade complete." }
    snap = { give = { { id = 2589, n = 20 } }, get = {}, giveCopper = 0, getCopper = 50000 }
    partner = "Bob-R"
    listings = { { id = "L1", v = 1, t = 1000, by = "ann", char = "Ann-R", exp = 700000, del = false,
      d = { kind = "WTS", item = LINK, qty = 20, cod = false, created = 1000 } } }
  end)

  it("a complete trade publishes exactly one observation", function()
    local w = build()
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    assert.equal(1, #published)
    assert.same({ kind = "trade", listing = "L1", seller = "ann", buyer = "bob", item = 2589, count = 20,
      copper = 50000, at = 5000 }, published[1])
  end)

  it("accepts the numeric message type form", function()
    env.LE_GAME_ERR_TRADE_COMPLETE = 77
    local w = build()
    w:OnEvent("TRADE_ACCEPT_UPDATE", true, true)
    w:OnEvent("UI_INFO_MESSAGE", 77)
    assert.equal(1, #published)
  end)

  it("ignores other messages, and one-sided accepts", function()
    local w = build()
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 0)
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    w:OnEvent("UI_INFO_MESSAGE", 1, "Something else.")
    assert.equal(0, #published)
  end)

  it("a secret trade money value gives no snapshot and no observation (Review Focus 1)", function()
    local cns = {}
    loadAddonFile(cns, "Guildhall/Core/Util.lua")
    loadAddonFile(cns, "Guildhall/Core/Compat.lua")
    local real = cns.Compat.new({
      GetTradePlayerItemLink = function(i) if i == 1 then return LINK end end,
      GetTradePlayerItemInfo = function(i) if i == 1 then return "x", 1, 20 end end,
      GetTradeTargetItemLink = function() end, GetTradeTargetItemInfo = function() end,
      GetPlayerTradeMoney = function() return 0 end, GetTargetTradeMoney = function() return 50000 end,
      UnitName = function() return "Bob", "R" end,
      issecretvalue = function(v) return v == 50000 end,
    })
    local w = ns.Exchange.DealWatch.new({
      compat = real,
      exchange = { listings = { List = function() return listings end } },
      observations = { Publish = function(_, d) published[#published + 1] = d end },
      profile = { Id = function() return "ann" end, OwnerOf = function() return "bob" end },
      roster = { Norm = function(_, n) return n end },
      now = function() return now end, after = function() end, env = env,
    })
    assert.has_no.errors(function()
      w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
      w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    end)
    assert.equal(0, #published)
  end)

  it("no profile for the partner means no observation", function()
    partner = "Stranger-R"
    local w = build()
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    assert.equal(0, #published)
  end)

  it("TRADE_CLOSED clears the snapshot after 1 s", function()
    local w = build()
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    w:OnEvent("TRADE_CLOSED")
    assert.equal(1, timers[1].s)
    -- completion message arriving right after close still counts
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    assert.equal(1, #published)
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    w:OnEvent("TRADE_CLOSED")
    timers[2].fn()
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    assert.equal(1, #published)
  end)

  it("a stale close timer doesn't clear a newer trade's snapshot", function()
    local w = build()
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    w:OnEvent("TRADE_CLOSED")
    w:OnEvent("TRADE_ACCEPT_UPDATE", 1, 1)
    timers[1].fn()
    w:OnEvent("UI_INFO_MESSAGE", 1, "Trade complete.")
    assert.equal(1, #published)
  end)
end)
