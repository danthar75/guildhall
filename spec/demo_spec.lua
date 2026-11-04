-- /gh lbdemo: fake leaderboard data, in memory only.
describe("Leaderboard demo", function()
  local ns, Demo, publishes, synced, lb, realLedger, realConfig, refreshed
  local NOW = 1699999999 -- 2023-11-14 21:33 UTC

  local function profileStub()
    return {
      Id = function() return "real1" end,
      IsHidden = function() return false end,
      OnlineChar = function() return nil end,
      OwnerOf = function() return nil end,
      CharsOf = function() return {} end,
    }
  end

  before_each(function()
    ns = { Events = { Fire = function() end } }
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Ledger.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Deals.lua")
    ns.Observations = { KINDS = { trade = true, cod = true, manual = true, witness = true, bank = true } }
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Bank.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Demo.lua")
    Demo = ns.Leaderboard.Demo
    publishes, refreshed = 0, 0
    ns.Leaderboard.View = { Refresh = function() refreshed = refreshed + 1 end }
    realLedger = { Query = function() return { byProfile = {}, guild = {}, goldKept = 0 } end, Invalidate = function() end }
    realConfig = { Months = function() return {} end, Month = function() return nil end, Weights = function() return {} end }
    lb = {
      observations = { Publish = function() publishes = publishes + 1 end },
      ledger = realLedger, config = realConfig,
    }
    ns.leaderboard = lb
    synced = {}
    ns.services = { profile = profileStub(), now = function() return NOW end, syncs = synced,
      comm = { Send = function() publishes = publishes + 1 end } }
    GuildhallDB = { snapshot = { a = { 1, 2 } } }
  end)

  after_each(function() GuildhallDB = nil end)

  local function snapshot(t)
    local out = {}
    local function walk(v, path)
      if type(v) == "table" then
        for k, x in pairs(v) do walk(x, path .. "/" .. tostring(k)) end
      else
        out[#out + 1] = path .. "=" .. tostring(v)
      end
    end
    walk(t, "")
    table.sort(out)
    return table.concat(out, "\n")
  end

  it("builds 12 fake profiles, about 60 deals, about 40 bank entries and a month", function()
    local store = Demo.Build(NOW)
    local n = 0
    for _ in pairs(store.names) do n = n + 1 end
    assert.equal(12, n)
    assert.is_true(#store:List("trade") + #store:List("cod") >= 100)
    assert.is_true(#store:List("bank") >= 40)
    assert.is_truthy(store.month)
    assert.is_truthy(store.month.rec.overall[1])
    -- only fake names; none of them is a real guildmate
    assert.equal("Thalwyn", store.names.d1)
  end)

  it("demo mode publishes nothing and lbdemo off restores the real ledger", function()
    local before = snapshot(GuildhallDB)
    Demo.Set(ns, true)
    assert.is_true(lb.demo)
    assert.not_equal(realLedger, lb.ledger)
    local r = lb.ledger:Query({})
    assert.is_truthy(next(r.byProfile))
    assert.is_truthy(lb.config:Months()[1])
    assert.is_truthy(lb.config:Month(lb.config:Months()[1]))
    assert.equal(1, refreshed)
    assert.equal(0, publishes)
    assert.equal(before, snapshot(GuildhallDB))
    assert.equal(0, #synced)
    Demo.Set(ns, false)
    assert.is_falsy(lb.demo)
    assert.equal(realLedger, lb.ledger)
    assert.equal(realConfig, lb.config)
    assert.is_nil(lb.demoProfile)
    assert.equal(2, refreshed)
    assert.equal(0, publishes)
  end)

  it("demo data fills the week, the month and the previous month", function()
    Demo.Set(ns, true)
    local clock = { tz = 0 }
    local function total(from, to)
      local r = lb.ledger:Query({ from = from, to = to })
      local n = 0
      for _, t in pairs(r.byProfile) do n = n + (t["exchange.sales"] or 0) end
      return n
    end
    local wf, wt = ns.Scoring.Period("week", NOW, clock)
    local mf, mt = ns.Scoring.Period("month", NOW, clock)
    assert.is_true(total(wf, wt) > 0)
    assert.is_true(total(mf, mt) > 0)
    assert.is_true(total(mf - 31 * 86400, mf) > 0)
    assert.equal(0, publishes)
  end)

  it("turning demo on twice keeps the real ledger for off", function()
    Demo.Set(ns, true)
    Demo.Set(ns, true)
    Demo.Set(ns, false)
    assert.equal(realLedger, lb.ledger)
  end)
end)
