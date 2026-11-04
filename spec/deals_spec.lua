describe("Exchange deals", function()
  local ns, Deals, DAY = nil, nil, 86400
  local LINK = "|Hitem:2589::|h[Linen Cloth]|h"

  local function listing(o)
    local r = { id = "L1", v = 1, t = 1000, by = "ann", char = "Ann-R", exp = 1000 + 604800, del = false,
      d = { kind = "WTS", item = LINK, qty = 20, cod = false, created = 1000 } }
    for k, v in pairs(o or {}) do r[k] = v end
    return r
  end
  local function transfer(o)
    local t = { me = "ann", partner = "bob", give = { { id = 2589, n = 20 } }, get = {},
      giveCopper = 0, getCopper = 50000, at = 5000 }
    for k, v in pairs(o or {}) do t[k] = v end
    return t
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Deals.lua")
    Deals = ns.Exchange.Deals
  end)

  describe("Match", function()
    it("WTS: item from owner, gold from partner matches", function()
      local l = listing()
      assert.equal(l, Deals.Match(transfer(), { l }))
      -- seen from the buyer's side
      assert.equal(l, Deals.Match(transfer({ me = "bob", partner = "ann", give = {}, get = { { id = 2589, n = 20 } },
        giveCopper = 50000, getCopper = 0 }), { l }))
    end)

    it("LF: reversed direction matches; wrong direction doesn't", function()
      local lf = listing({ by = "bob", d = { kind = "LF", item = LINK, qty = 20, cod = false, created = 1000 } })
      -- Bob wants it: Ann (me) gives the item, Bob pays
      assert.equal(lf, Deals.Match(transfer(), { lf }))
      -- Bob would be handing over the item instead: wrong direction
      assert.is_nil(Deals.Match(transfer({ me = "bob", partner = "ann" }), { lf }))
      -- WTS with the item going to the owner is wrong too
      local wts = listing()
      assert.is_nil(Deals.Match(transfer({ give = {}, get = { { id = 2589, n = 20 } }, giveCopper = 50000, getCopper = 0 }), { wts }))
      -- right item direction but gold flows the wrong way
      assert.is_nil(Deals.Match(transfer({ giveCopper = 50000, getCopper = 0 }), { wts }))
    end)

    it("a listing removed 47 h ago matches, and one removed 49 h ago doesn't", function()
      local at = 500000
      local l47 = listing({ del = true, t = at - 47 * 3600 })
      local l49 = listing({ del = true, t = at - 49 * 3600 })
      assert.equal(l47, Deals.Match(transfer({ at = at }), { l47 }))
      assert.is_nil(Deals.Match(transfer({ at = at }), { l49 }))
    end)

    it("expiry counts as ending at exp", function()
      local at = 900000
      assert.is_not_nil(Deals.Match(transfer({ at = at }), { listing({ exp = at - 47 * 3600 }) }))
      assert.is_nil(Deals.Match(transfer({ at = at }), { listing({ exp = at - 49 * 3600 }) }))
    end)

    it("same-profile trade never matches", function()
      assert.is_nil(Deals.Match(transfer({ partner = "ann" }), { listing() }))
    end)

    it("a listing owned by a third profile doesn't match", function()
      assert.is_nil(Deals.Match(transfer(), { listing({ by = "cat" }) }))
    end)

    it("typed-name listing never matches", function()
      local l = listing({ d = { kind = "WTS", item = "Linen Cloth", qty = 20, cod = false } })
      assert.is_nil(Deals.Match(transfer(), { l }))
    end)

    it("picks the newest of several matches", function()
      local a, b = listing({ id = "A", t = 1000 }), listing({ id = "B", t = 2000 })
      assert.equal(b, Deals.Match(transfer(), { a, b }))
      assert.equal(b, Deals.Match(transfer(), { b, a }))
    end)
  end)

  describe("Observation", function()
    it("describes the deal from either side", function()
      local l = listing()
      local want = { kind = "trade", listing = "L1", seller = "ann", buyer = "bob", item = 2589,
        count = 20, copper = 50000, at = 5000 }
      assert.same(want, Deals.Observation("trade", l, transfer()))
      local buyerView = transfer({ me = "bob", partner = "ann", give = {}, get = { { id = 2589, n = 12 }, { id = 2589, n = 8 } },
        giveCopper = 50000, getCopper = 0 })
      assert.same(want, Deals.Observation("trade", l, buyerView))
    end)
  end)

  describe("deriver", function()
    local function rec(id, by, d) return { id = id, by = by, d = d } end
    local function d(o)
      local x = { kind = "trade", listing = "L1", seller = "ann", buyer = "bob", item = 2589, count = 20,
        copper = 50000, at = 5000 }
      for k, v in pairs(o or {}) do x[k] = v end
      return x
    end
    local function derive(kind, list) return ns.Activity.Deriver(kind)(list, {}) end
    local function sum(list, type_, counted)
      local n, who = 0, {}
      for _, c in ipairs(list) do
        if c.type == type_ and c.counted == counted then n = n + c.value; who[#who + 1] = c.profile end
      end
      return n, who
    end

    it("registers the five activity types in order", function()
      local ids = {}
      for _, t in ipairs(ns.Activity.Types()) do ids[#ids + 1] = t.id end
      assert.same({ "exchange.listings", "exchange.sales", "exchange.purchases", "exchange.gold.earned",
        "exchange.gold.paid" }, ids)
      assert.equal("gold", ns.Activity.Get("exchange.gold.paid").unit)
      assert.equal(5, ns.Activity.Get("exchange.sales").weight)
    end)

    it("pairing needs both profiles; one side gives unpaired rows", function()
      local one = derive("trade", { rec("o1", "ann", d()) })
      assert.equal(0, (sum(one, "exchange.sales", true)))
      local n, who = sum(one, "exchange.sales", false)
      assert.equal(1, n); assert.same({ "ann" }, who)
      assert.equal(50000, (sum(one, "exchange.gold.earned", false)))
      for _, c in ipairs(one) do assert.equal("unpaired", c.why) end

      local two = derive("trade", { rec("o1", "ann", d()), rec("o2", "bob", d({ at = 5100 })) })
      assert.equal(1, (sum(two, "exchange.sales", true)))
      local _, buyers = sum(two, "exchange.purchases", true)
      assert.same({ "bob" }, buyers)
      assert.equal(50000, (sum(two, "exchange.gold.earned", true)))
      assert.equal(50000, (sum(two, "exchange.gold.paid", true)))
      assert.equal(4, #two)
      for _, c in ipairs(two) do
        assert.equal("deal:L1:o1", c.ref)
        assert.equal(5000, c.at)
        assert.is_nil(c.char)
      end
    end)

    it("two observations from the same profile never pair", function()
      local list = derive("trade", { rec("o1", "ann", d()), rec("o2", "ann", d({ at = 5001 })) })
      assert.equal(0, (sum(list, "exchange.sales", true)))
    end)

    it("an observation from an outsider doesn't pair", function()
      local list = derive("trade", { rec("o1", "ann", d()), rec("o2", "cat", d()) })
      assert.equal(0, (sum(list, "exchange.sales", true)))
    end)

    it("differing count or copper doesn't pair", function()
      local list = derive("trade", { rec("o1", "ann", d()), rec("o2", "bob", d({ copper = 49999 })) })
      assert.equal(0, (sum(list, "exchange.sales", true)))
    end)

    it("trades 16 min apart don't pair", function()
      local list = derive("trade", { rec("o1", "ann", d()), rec("o2", "bob", d({ at = 5000 + 960 })) })
      assert.equal(0, (sum(list, "exchange.sales", true)))
      local ok = derive("trade", { rec("o1", "ann", d()), rec("o2", "bob", d({ at = 5000 + 900 })) })
      assert.equal(1, (sum(ok, "exchange.sales", true)))
    end)

    it("cod pairs across days, manual waits with its own reason", function()
      local cod = derive("cod", { rec("o1", "ann", d({ kind = "cod" })), rec("o2", "bob", d({ kind = "cod", at = 5000 + 20 * DAY })) })
      assert.equal(1, (sum(cod, "exchange.sales", true)))
      local far = derive("cod", { rec("o1", "ann", d({ kind = "cod" })), rec("o2", "bob", d({ kind = "cod", at = 5000 + 31 * DAY })) })
      assert.equal(0, (sum(far, "exchange.sales", true)))
      local man = derive("manual", { rec("o1", "bob", d({ kind = "manual" })) })
      assert.equal("waiting for confirmation", man[1].why)
      local manPair = derive("manual", { rec("o1", "bob", d({ kind = "manual" })), rec("o2", "ann", d({ kind = "manual", at = 5000 + 13 * DAY })) })
      assert.equal(1, (sum(manPair, "exchange.purchases", true)))
    end)

    it("each observation pairs at most once", function()
      local list = derive("trade", { rec("o1", "ann", d()), rec("o2", "bob", d({ at = 5010 })), rec("o3", "bob", d({ at = 5020 })) })
      assert.equal(1, (sum(list, "exchange.sales", true)))
      assert.equal(1, (sum(list, "exchange.purchases", false)))
    end)
  end)
end)
