describe("Leaderboard Config", function()
  local fakes = require("spec.helpers.fakes")
  local clock, timers, bus, officers, offset, cfg, ns, ctx, store

  local function utc(y, m, d, h)
    local a = math.floor((14 - m) / 12)
    y, m = y + 4800 - a, m + 12 * a - 3
    local jdn = d + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 32045
    return (jdn - 2440588) * 86400 + (h or 0) * 3600
  end

  local function build(char)
    ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Config.lua")
    ns.Activity.Register({ id = "sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 1 })
    ns.Activity.Register({ id = "gold.earned", label = "Gold earned", unit = "gold", verify = "paired", weight = 0.1, order = 2 })
    store = {}
    ctx = {
      comm = bus:join(char), now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = ns.Log.new({}, clock.now, function() return "" end),
      roster = { IsOfficer = function(_, name) return officers[name] end },
      profile = {
        Id = function() return "pMe" end,
        OnlineChar = function() return nil end,
        CharsOf = function(_, id) return { id .. "-Realm" } end,
        set = { Get = function() return nil end },
      },
      compat = { ServerOffset = function() return offset end },
      playerChar = char, db = store,
    }
    cfg = ns.LbConfig.new(ctx)
    return cfg
  end

  before_each(function()
    clock = fakes.clock(utc(2026, 11, 4, 12))
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    officers = { ["Boss-Realm"] = true, ["Grunt-Realm"] = false }
    offset = 0
    build("Boss-Realm")
  end)

  local function rec(id, v, char, d)
    return { id = id, v = v, t = clock.now(), exp = clock.now() + 1000000, by = "pX", char = char, d = d }
  end
  local function apply(r) return cfg.sync:_applyOne(r, "Sender") end

  local function ledger(byProfile, kept)
    local l = { queries = {} }
    function l:Query(q)
      self.queries[#self.queries + 1] = q
      return { byProfile = byProfile, guild = {}, goldKept = kept or 0 }
    end
    return l
  end

  it("a weights record from a non-officer is rejected", function()
    assert.equal("invalid", apply(rec("weights", 1, "Grunt-Realm", { weights = { sales = 9 } })))
    assert.equal(5, cfg:Weights().sales)
  end)

  it("an unknown roster rejects now and accepts on a later sync", function()
    officers["Boss-Realm"] = nil
    local r = rec("weights", 1, "Boss-Realm", { weights = { sales = 9 } })
    assert.equal("invalid", apply(r))
    assert.is_nil(cfg.set:Get("weights"))
    officers["Boss-Realm"] = true
    assert.equal("accepted", apply(r))
  end)

  it("from an officer it is accepted, and Weights merges defaults", function()
    assert.equal("accepted", apply(rec("weights", 1, "Boss-Realm", { weights = { sales = 9 } })))
    local w = cfg:Weights()
    assert.equal(9, w.sales)
    assert.equal(0.1, w["gold.earned"])
  end)

  it("a demoted officer's earlier record stays in effect (Review Focus 5)", function()
    apply(rec("weights", 1, "Boss-Realm", { weights = { sales = 9 } }))
    officers["Boss-Realm"] = false
    assert.equal(9, cfg:Weights().sales)
    assert.equal("invalid", apply(rec("weights", 2, "Boss-Realm", { weights = { sales = 1 } })))
    assert.equal(9, cfg:Weights().sales)
  end)

  it("a negative or NaN weight is invalid", function()
    for _, bad in ipairs({ -1, 0 / 0, math.huge, 1001, "5" }) do
      assert.equal("invalid", apply(rec("weights", 1, "Boss-Realm", { weights = { sales = bad } })))
      local ok = cfg:PublishWeights({ sales = bad })
      assert.is_false(ok)
    end
    assert.is_nil(cfg.set:Get("weights"))
    assert.is_true((cfg:PublishWeights({ sales = 0 })))
    assert.equal(0, cfg:Weights().sales)
  end)

  it("PublishWeights is officers only and stamps tz", function()
    offset = 3600
    assert.is_true((cfg:PublishWeights({ sales = 7 })))
    assert.equal(3600, cfg:Tz())
    local g = build("Grunt-Realm")
    local ok, err = g:PublishWeights({ sales = 7 })
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("MaybeSaveMonth waits for the 3-day grace", function()
    local l = ledger({ p1 = { sales = 3 } })
    clock.advance(utc(2026, 11, 4, 0) - 1 - clock.now())
    cfg:MaybeSaveMonth(l, clock.now())
    assert.is_nil(cfg:Month("2026-10"))
    clock.advance(1)
    cfg:MaybeSaveMonth(l, clock.now())
    local m = cfg:Month("2026-10")
    assert.is_table(m)
    assert.equal(utc(2026, 10, 1), m.from)
    assert.equal(utc(2026, 11, 1), m.to)
    assert.equal("Boss-Realm", m.savedBy)
    assert.equal("p1", m.overall[1].profile)
    assert.equal("p1", m.overall[1].name)
    assert.equal(15, m.overall[1].value)
    assert.equal(1, m.overall[1].rank)
    assert.equal(3, m.boards.sales[1].value)
    assert.equal(5, m.weights.sales)
    assert.same({ ["2026-10"] = true }, { [cfg:Months()[1]] = true })
  end)

  it("non-officers do not save months", function()
    local g = build("Grunt-Realm")
    clock.advance(utc(2026, 11, 10) - clock.now())
    g:MaybeSaveMonth(ledger({ p1 = { sales = 3 } }), clock.now())
    assert.is_nil(g:Month("2026-10"))
  end)

  it("a second save for the same month is ignored", function()
    clock.advance(utc(2026, 11, 10) - clock.now())
    local l = ledger({ p1 = { sales = 3 } })
    cfg:MaybeSaveMonth(l, clock.now())
    cfg:MaybeSaveMonth(ledger({ p2 = { sales = 99 } }), clock.now())
    assert.equal(1, cfg.set:Get("month:2026-10").v)
    assert.equal("p1", cfg:Month("2026-10").overall[1].profile)
    -- a later version without retake is refused too
    local r = rec("month:2026-10", 2, "Boss-Realm", cfg:Month("2026-10"))
    assert.equal("invalid", apply(r))
    -- an identical redelivery is just stale
    assert.equal("stale", apply(cfg.set:Get("month:2026-10")))
  end)

  it("a retake replaces it", function()
    clock.advance(utc(2026, 11, 10) - clock.now())
    cfg:MaybeSaveMonth(ledger({ p1 = { sales = 3 } }), clock.now())
    clock.advance(10)
    assert.is_true(cfg:RetakeMonth("2026-10", ledger({ p2 = { sales = 4 } })))
    local r = cfg.set:Get("month:2026-10")
    assert.equal(2, r.v)
    assert.is_true(r.d.retake)
    assert.equal("p2", cfg:Month("2026-10").overall[1].profile)
    assert.is_false((build("Grunt-Realm"):RetakeMonth("2026-10", ledger({}))))
    -- a peer accepts the retake over the original
    local peer = build("Boss-Realm")
    clock.advance(0)
    assert.equal("accepted", peer.sync:_applyOne({ id = r.id, v = 1, t = r.t - 10, exp = r.exp, by = r.by, char = r.char,
      d = { month = "2026-10", from = r.d.from, to = r.d.to, tz = 0, goldKept = 0, overall = {}, boards = {},
        weights = {}, savedBy = "Boss-Realm", savedAt = 1 } }, "S"))
    assert.equal("accepted", peer.sync:_applyOne(r, "S"))
  end)

  it("a month record keeps its numbers after weights change", function()
    clock.advance(utc(2026, 11, 10) - clock.now())
    local l = ledger({ p1 = { sales = 3 } })
    cfg:MaybeSaveMonth(l, clock.now())
    assert.is_true((cfg:PublishWeights({ sales = 100 })))
    local m = cfg:Month("2026-10")
    assert.equal(15, m.overall[1].value)
    assert.equal(5, m.weights.sales)
    assert.equal(100, cfg:Weights().sales)
  end)

  it("MaybeRefreshTz republishes only when the offset moves >= 15 min", function()
    offset = 3600
    -- no record yet (an unsynced client): never publishes, so custom weights cannot be wiped
    assert.is_false(cfg:MaybeRefreshTz())
    assert.is_nil(cfg.set:Get("weights"))
    assert.is_true((cfg:PublishWeights({ sales = 8 })))
    assert.equal(1, cfg.set:Get("weights").v)
    offset = 3600 + 899
    cfg:MaybeRefreshTz()
    assert.equal(1, cfg.set:Get("weights").v)
    offset = 3600 + 900
    clock.advance(1)
    cfg:MaybeRefreshTz()
    local r = cfg.set:Get("weights")
    assert.equal(2, r.v)
    assert.equal(4500, cfg:Tz())
    assert.equal(8, cfg:Weights().sales)
    offset = nil
    cfg:MaybeRefreshTz()
    assert.equal(2, cfg.set:Get("weights").v)
  end)

  local function drain() for _ = 1, 20 do clock.advance(10); timers.run(clock) end end
  local function bigMonth(m)
    local function t5()
      local o = {}
      for i = 1, 5 do
        o[i] = { profile = string.format("%016x", 0xabcdef000000 + i), name = string.rep("N", 40) .. i,
          value = 123456789.123, rank = i }
      end
      return o
    end
    local ym = string.format("2026-%02d", m)
    local b = {}
    for i = 1, 16 do b["board.number" .. i] = t5() end
    local w = {}
    for i = 1, 32 do w["weight.type.number" .. i] = 0.15 end
    return ym, { month = ym, from = 1000 * m, to = 1000 * m + 999, tz = 0, goldKept = 1234567,
      overall = t5(), boards = b, weights = w, savedBy = "Officer-Realm", savedAt = 1 }
  end

  it("a fresh client receives all 7 saved months", function()
    bus = fakes.bus(clock, timers, { burst = 10, refill = 1 })   -- production pacing
    local a = build("Boss-Realm")
    for m = 4, 10 do
      local ym, d = bigMonth(m)
      assert.is_true(a.set:Apply(rec("month:" .. ym, 1, "Boss-Realm", d)) == "accepted")
    end
    local d = build("Grunt-Realm")
    d.sync:Start()
    for _ = 1, 3000 do clock.advance(1); timers.run(clock) end
    assert.equal(7, #d:Months())
    assert.equal(7, #a:Months())
  end)

  it("a payload at the bounds is valid and one past them is not", function()
    local ym, d = bigMonth(5)
    assert.equal("accepted", apply(rec("month:" .. ym, 1, "Boss-Realm", d)))
    local _, d2 = bigMonth(6)
    d2.boards["one.too.many"] = d2.boards["board.number1"]
    assert.equal("invalid", apply(rec("month:2026-06", 1, "Boss-Realm", d2)))
    local _, d3 = bigMonth(7)
    d3.weights["extra"] = 1
    assert.equal("invalid", apply(rec("month:2026-07", 1, "Boss-Realm", d3)))
    local _, d4 = bigMonth(8)
    d4.overall[1].profile = string.rep("x", 17)
    assert.equal("invalid", apply(rec("month:2026-08", 1, "Boss-Realm", d4)))
    local _, d5 = bigMonth(9)
    d5.overall[1].rank = 6
    assert.equal("invalid", apply(rec("month:2026-09", 1, "Boss-Realm", d5)))
    local _, d6 = bigMonth(10)
    d6.overall[1].value = 1e13
    assert.equal("invalid", apply(rec("month:2026-10", 1, "Boss-Realm", d6)))
    local _, d7 = bigMonth(11)
    d7.overall[1].rank = 1.5
    assert.equal("invalid", apply(rec("month:2026-11", 1, "Boss-Realm", d7)))
    assert.equal("invalid", apply(rec("weights", 1, "Boss-Realm", { weights = (function()
      local w = {}
      for i = 1, 33 do w["t" .. i] = 1 end
      return w
    end)() })))
  end)

  it("two officers save the same month concurrently and all clients converge on the earliest, with no rejected-log spam", function()
    officers["Other-Realm"] = true
    local a = build("Boss-Realm")
    local b = build("Other-Realm")
    local c = build("Grunt-Realm")
    clock.advance(utc(2026, 11, 10) - clock.now())
    a:MaybeSaveMonth(ledger({ pA = { sales = 3 } }), clock.now())
    clock.advance(100)
    b:MaybeSaveMonth(ledger({ pB = { sales = 3 } }), clock.now())
    for _ = 1, 3 do
      for _, x in ipairs({ a, b, c }) do x.sync:Start(); drain(); clock.advance(400) end
    end
    for _, x in ipairs({ a, b, c }) do
      assert.equal("pA", x:Month("2026-10").overall[1].profile)
      for _, e in ipairs(x.ctx.log.store) do assert.not_equal("rejected", e.result) end
    end
  end)

  it("first login on 2026-12-10 saves October and November", function()
    local _, sept = bigMonth(9)
    assert.equal("accepted", apply(rec("month:2026-09", 1, "Boss-Realm", sept)))
    clock.advance(utc(2026, 12, 10) - clock.now())
    cfg:MaybeSaveMonth(ledger({ p1 = { sales = 3 } }), clock.now())
    assert.same({ "2026-11", "2026-10", "2026-09" }, cfg:Months())
    assert.equal(15, cfg:Month("2026-11").overall[1].value)
  end)

  it("catch-up stops at months older than the retention window", function()
    clock.advance(utc(2028, 12, 10) - clock.now())
    cfg:MaybeSaveMonth(ledger({ p1 = { sales = 3 } }), clock.now())
    local months = cfg:Months()
    assert.is_true(#months >= 10 and #months <= 13)
    assert.equal("2028-11", months[1])
    for _, ym in ipairs(months) do assert.is_true(cfg:Month(ym).from >= clock.now() - 34560000) end
  end)

  it("first login on an empty ledger saves no months; once activity exists, only months with activity are saved", function()
    clock.advance(utc(2026, 12, 10) - clock.now())
    cfg:MaybeSaveMonth(ledger({}), clock.now())
    assert.same({}, cfg:Months())
    local l = { Query = function(_, q)
      if q.from == utc(2026, 11, 1) then return { byProfile = { p1 = { sales = 3 } }, guild = {}, goldKept = 0 } end
      return { byProfile = {}, guild = {}, goldKept = 0 }
    end }
    cfg:MaybeSaveMonth(l, clock.now())
    assert.same({ "2026-11" }, cfg:Months())
  end)

  it("Month returns a copy", function()
    clock.advance(utc(2026, 11, 10) - clock.now())
    cfg:MaybeSaveMonth(ledger({ p1 = { sales = 3 } }), clock.now())
    cfg:Month("2026-10").overall[1].value = 999
    assert.equal(15, cfg:Month("2026-10").overall[1].value)
  end)

  it("rejects unknown id prefixes and malformed month payloads", function()
    assert.equal("invalid", apply(rec("bogus", 1, "Boss-Realm", {})))
    assert.equal("invalid", apply(rec("month:2026-10", 1, "Boss-Realm", { month = "2026-09" })))
    assert.equal("invalid", apply(rec("month:2026-10", 1, "Boss-Realm", "x")))
  end)
end)
