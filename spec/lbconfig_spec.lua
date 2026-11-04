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
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    ns.Activity.Register({ id = "sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 1 })
    ns.Activity.Register({ id = "gold.earned", label = "Gold earned", unit = "gold", verify = "paired", weight = 0.1, order = 2 })
    store = {}
    ctx = {
      comm = bus:join(char), now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = ns.Log.new({}, clock.now, function() return "" end),
      -- An officer here is rank 0 (the guild master), who holds every permission by default;
      -- spec/permissions_spec.lua covers the other ranks.
      roster = { IsOfficer = function(_, name) return officers[name] end,
        HasRanks = function() return true end,
        RankIndex = function(_, name) if officers[name] ~= nil then return officers[name] and 0 or 5 end end },
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

  it("WeightsInfo names the author character and the real publish time", function()
    assert.is_nil(cfg:WeightsInfo())
    clock.advance(500)
    assert.is_true((cfg:PublishWeights({ sales = 7 })))
    assert.same({ char = "Boss-Realm", at = clock.now() }, cfg:WeightsInfo())
  end)

  it("PublishWeights stores who changed it and when, and a tz refresh keeps both", function()
    offset = 0
    clock.advance(100)
    assert.is_true((cfg:PublishWeights({ sales = 7 })))
    local at = clock.now()
    local d = cfg.set:Get("weights").d
    assert.equal("Boss-Realm", d.changedBy)
    assert.equal(at, d.changedAt)
    clock.advance(5000)
    offset = 3600
    assert.is_true(cfg:MaybeRefreshTz())
    assert.same({ char = "Boss-Realm", at = at }, cfg:WeightsInfo())
    assert.equal(3600, cfg:Tz())
  end)

  it("WeightsInfo falls back to the record's author and time for older records", function()
    assert.equal("accepted", apply(rec("weights", 1, "Boss-Realm", { weights = { sales = 9 } })))
    assert.same({ char = "Boss-Realm", at = clock.now() }, cfg:WeightsInfo())
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
    assert.equal("accepted", peer.sync:_applyOne({ id = r.id, v = 1, t = r.d.to, exp = r.exp, by = r.by, char = r.char,
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
    -- the month ends now, so a v1 record stamped now is an honest save time (t <= to + grace)
    local to = clock.now() + m
    return ym, { month = ym, from = to - 999, to = to, tz = 0, goldKept = 1234567,
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
  describe("change history", function()
    local TWO_YEARS = 63072000
    local function ids()
      local out = {}
      for _, r in ipairs(cfg.set:List(false)) do
        if r.id:match("^history:") then out[#out + 1] = r end
      end
      return out
    end
    local function hrec(id, v, char, d, t)
      t = t or clock.now()
      return { id = id, v = v, t = t, exp = t + TWO_YEARS, by = "pX", char = char, d = d }
    end
    local function hd(char, at)
      return { what = "weights", before = { sales = 5 }, after = { sales = 9 }, by = char, at = at or clock.now() }
    end

    it("a weights change writes one history record", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      local h = ids()
      assert.equal(1, #h)
      local r = h[1]
      assert.equal("history:pMe:" .. clock.now() .. ":1", r.id)
      assert.equal("weights", r.d.what)
      assert.equal("Boss-Realm", r.d.by)
      assert.equal(clock.now(), r.d.at)
      assert.equal(9, r.d.after.sales)
      assert.equal(5, r.d.before.sales)
      assert.equal(r.t + TWO_YEARS, r.exp)
    end)

    it("two changes in the same second get different ids", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      assert.is_true((cfg:PublishWeights({ sales = 8 })))
      assert.equal(2, #ids())
    end)

    it("a second version of a history id is rejected", function()
      local id = "history:pX:" .. clock.now() .. ":1"
      assert.equal("accepted", apply(hrec(id, 1, "Boss-Realm", hd("Boss-Realm"))))
      local second = hrec(id, 2, "Boss-Realm", hd("Boss-Realm"))
      second.d.after = { sales = 1 }
      assert.equal("invalid", apply(second))
      assert.equal(9, cfg.set:Get(id).d.after.sales)
    end)

    it("history from a non-member is rejected, from a demoted officer accepted", function()
      local id = "history:pX:" .. clock.now() .. ":1"
      assert.equal("invalid", apply(hrec(id, 1, "Stranger-Realm", hd("Stranger-Realm"))))
      assert.is_nil(cfg.set:Get(id))
      officers["Grunt-Realm"] = false -- a member who is not (or no longer) an officer
      assert.equal("accepted", apply(hrec(id, 1, "Grunt-Realm", hd("Grunt-Realm"))))
      local h = cfg:History()
      assert.is_false(cfg:HistoryAuthorPermitted(h[1]))
      assert.is_true(cfg:HistoryAuthorPermitted({ by = "Boss-Realm" }))
    end)

    it("history is accepted while the roster is not loaded yet", function()
      ctx.roster.HasRanks = function() return false end
      local id = "history:pX:" .. clock.now() .. ":1"
      assert.equal("accepted", apply(hrec(id, 1, "Stranger-Realm", hd("Stranger-Realm"))))
    end)

    it("only an identical copy of an existing history record is tolerated", function()
      local id = "history:pX:" .. clock.now() .. ":1"
      assert.equal("accepted", apply(hrec(id, 1, "Boss-Realm", hd("Boss-Realm"))))
      assert.equal("stale", apply(hrec(id, 1, "Boss-Realm", hd("Boss-Realm"))))
      local otherChar = hrec(id, 1, "Grunt-Realm", hd("Grunt-Realm"))
      officers["Grunt-Realm"] = true
      assert.equal("invalid", apply(otherChar))
      local otherD = hrec(id, 1, "Boss-Realm", hd("Boss-Realm"))
      otherD.d.after = { sales = 1 }
      assert.equal("invalid", apply(otherD))
      assert.equal("Boss-Realm", cfg.set:Get(id).char)
      assert.equal(9, cfg.set:Get(id).d.after.sales)
    end)

    it("stores only the keys that changed", function()
      assert.is_true((cfg:PublishWeights({ sales = 9, ["gold.earned"] = 0.1 })))
      local r = ids()[1]
      assert.same({ sales = 5 }, r.d.before)
      assert.same({ sales = 9 }, r.d.after)
    end)

    it("History skips expired records", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      local r = ids()[1]
      cfg.set.store[r.id].exp = clock.now()
      assert.equal(0, #cfg:History())
    end)

    it("an invalid history record is logged and not published, and the change stands", function()
      local ok = cfg:PublishWeights({ sales = 9 })
      assert.is_true(ok)
      local n = #ids()
      ctx.profile.Id = function() return string.rep("x", 17) end -- a history id the validator refuses
      assert.is_true((cfg:PublishWeights({ sales = 8 })))
      assert.equal(n, #ids())
      assert.equal(8, cfg:Weights().sales)
    end)

    it("a failing history write never escapes the publish", function()
      local errs = {}
      ns.OnError = function(e) errs[#errs + 1] = e end
      cfg._logHistory = function() error("boom") end
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      assert.equal(1, #errs)
    end)

    it("a relayed history record is accepted verbatim by a third client", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      local stored = cfg.set:Get(ids()[1].id)
      local b = build("Grunt-Realm")
      assert.equal("accepted", b.sync:_applyOne(stored, "Boss"))
      local relayed = b.set:Get(stored.id)
      local c = build("Boss-Realm")
      assert.equal("accepted", c.sync:_applyOne(relayed, "Grunt"))
      assert.same(stored.d, c.set:Get(stored.id).d)
    end)

    it("rejects malformed history records", function()
      local now = clock.now()
      local id = "history:pX:" .. now .. ":1"
      assert.equal("invalid", apply(hrec(id, 1, "Boss-Realm", { what = "bogus", by = "Boss-Realm", at = now })))
      assert.equal("invalid", apply(hrec(id, 1, "Boss-Realm", hd("Other-Realm")))) -- by must be the author
      local noexp = hrec(id, 1, "Boss-Realm", hd("Boss-Realm")); noexp.exp = noexp.exp + 1
      assert.equal("invalid", apply(noexp))
      local deleted = hrec(id, 1, "Boss-Realm", hd("Boss-Realm")); deleted.del = true
      assert.equal("invalid", apply(deleted))
      local bad = hd("Boss-Realm"); bad.after = { sales = -1 }
      assert.equal("invalid", apply(hrec(id, 1, "Boss-Realm", bad)))
    end)

    it("History is listed newest first", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      clock.advance(100)
      assert.is_true((cfg:PublishWeights({ sales = 8 })))
      clock.advance(100)
      assert.is_true((cfg:PublishWeights({ sales = 7 })))
      local h = cfg:History()
      assert.equal(3, #h)
      assert.equal(7, h[1].after.sales)
      assert.equal(8, h[2].after.sales)
      assert.equal(9, h[3].after.sales)
      assert.is_true(h[1].at > h[2].at)
    end)

    it("History returns copies", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      cfg:History()[1].after.sales = 1
      assert.equal(9, cfg:History()[1].after.sales)
    end)

    it("a refused publish writes no history", function()
      local g = build("Grunt-Realm")
      assert.is_false((g:PublishWeights({ sales = 9 })))
      assert.is_false((g:RetakeMonth("2026-10", ledger({}))))
      assert.equal(0, #g:History())
      local b = build("Boss-Realm")
      assert.is_false((b:PublishWeights({ sales = 5000 })))
      assert.is_false((b:RetakeMonth("2026-09", ledger({}))))
      assert.equal(0, #b:History())
    end)

    it("a month retake writes a summary record", function()
      clock.advance(utc(2026, 11, 10) - clock.now())
      cfg:MaybeSaveMonth(ledger({ p1 = { sales = 3 } }), clock.now())
      assert.equal(0, #cfg:History()) -- the automatic save is not an officer decision
      local savedAt = cfg:Month("2026-10").savedAt
      clock.advance(10)
      assert.is_true(cfg:RetakeMonth("2026-10", ledger({ p2 = { sales = 4 } })))
      local h = cfg:History()
      assert.equal(1, #h)
      assert.equal("month", h[1].what)
      assert.equal("2026-10", h[1].key)
      assert.same({ savedBy = "Boss-Realm", savedAt = savedAt }, h[1].before)
      assert.same({ savedBy = "Boss-Realm", savedAt = clock.now() }, h[1].after)
    end)

    it("MaybeRefreshTz writes no history", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      assert.equal(1, #cfg:History())
      clock.advance(10)
      offset = 3600
      assert.is_true(cfg:MaybeRefreshTz())
      assert.equal(1, #cfg:History())
    end)

    it("history survives the retention window of 2 years and then purges", function()
      assert.is_true((cfg:PublishWeights({ sales = 9 })))
      clock.advance(TWO_YEARS - 10)
      cfg.set:Purge()
      assert.equal(1, #cfg:History())
      clock.advance(20)
      cfg.set:Purge()
      assert.equal(0, #cfg:History())
    end)
  end)

  describe("bank exclusions", function()
    local TWO_YEARS = 63072000
    local REF = "bank:o42"
    local contribs

    local function xrec(v, char, d, t)
      t = t or clock.now()
      d = d or {}
      local data = { ref = REF, excluded = true, by = char, at = t }
      for k, val in pairs(d) do data[k] = val end
      return { id = "exclude:" .. (data.ref or REF), v = v, t = t, exp = t + TWO_YEARS, by = "pX", char = char, d = data }
    end
    local function hist()
      local out = {}
      for _, e in ipairs(cfg:History()) do if e.what == "bank" then out[#out + 1] = e end end
      return out
    end
    -- A real Ledger over fixed bank contributions, reading exclusions from cfg.
    local function realLedger()
      loadAddonFile(ns, "Guildhall/Core/Leaderboard/Ledger.lua")
      ns.Observations = { KINDS = { bank = true } }
      ns.Activity.Register({ id = "bank.gold", label = "Bank gold", unit = "gold", verify = "paired", weight = 0.2, order = 60 })
      ns.Activity.RegisterDeriver("bank", function() return contribs end)
      local owners = { ["Bob-Realm"] = "pBob", ["Cat-Realm"] = "pCat" }
      return ns.Ledger.new({
        observations = { List = function() return { {} } end, changes = 0 },
        profile = {
          OwnerOf = function(_, ch) return owners[ch] end,
          CharsOf = function(_, id) return id == "pBob" and { "Bob-Realm" } or id == "pCat" and { "Cat-Realm" } or {} end,
          OnlineChar = function() return nil end,
          set = { Get = function() return nil end },
        },
        roster = { RankIndex = function() return nil end, ConfigList = function() return {} end },
        now = clock.now, config = cfg,
      })
    end

    before_each(function()
      contribs = {
        { type = "bank.gold", char = "Bob-Realm", value = 500000, at = utc(2026, 10, 5), ref = REF, counted = true, net = true },
        { type = "bank.gold", char = "Cat-Realm", value = 200000, at = utc(2026, 10, 6), ref = "bank:o43", counted = true, net = true },
      }
    end)

    it("an officer's exclusion removes the entry from the member's total but not the guild total", function()
      local l = realLedger()
      assert.equal(500000, l:Query({}).byProfile.pBob["bank.gold"])
      assert.is_true((cfg:SetExcluded(REF, true, "moving guild funds")))
      local r = l:Query({})
      assert.is_nil(r.byProfile.pBob)
      assert.equal(200000, r.byProfile.pCat["bank.gold"])
      assert.equal(700000, r.guild["bank.gold"])
      assert.equal(700000, r.goldKept)
    end)

    it("re-ticking restores it", function()
      local l = realLedger()
      assert.is_true((cfg:SetExcluded(REF, true, "oops")))
      clock.advance(5)
      assert.is_true((cfg:SetExcluded(REF, false)))
      assert.same({}, cfg:Exclusions())
      assert.equal(500000, l:Query({}).byProfile.pBob["bank.gold"])
      local rec = cfg.set:Get("exclude:" .. REF)
      assert.equal(2, rec.v)
      assert.is_false(rec.d.excluded)
      assert.is_nil(rec.d.reason)
      assert.equal(rec.t + TWO_YEARS, rec.exp)
    end)

    it("an exclusion record from a rank without bankreview is rejected; granting the rank makes it accepted", function()
      local r = xrec(1, "Grunt-Realm")
      assert.equal("invalid", apply(r))
      assert.is_nil(cfg.set:Get(r.id))
      assert.is_true((cfg.perms:Publish({ bankreview = { ranks = { [5] = true } } })))
      assert.equal("accepted", apply(r))
      assert.same({ [REF] = { excluded = true, by = "Grunt-Realm", at = r.t } }, cfg:Exclusions())
    end)

    it("an unknown roster rejects an exclusion now and accepts it on a later sync", function()
      officers["Boss-Realm"] = nil
      local r = xrec(1, "Boss-Realm")
      assert.equal("invalid", apply(r))
      local last = ctx.log:Query()[1]
      assert.equal("roster unknown", last.reason)
      officers["Boss-Realm"] = true
      assert.equal("accepted", apply(r))
    end)

    it("each change writes one history record what=bank", function()
      assert.is_true((cfg:SetExcluded(REF, true, "  moving guild funds  ")))
      local h = hist()
      assert.equal(1, #h)
      assert.equal(REF, h[1].key)
      assert.same({ excluded = false }, h[1].before)
      assert.same({ excluded = true, reason = "moving guild funds" }, h[1].after)
      clock.advance(10)
      assert.is_true((cfg:SetExcluded(REF, false)))
      h = hist()
      assert.equal(2, #h)
      assert.same({ excluded = true, reason = "moving guild funds" }, h[1].before)
      assert.same({ excluded = false }, h[1].after)
      -- a change that changes nothing publishes nothing
      local v = cfg.set:Get("exclude:" .. REF).v
      assert.is_true((cfg:SetExcluded(REF, false)))
      assert.equal(2, #hist())
      assert.equal(v, cfg.set:Get("exclude:" .. REF).v)
      -- only the reason changes: excluded is left out of both sides
      assert.is_true((cfg:SetExcluded(REF, true, "a")))
      clock.advance(10)
      assert.is_true((cfg:SetExcluded(REF, true, "b")))
      h = hist()
      assert.same({ reason = "a" }, h[1].before)
      assert.same({ reason = "b" }, h[1].after)
      assert.is_true(cfg:HistoryAuthorPermitted(h[1]))
    end)

    it("stores the reason trimmed, an empty reason as nil, and cuts a long one to 80 bytes", function()
      assert.is_true((cfg:SetExcluded(REF, true, "   ")))
      assert.is_nil(cfg.set:Get("exclude:" .. REF).d.reason)
      assert.is_true((cfg:SetExcluded("bank:o43", true, string.rep("a", 79) .. "\195\169x")))
      local reason = cfg.set:Get("exclude:bank:o43").d.reason
      assert.equal(string.rep("a", 79), reason) -- never splits a UTF-8 character
      assert.is_true((cfg:SetExcluded("bank:o44", true, string.rep("b", 100))))
      assert.equal(80, #cfg.set:Get("exclude:bank:o44").d.reason)
    end)

    it("SetExcluded needs bankreview and a bank ref", function()
      local g = build("Grunt-Realm")
      local ok, err = g:SetExcluded(REF, true)
      assert.is_false(ok)
      assert.equal("no permission", err)
      assert.is_nil(g.set:Get("exclude:" .. REF))
      assert.equal(0, #g:History())
      build("Boss-Realm")
      assert.is_false((cfg:SetExcluded("trade:o1", true)))
      assert.is_false((cfg:SetExcluded("bank:" .. string.rep("x", 44), true)))
      assert.is_false((cfg:SetExcluded(REF, "yes")))
      assert.is_false((cfg:SetExcluded("bank:o1\n", true)))
      assert.is_false((cfg:SetExcluded("bank:o 1", true)))
      assert.equal(0, #cfg:History())
      -- a real observation id (Observations _nextId: "<profile hex>:o<time>_<n>")
      assert.is_true((cfg:SetExcluded("bank:0a1b2c3d4e5f:o1793793600_12", true)))
    end)

    it("rejects malformed exclusion records", function()
      local t = clock.now()
      local function bad(r) assert.equal("invalid", apply(r)) end
      local r
      r = xrec(1, "Boss-Realm"); r.id = "exclude:trade:o1"; r.d.ref = "trade:o1"; bad(r)
      r = xrec(1, "Boss-Realm"); local long = "bank:" .. string.rep("x", 44); r.id = "exclude:" .. long; r.d.ref = long; bad(r)
      r = xrec(1, "Boss-Realm"); r.d.ref = "bank:o99"; bad(r) -- d.ref must match the id
      r = xrec(1, "Boss-Realm"); r.id = "exclude:bank:o1\n"; r.d.ref = "bank:o1\n"; bad(r)
      bad(xrec(1, "Boss-Realm", { excluded = "true" }))
      bad(xrec(1, "Boss-Realm", { reason = string.rep("r", 81) }))
      bad(xrec(1, "Boss-Realm", { reason = " padded" }))
      bad(xrec(1, "Boss-Realm", { reason = "" }))
      bad(xrec(1, "Boss-Realm", { reason = 5 }))
      bad(xrec(1, "Boss-Realm", { by = "Other-Realm" }))
      bad(xrec(1, "Boss-Realm", { at = t - 1 }))
      bad(xrec(1, "Boss-Realm", { extra = 1 }))
      r = xrec(1, "Boss-Realm"); r.exp = r.exp + 1; bad(r)
      r = xrec(1, "Boss-Realm"); r.d = "x"; bad(r)
      r = xrec(1, "Boss-Realm"); r.del = true; bad(r)
      assert.same({}, cfg:Exclusions())
      -- the good one, at the bounds
      assert.equal("accepted", apply(xrec(1, "Boss-Realm", { reason = string.rep("r", 80) })))
    end)

    it("a newer version wins and Exclusions lists only excluded refs", function()
      assert.equal("accepted", apply(xrec(1, "Boss-Realm", { reason = "x" })))
      clock.advance(1)
      assert.equal("accepted", apply(xrec(2, "Boss-Realm", { excluded = false })))
      assert.equal("stale", apply(xrec(1, "Boss-Realm", { reason = "x" }, clock.now() - 1)))
      assert.same({}, cfg:Exclusions())
      local e = cfg:Exclusions()
      e.x = 1
      assert.is_nil(cfg:Exclusions().x)
    end)

    it("rejects malformed bank history records", function()
      local now = clock.now()
      local id = "history:pX:" .. now .. ":1"
      local function h(d)
        d.what, d.by, d.at = "bank", "Boss-Realm", now
        return { id = id, v = 1, t = now, exp = now + TWO_YEARS, by = "pX", char = "Boss-Realm", d = d }
      end
      assert.equal("invalid", apply(h({ key = "trade:o1", before = {}, after = { excluded = true } })))
      assert.equal("invalid", apply(h({ key = REF, before = { excluded = "no" }, after = {} })))
      assert.equal("invalid", apply(h({ key = REF, before = {}, after = { reason = string.rep("r", 81) } })))
      assert.equal("invalid", apply(h({ key = REF, before = {}, after = { other = 1 } })))
      assert.equal("invalid", apply(h({ before = {}, after = {} })))
      assert.equal("accepted", apply(h({ key = REF, before = { excluded = false }, after = { excluded = true, reason = "x" } })))
    end)

    it("an exclusion survives two years and then purges", function()
      assert.is_true((cfg:SetExcluded(REF, true)))
      clock.advance(TWO_YEARS - 10)
      cfg.set:Purge()
      assert.is_not_nil(cfg:Exclusions()[REF])
      clock.advance(20)
      cfg.set:Purge()
      assert.same({}, cfg:Exclusions())
    end)

    it("an excluded entry inside a saved month leaves the month record unchanged", function()
      local l = realLedger()
      clock.advance(utc(2026, 11, 10) - clock.now())
      assert.is_true(cfg:MaybeSaveMonth(l, clock.now()))
      local before = cfg:Month("2026-10")
      assert.equal("pBob", before.overall[1].profile)
      assert.equal(2, #before.boards["bank.gold"])
      assert.is_true((cfg:SetExcluded(REF, true, "moving guild funds")))
      assert.same(before, cfg:Month("2026-10"))
      assert.is_false(cfg:MaybeSaveMonth(l, clock.now()))
      assert.same(before, cfg:Month("2026-10"))
      -- a retake picks the exclusion up
      clock.advance(10)
      assert.is_true(cfg:RetakeMonth("2026-10", l))
      local after = cfg:Month("2026-10")
      assert.equal(1, #after.boards["bank.gold"])
      assert.equal("pCat", after.overall[1].profile)
      assert.equal(700000, after.goldKept)
    end)
  end)
end)
