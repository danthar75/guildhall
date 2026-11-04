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
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
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

-- Drives a REAL LbConfig (with a sync over a spy Comm) and the officer timer path with demo on.
describe("Leaderboard demo never reaches the real guild", function()
  local fakes = require("spec.helpers.fakes")
  local function utc(y, m, d, h)
    local a = math.floor((14 - m) / 12)
    y, m = y + 4800 - a, m + 12 * a - 3
    local jdn = d + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 32045
    return (jdn - 2440588) * 86400 + (h or 0) * 3600
  end

  local ns, clock, timers, sent, cfg, db, lb, services

  before_each(function()
    clock = fakes.clock(utc(2026, 11, 5, 12))
    timers = fakes.timers(clock)
    local bus = fakes.bus(clock, timers)
    ns = { Events = { Fire = function() end, On = function() end }, OnError = function(e) error(e) end }
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua") end
    for _, f in ipairs({ "Activity", "Scoring", "Ledger" }) do loadAddonFile(ns, "Guildhall/Core/Leaderboard/" .. f .. ".lua") end
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Deals.lua")
    ns.Observations = { KINDS = { trade = true, cod = true, manual = true, witness = true, bank = true } }
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Bank.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Config.lua")
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Demo.lua")
    ns.RegisterModule = function() end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Module.lua")
    sent = 0
    local comm = bus:join("Boss-Realm")
    local realSend = comm.Send
    comm.Send = function(...) sent = sent + 1; return realSend(...) end
    local profile = { Id = function() return "pMe" end, IsHidden = function() return false end,
      OnlineChar = function() return nil end, CharsOf = function() return {} end, OwnerOf = function() return nil end,
      set = { Get = function() return nil end } }
    local roster = { IsOfficer = function() return true end }
    db = {}
    cfg = ns.LbConfig.new({ comm = comm, now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = ns.Log.new({}, clock.now, function() return "" end), roster = roster, profile = profile,
      compat = { ServerOffset = function() return 0 end }, playerChar = "Boss-Realm", db = db })
    local realLedger = { Query = function() return { byProfile = {}, guild = {}, goldKept = 0 } end, Invalidate = function() end }
    lb = { ledger = realLedger, config = cfg }
    ns.leaderboard = lb
    services = { now = clock.now, compat = { ServerOffset = function() return 0 end }, profile = profile,
      roster = roster, playerChar = "Boss-Realm" }
    ns.services = services
  end)

  local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

  it("the officer timer during demo saves and sends nothing", function()
    ns.Leaderboard.Demo.Set(ns, true)
    local before = count(db)
    ns.Leaderboard.RunOfficerWork(services)
    assert.equal(0, sent)
    assert.equal(before, count(db))
    ns.Leaderboard.Demo.Set(ns, false)
    assert.is_nil(cfg:Month("2026-10"))
    assert.equal(0, sent)
  end)

  it("every write on the demo config is refused", function()
    ns.Leaderboard.Demo.Set(ns, true)
    for _, name in ipairs({ "PublishWeights", "RetakeMonth", "MaybeSaveMonth", "MaybeRefreshTz", "SetExcluded" }) do
      local ok, err = lb.config[name](lb.config, {}, lb.ledger)
      assert.is_false(ok)
      assert.is_truthy(err:find("/gh lbdemo off", 1, true))
    end
    assert.is_nil(rawget(lb.config, "set"))
    assert.equal(0, sent)
  end)

  it("demo permissions are the defaults, read-only, and refuse a save", function()
    local real = cfg.perms
    lb.permissions = real
    ns.Leaderboard.Demo.Set(ns, true)
    local p = lb.permissions
    assert.not_equal(real, p)
    assert.equal(p, lb.config.perms)
    assert.is_false(p:Editable())
    assert.same({ ranks = { [0] = true }, raidlead = false }, p:Grants("weights"))
    local before = count(db)
    local ok, err = p:Publish({ weights = { ranks = { [1] = true } } })
    assert.is_false(ok)
    assert.is_truthy(err:find("/gh lbdemo off", 1, true))
    assert.equal(before, count(db))
    assert.equal(0, sent)
    ns.Leaderboard.Demo.Set(ns, false)
    assert.equal(real, lb.permissions)
  end)

  it("demo mode writes no history and History is an empty read", function()
    Demo = ns.Leaderboard.Demo
    Demo.Set(ns, true)
    local before = count(db)
    assert.same({}, lb.config:History())
    assert.is_false((lb.config:PublishWeights({ sales = 9 })))
    assert.equal(before, count(db))
    Demo.Set(ns, false)
    assert.same({}, cfg:History())
  end)
end)
