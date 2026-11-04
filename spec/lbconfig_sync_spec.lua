-- core.config over a fake guild channel: several real LbConfig clients, each with its own roster,
-- exchanging perms and the records that depend on them (final review I1, I2, I4).
describe("Leaderboard Config sync between clients", function()
  local fakes = require("spec.helpers.fakes")
  local T0 = 1793793600 -- 2026-11-04 12:00 UTC
  local TWO_YEARS = 63072000
  local clock, timers, bus

  -- ranks: this client's view of the roster, { [char] = rankIndex }; loaded() says whether it
  -- has loaded (defaults to "has any rank").
  local function client(char, ranks, loaded)
    local ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    for _, f in ipairs({ "Activity", "Scoring", "Config" }) do
      loadAddonFile(ns, "Guildhall/Core/Leaderboard/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    ns.Activity.Register({ id = "sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 1 })
    local roster = {
      HasRanks = function() if loaded then return loaded() end return next(ranks) ~= nil end,
      RankIndex = function(_, n) return ranks[n] end,
      IsOfficer = function(_, n) local r = ranks[n]; if r == nil then return nil end return r < 2 end,
    }
    local log = ns.Log.new({}, clock.now, function() return "" end)
    local cfg = ns.LbConfig.new({ comm = bus:join(char), now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = log, roster = roster,
      profile = { Id = function() return "p" .. char:sub(1, 4) end, OnlineChar = function() end,
        CharsOf = function() return {} end, set = { Get = function() end } },
      compat = { ServerOffset = function() return 0 end }, playerChar = char, db = {}, seenV = {} })
    return cfg
  end

  local function drain(seconds)
    for _ = 1, seconds or 200 do clock.advance(1); timers.run(clock) end
  end

  local function count(set)
    local n = 0
    for _ in pairs(set.store) do n = n + 1 end
    return n
  end

  local function reasons(cfg)
    local out = {}
    for _, e in ipairs(cfg.log.store) do if e.reason then out[#out + 1] = e.id .. ": " .. e.reason end end
    return out
  end

  before_each(function()
    clock = fakes.clock(T0)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
  end)

  it("a departed guild master's weights reach a fresh client, and the new guild master's change wins everywhere", function()
    local oldRanks = { ["Gone-R"] = 0, ["New-R"] = 1, ["Old-R"] = 3 }
    local old = client("Old-R", oldRanks)
    for i = 1, 5 do
      local r = { id = "weights", v = i, t = T0 + i, exp = T0 + 1e8, by = "pGone", char = "Gone-R",
        d = { weights = { sales = 10 + i } } }
      assert.equal("accepted", old.sync:_applyOne(r, "Gone-R"))
    end
    -- Gone leaves and New becomes guild master; New installs fresh
    oldRanks["Gone-R"], oldRanks["New-R"] = nil, 0
    clock.advance(100)
    local fresh = client("New-R", { ["New-R"] = 0, ["Old-R"] = 3 })
    fresh:Start()
    drain()
    assert.equal(15, fresh:Weights().sales)
    assert.equal(5, fresh.set:Get("weights").v)
    assert.is_true((fresh:PublishWeights({ sales = 99 })))
    drain()
    assert.equal(6, old.set:Get("weights").v)
    assert.equal(99, old:Weights().sales)
    assert.equal(99, fresh:Weights().sales)
  end)

  it("GM handover: the heir's fresh-install perms outrank the former GM's v3 on old clients", function()
    local ranks = { ["Prev-R"] = 0, ["Old-R"] = 3 }
    local old = client("Old-R", ranks)
    for i = 1, 3 do
      local r = { id = "perms", v = i, t = T0 + i, exp = T0 + 1e8, by = "pPrev", char = "Prev-R",
        d = { grants = { weights = { ranks = { 0, 1 }, raidlead = false } } } }
      assert.equal("accepted", old.sync:_applyOne(r, "Prev-R"))
    end
    -- handover: Prev stays as rank 1
    ranks["Prev-R"], ranks["Heir-R"] = 1, 0
    clock.advance(10)
    local fresh = client("Heir-R", { ["Heir-R"] = 0, ["Prev-R"] = 1, ["Old-R"] = 3 })
    fresh:Start()
    drain()
    assert.is_nil(fresh.set:Get("perms")) -- the former GM is no longer rank 0 here
    assert.equal(3, fresh.seenV.perms)
    assert.is_true((fresh.perms:Publish({ weights = { ranks = { 0 }, raidlead = false } })))
    assert.equal(4, fresh.set:Get("perms").v)
    drain()
    assert.equal(4, old.set:Get("perms").v)
    assert.is_false(old.perms:Can("Prev-R", "weights"))
    assert.is_false(fresh.perms:Can("Prev-R", "weights"))
  end)

  it("a former guild master's perms stay in effect after they leave, on old and fresh clients", function()
    local gmRanks = { ["Gm-R"] = 0, ["Off-R"] = 1, ["Old-R"] = 3 }
    local gm = client("Gm-R", gmRanks)
    local oldRanks = { ["Gm-R"] = 0, ["Off-R"] = 1, ["Old-R"] = 3 }
    local old = client("Old-R", oldRanks)
    assert.is_true((gm.perms:Publish({ weights = { ranks = { 0, 1 }, raidlead = false } })))
    drain()
    assert.is_true(old.perms:Can("Off-R", "weights"))
    -- the guild master leaves the guild
    gmRanks["Gm-R"], oldRanks["Gm-R"] = nil, nil
    assert.is_true(old.perms:Can("Off-R", "weights"))
    clock.advance(10)
    local fresh = client("New-R", { ["Off-R"] = 1, ["Old-R"] = 3, ["New-R"] = 4 })
    fresh:Start()
    drain()
    assert.is_not_nil(fresh.set:Get("perms"))
    assert.is_true(fresh.perms:Can("Off-R", "weights"))
    -- the officer can still edit weights, and every client takes it
    local off = client("Off-R", { ["Off-R"] = 1, ["Old-R"] = 3, ["New-R"] = 4 })
    off:Start()
    drain()
    clock.advance(70)
    assert.is_true((off:PublishWeights({ sales = 42 })))
    drain()
    for _, c in ipairs({ old, fresh, off }) do assert.equal(42, c:Weights().sales) end
  end)

  it("a granted reviewer's exclusion that arrives before the perms record is stored after the re-sync", function()
    local ranks = { ["Gm-R"] = 0, ["Rev-R"] = 1, ["Fresh-R"] = 4 }
    local gm = client("Gm-R", ranks)
    local ref = "bank:0123456789ab:o1793790000_1"
    local perms = { id = "perms", v = 1, t = T0 - 100, exp = T0 + 1e8, by = "pGm-R", char = "Gm-R",
      d = { grants = { bankreview = { ranks = { 0, 1 }, raidlead = false } } } }
    local ex = { id = "exclude:" .. ref, v = 1, t = T0 - 50, exp = T0 - 50 + TWO_YEARS, by = "pRev", char = "Rev-R",
      d = { ref = ref, excluded = true, by = "Rev-R", at = T0 - 50 } }
    assert.equal("accepted", gm.sync:_applyOne(perms, "Gm-R"))
    assert.equal("accepted", gm.sync:_applyOne(ex, "Rev-R"))
    local fresh = client("Fresh-R", { ["Gm-R"] = 0, ["Rev-R"] = 1, ["Fresh-R"] = 4 })
    -- one REC with both, in Sync's sorted id order: the exclusion is checked before perms lands
    fresh.sync:_onRec({ rs = { ex, perms } }, "Gm-R")
    assert.is_not_nil(fresh.set:Get("perms"))
    assert.is_nil(fresh:Exclusions()[ref])
    assert.same({ "exclude:" .. ref .. ": author lacks permission" }, reasons(fresh))
    -- the accepted perms record started a sync, which asks the guild again
    drain()
    assert.is_not_nil(fresh.set:Get("exclude:" .. ref))
    assert.is_not_nil(fresh:Exclusions()[ref])
  end)

  it("the same exclusion ordering over a real login sync converges", function()
    local gm = client("Gm-R", { ["Gm-R"] = 0, ["Rev-R"] = 1 })
    local rev = client("Rev-R", { ["Gm-R"] = 0, ["Rev-R"] = 1 })
    assert.is_true((gm.perms:Publish({ bankreview = { ranks = { 0, 1 }, raidlead = false } })))
    drain()
    local ref = "bank:0123456789ab:o1793790000_1"
    assert.is_true((rev:SetExcluded(ref, true, "moving funds")))
    drain()
    assert.is_not_nil(gm:Exclusions()[ref])
    local fresh = client("Fresh-R", { ["Gm-R"] = 0, ["Rev-R"] = 1, ["Fresh-R"] = 4 })
    fresh:Start()
    drain(300)
    assert.is_not_nil(fresh:Exclusions()[ref])
    assert.equal(count(gm.set), count(fresh.set))
  end)

  it("records rejected while the roster is unknown arrive once it loads", function()
    local gm = client("Gm-R", { ["Gm-R"] = 0 })
    assert.is_true((gm:PublishWeights({ sales = 8 })))
    local isLoaded = false
    local fresh = client("Fresh-R", { ["Gm-R"] = 0, ["Fresh-R"] = 4 }, function() return isLoaded end)
    fresh:Start()
    drain()
    assert.is_nil(fresh.set:Get("weights"))
    assert.same({ "weights: roster unknown" }, reasons(fresh))
    isLoaded = true
    fresh:OnRosterRefreshed()
    drain(200)
    assert.equal(8, fresh:Weights().sales)
    -- only the change from not loaded to loaded triggers it
    local starts = 0
    fresh.sync.Start = function() starts = starts + 1 end
    fresh:OnRosterRefreshed()
    assert.equal(0, starts)
  end)

  it("a 300-id config converges between two clients through the bucketed digest", function()
    local ranks = { ["Gm-R"] = 0, ["Fresh-R"] = 4 }
    local gm = client("Gm-R", ranks)
    local function put(r) assert.equal("accepted", gm.sync:_applyOne(r, "Gm-R"), r.id) end
    put({ id = "weights", v = 1, t = T0, exp = T0 + 1e8, by = "pGm-R", char = "Gm-R", d = { weights = { sales = 3 } } })
    put({ id = "perms", v = 1, t = T0, exp = T0 + 1e8, by = "pGm-R", char = "Gm-R",
      d = { grants = { bankreview = { ranks = { 0 }, raidlead = false } } } })
    for i = 1, 149 do
      local at = T0 - i * 3 * 86400 -- spread over about 15 months
      local ref = string.format("bank:0123456789ab:o%d_%d", at, i)
      put({ id = "exclude:" .. ref, v = 1, t = at, exp = at + TWO_YEARS, by = "pGm-R", char = "Gm-R",
        d = { ref = ref, excluded = true, by = "Gm-R", at = at } })
      put({ id = string.format("history:pGm-R:%d:%d", at, i), v = 1, t = at, exp = at + TWO_YEARS, by = "pGm-R",
        char = "Gm-R", d = { what = "bank", key = ref, before = {}, after = { excluded = true }, by = "Gm-R", at = at } })
    end
    assert.equal(300, count(gm.set))
    local fresh = client("Fresh-R", { ["Gm-R"] = 0, ["Fresh-R"] = 4 })
    local kinds = {}
    local send = fresh.sync.comm.Send
    fresh.sync.comm.Send = function(c, module, kind, p)
      if module == "core.config" then
        kinds[kind] = (kinds[kind] or 0) + 1
        if kind == "REQ" then assert.is_table(p.days) end -- every digest REQ names its buckets
      end
      return send(c, module, kind, p)
    end
    fresh:Start()
    assert.equal(1, kinds.DAYS)
    assert.is_nil(kinds.REQ)
    drain(600)
    assert.equal(300, count(fresh.set))
    for id, r in pairs(gm.set.store) do
      assert.equal(r.v, fresh.set:Get(id).v, id)
    end
    -- the buckets: "c" plus one "x" and one "h" per month
    local days = fresh.sync:_days()
    assert.is_not_nil(days.c)
    local n = 0
    for _ in pairs(days) do n = n + 1 end
    assert.is_true(n > 20 and n < 40, tostring(n))
    -- a second login sync sends one DAYS and the peer finds nothing to send
    clock.advance(120)
    local before, daysBefore, recs = count(fresh.set), kinds.DAYS, 0
    local onRec = fresh.sync._onRec
    fresh.sync._onRec = function(...) recs = recs + 1; return onRec(...) end
    fresh.sync:Start()
    drain(60)
    assert.equal(before, count(fresh.set))
    assert.equal(daysBefore + 1, kinds.DAYS)
    assert.equal(0, recs)
  end)
end)
