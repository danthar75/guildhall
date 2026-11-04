describe("Ledger", function()
  local ns, obsList, changes, ctx, ranks, config, owners, chars, ledger
  local DAY = 86400

  local function c(t)
    local x = { type = "listings", value = 1, at = 100, ref = "r" .. tostring(math.random(1e6)), counted = true }
    for k, v in pairs(t) do x[k] = v end
    return x
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Ledger.lua")
    ns.Observations = { KINDS = { fake = true, bank = true } }
    obsList, changes, ranks, config, owners, chars = {}, 0, {}, {}, {}, {}
    ctx = {
      activity = ns.Activity,
      observations = { List = function(_, kind) return obsList[kind] or {} end, changes = 0 },
      profile = {
        OwnerOf = function(_, ch) return owners[ch] end,
        CharsOf = function(_, id) return chars[id] or {} end,
      },
      roster = {
        RankIndex = function(_, ch) return ranks[ch] end,
        ConfigList = function(_, k) return config[k] or {} end,
      },
      now = function() return 1000 end,
    }
    for _, id in ipairs({ "listings", "sales", "bank.gold", "bank.items", "exchange.gold.earned" }) do
      ns.Activity.Register({ id = id, label = id, unit = "count", verify = "paired", weight = 1, order = 1 })
    end
    owners["Ann-R"], chars.ann = "ann", { "Ann-R", "Ann2-R" }
    owners["Bob-R"], chars.bob = "bob", { "Bob-R" }
    owners["Ann2-R"] = "ann"
    local contribs = {}
    ns.Activity.RegisterDeriver("fake", function() return contribs end)
    ns.Activity.RegisterDeriver("bank", function() return {} end)
    obsList.fake = { {} }
    ctx.contribs = contribs
    ledger = ns.Ledger.new(ctx)
  end)

  local function add(t) table.insert(ctx.contribs, c(t)) end

  it("Contributions lists the observations once and hands each deriver its kind", function()
    local recs = { { id = "a", d = { kind = "fake" } }, { id = "b", d = { kind = "bank" } },
      { id = "c", d = { kind = "fake" } } }
    local calls = 0
    ctx.observations = { changes = 0, List = function(_, kind)
      calls = calls + 1
      local out = {}
      for _, r in ipairs(recs) do if kind == nil or r.d.kind == kind then out[#out + 1] = r end end
      return out
    end }
    local seen = {}
    ns.Activity.RegisterDeriver("fake", function(list, dctx)
      seen.fake = list
      seen.bankFromCtx = dctx.observations:List("bank")
      seen.roster = dctx.roster
      return {}
    end)
    ns.Activity.RegisterDeriver("bank", function(list) seen.bank = list; return {} end)
    ledger = ns.Ledger.new(ctx)
    ledger:Contributions()
    assert.equal(1, calls)
    assert.same({ "a", "c" }, { seen.fake[1].id, seen.fake[2].id })
    assert.equal(2, #seen.fake)
    assert.equal("b", seen.bank[1].id)
    assert.equal("b", seen.bankFromCtx[1].id)
    assert.equal(ctx.roster, seen.roster) -- the rest of ctx passes through
  end)

  it("Query sums by profile and type inside [from, to)", function()
    add({ profile = "ann", at = 99 })
    add({ profile = "ann", at = 100 })
    add({ profile = "ann", at = 150, value = 2 })
    add({ profile = "bob", at = 150 })
    add({ profile = "ann", at = 200 })
    local r = ledger:Query({ from = 100, to = 200 })
    assert.equal(3, r.byProfile.ann.listings)
    assert.equal(1, r.byProfile.bob.listings)
    assert.equal(4, r.guild.listings)
    assert.is_nil(r.rows)
    local all = ledger:Query({})
    assert.equal(6, all.guild.listings)
    assert.is_nil(ledger:Query({ types = { sales = true } }).guild.listings)
  end)

  it("net types floor at 0 per player per window", function()
    add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, at = 10 })
    add({ type = "bank.gold", char = "Ann2-R", value = -150, net = true, at = 20 })
    add({ type = "bank.items", char = "Ann-R", item = 7, value = 5, net = true, at = 10 })
    add({ type = "bank.items", char = "Ann-R", item = 7, value = -2, net = true, at = 20 })
    local r = ledger:Query({})
    assert.equal(0, r.byProfile.ann["bank.gold"])
    assert.equal(3, r.byProfile.ann["bank.items"])
    assert.equal(3, r.guild["bank.items"])
    assert.equal(0, r.goldKept)
    -- the window decides what nets
    local w = ledger:Query({ to = 15 })
    assert.equal(100, w.byProfile.ann["bank.gold"])
    assert.equal(100, w.goldKept)
  end)

  it("net is per item id", function()
    add({ type = "bank.items", char = "Ann-R", item = 1, value = 5, net = true })
    add({ type = "bank.items", char = "Ann-R", item = 2, value = -9, net = true })
    add({ type = "bank.items", char = "Bob-R", item = 2, value = 4, net = true })
    local r = ledger:Query({})
    assert.equal(5, r.byProfile.ann["bank.items"])
    assert.equal(4, r.byProfile.bob["bank.items"])
    assert.equal(9, r.guild["bank.items"])
  end)

  it("excluded rank and uncounted tab go to rows with why and not to totals", function()
    config.bankexclude, config.donations = { 0 }, { 3 }
    ranks["Ann-R"], ranks["Bob-R"] = 0, 5
    add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, tab = 3 })
    add({ type = "bank.gold", char = "Bob-R", value = 50, net = true, tab = 3 })
    add({ type = "bank.gold", char = "Bob-R", value = 70, net = true, tab = 4 })
    add({ profile = "bob", counted = false, why = "unpaired" })
    local r = ledger:Query({})
    assert.is_nil(r.byProfile.ann)
    assert.equal(50, r.byProfile.bob["bank.gold"])
    assert.equal(50, r.guild["bank.gold"])
    assert.is_nil(r.guild.listings)
    assert.equal(50, r.goldKept)
    local rows = ledger:Query({ includeUncounted = true }).rows
    local why = {}
    for _, row in ipairs(rows) do why[#why + 1] = row.why or "ok" end
    table.sort(why)
    assert.same({ "ok", "rank excluded", "tab not counted", "unpaired" }, why)
    -- cache must not be mutated by the query
    assert.is_true(ctx.contribs[1].counted)
    -- explicit overrides
    local o = ledger:Query({ excludeRanks = {}, tabs = { [4] = true } })
    assert.equal(70, o.guild["bank.gold"])
  end)

  it("unlinked char counts in guild only (Review Focus 2)", function()
    owners["Ghost-R"] = nil
    add({ type = "bank.gold", char = "Ghost-R", value = 40, net = true })
    -- an excluded alt: owner unresolved
    owners["Alt-R"] = nil
    add({ type = "bank.gold", char = "Alt-R", value = 60, net = true })
    -- owner says ann but her record does not list the char
    owners["Odd-R"] = "ann"
    add({ type = "bank.gold", char = "Odd-R", value = 5, net = true })
    local r = ledger:Query({})
    assert.same({}, r.byProfile)
    assert.equal(105, r.guild["bank.gold"])
    assert.equal(105, r.goldKept)
    -- unknown rank is not excluded, even with bankexclude set
    config.bankexclude = { 0 }
    ranks["Ghost-R"] = nil
    local r2 = ledger:Query({ includeUncounted = true })
    assert.equal(105, r2.guild["bank.gold"])
    for _, row in ipairs(r2.rows) do assert.not_equal("rank excluded", row.why) end
  end)

  it("hidden profile still counts in goldKept", function()
    ctx.profile.IsHidden = function(_, id) return id == "ann" end
    add({ type = "exchange.gold.earned", profile = "ann", value = 1000 })
    add({ type = "exchange.gold.earned", profile = "bob", value = 500 })
    add({ type = "exchange.gold.earned", profile = "bob", value = -200 })
    add({ type = "bank.gold", char = "Ann-R", value = 300, net = true })
    local r = ledger:Query({})
    assert.equal(1800, r.goldKept)
  end)

  it("item filter limits to matching items", function()
    add({ type = "bank.items", char = "Ann-R", item = 1, value = 5, net = true })
    add({ type = "bank.items", char = "Ann-R", item = 2, value = 7, net = true })
    local r = ledger:Query({ item = function(id) return id == 2 end })
    assert.equal(7, r.byProfile.ann["bank.items"])
    assert.equal(7, r.guild["bank.items"])
  end)

  it("a failing deriver is reported, skipped and retried", function()
    local errs, calls = {}, 0
    ns.OnError = function(m) errs[#errs + 1] = m end
    ns.Activity.RegisterDeriver("fake", function() calls = calls + 1; error("boom") end)
    assert.same({}, ledger:Contributions())
    assert.equal(1, #errs)
    assert.truthy(errs[1]:find("deriver 'fake'", 1, true))
    assert.truthy(errs[1]:find("boom", 1, true))
    ledger:Contributions()
    assert.equal(2, calls)
  end)

  it("Contributions caches until observations change or Invalidate", function()
    local calls = 0
    ns.Activity.RegisterDeriver("fake", function() calls = calls + 1; return {} end)
    ledger:Contributions(); ledger:Contributions()
    assert.equal(1, calls)
    ctx.observations.changes = 1
    ledger:Contributions()
    assert.equal(2, calls)
    ledger:Invalidate()
    ledger:Contributions()
    assert.equal(3, calls)
  end)

  describe("exclusions", function()
    local excl
    before_each(function()
      excl = {}
      ctx.config = { Exclusions = function() return excl end }
    end)

    it("an excluded entry leaves the member's total, stays in the guild total, and shows with its reason", function()
      add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, ref = "bank:a" })
      add({ type = "bank.gold", char = "Bob-R", value = 30, net = true, ref = "bank:b" })
      add({ type = "listings", profile = "bob", ref = "x:1" })
      excl["bank:a"] = { excluded = true, reason = "moving guild funds", by = "Gm-R", at = 5 }
      local r = ledger:Query({ includeUncounted = true })
      assert.is_nil(r.byProfile.ann)
      assert.equal(30, r.byProfile.bob["bank.gold"])
      assert.equal(130, r.guild["bank.gold"])
      assert.equal(130, r.goldKept)
      local row
      for _, x in ipairs(r.rows) do if x.ref == "bank:a" then row = x end end
      assert.is_false(row.counted)
      assert.equal("excluded by an officer", row.why)
      assert.equal("moving guild funds", row.reason)
      assert.equal("Gm-R", row.excludedBy)
      assert.equal("ann", row.profile)
      -- applied in Query only: the cached contribution is untouched
      assert.is_true(ctx.contribs[1].counted)
      assert.is_nil(ctx.contribs[1].why)
      excl["bank:a"] = nil
      assert.equal(100, ledger:Query({}).byProfile.ann["bank.gold"])
    end)

    it("an excluded deposit nets out of the member but not the guild", function()
      add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, ref = "bank:dep", at = 10 })
      add({ type = "bank.gold", char = "Ann-R", value = -40, net = true, ref = "bank:wd", at = 20 })
      local before = ledger:Query({})
      assert.equal(60, before.byProfile.ann["bank.gold"])
      assert.equal(60, before.guild["bank.gold"])
      excl["bank:dep"] = { excluded = true }
      local r = ledger:Query({})
      assert.equal(0, r.byProfile.ann["bank.gold"]) -- -40 alone clamps at 0
      assert.equal(60, r.guild["bank.gold"])        -- the bank still holds the 60
      assert.equal(60, r.goldKept)
    end)

    it("an excluded withdrawal nets out of the member but not the guild", function()
      add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, ref = "bank:dep", at = 10 })
      add({ type = "bank.gold", char = "Ann-R", value = -40, net = true, ref = "bank:wd", at = 20 })
      excl["bank:wd"] = { excluded = true, reason = "repairs for the raid" }
      local r = ledger:Query({})
      assert.equal(100, r.byProfile.ann["bank.gold"])
      assert.equal(60, r.guild["bank.gold"])
      assert.equal(60, r.goldKept)
      -- netting is still per window
      local w = ledger:Query({ to = 15 })
      assert.equal(100, w.byProfile.ann["bank.gold"])
      assert.equal(100, w.guild["bank.gold"])
    end)

    it("excluding every entry of a member still leaves the guild total and clamps at 0", function()
      add({ type = "bank.items", char = "Ann-R", item = 7, value = 5, net = true, ref = "bank:i1" })
      add({ type = "bank.items", char = "Ann-R", item = 7, value = -8, net = true, ref = "bank:i2" })
      excl["bank:i1"], excl["bank:i2"] = { excluded = true }, { excluded = true }
      local r = ledger:Query({})
      assert.is_nil(r.byProfile.ann) -- nothing left of hers adds to byProfile
      assert.equal(0, r.guild["bank.items"])
    end)

    it("an excluded entry that wasn't counted keeps its own why and adds nothing", function()
      add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, ref = "bank:u", counted = false, why = "unpaired" })
      excl["bank:u"] = { excluded = true }
      local r = ledger:Query({ includeUncounted = true })
      assert.is_nil(r.guild["bank.gold"])
      assert.equal("unpaired", r.rows[1].why)
    end)

    it("works without a config", function()
      ctx.config = nil
      add({ type = "bank.gold", char = "Ann-R", value = 100, net = true, ref = "bank:a" })
      assert.equal(100, ledger:Query({}).byProfile.ann["bank.gold"])
    end)
  end)

  it("every row with a character names its profile, without changing what counts", function()
    add({ type = "bank.gold", char = "Ann-R", value = 50, net = true, ref = "bank:u", counted = false, why = "unpaired" })
    add({ type = "bank.gold", char = "Ghost-R", value = 20, net = true, ref = "bank:g", counted = false, why = "unpaired" })
    local r = ledger:Query({ includeUncounted = true })
    local by = {}
    for _, row in ipairs(r.rows) do by[row.ref] = row end
    assert.equal("ann", by["bank:u"].profile)
    assert.is_nil(by["bank:g"].profile)
    assert.same({}, r.byProfile)
    assert.is_nil(r.guild["bank.gold"])
  end)
end)
