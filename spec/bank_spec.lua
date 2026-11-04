describe("Bank log reader", function()
  local fakes = require("spec.helpers.fakes")
  local H = 3600
  local ns, now, published, env, logs, money, secrets, owners, timers, queried, db, bank, status

  local function mk()
    local compat
    compat, env = fakes.compat({
      GetNumGuildBankTabs = function() return 2 end,
      MAX_GUILDBANK_TABS = 6,
      QueryGuildBankLog = function(tab) queried[#queried + 1] = tab end,
      GetNumGuildBankTransactions = function(tab) return #(logs[tab] or {}) end,
      GetGuildBankTransaction = function(tab, i) return unpack(logs[tab][i]) end,
      GetNumGuildBankMoneyTransactions = function() return #money end,
      GetGuildBankMoneyTransaction = function(i) return unpack(money[i]) end,
      issecretvalue = function(v) return secrets[v] == true end,
    })
    return compat
  end

  local LINK = "|cffffffff|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"
  -- type, name, link, count, tab1, tab2, year, month, day, hour
  local function item(t, name, count, hours)
    return { t, name, LINK, count, 0, 0, 0, 0, 0, hours or 0 }
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Ledger.lua")
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Bank.lua")
    now = 10 * H + 1200   -- 10:20
    published, logs, money, secrets, owners, timers, queried, db = {}, {}, {}, {}, {}, {}, {}, {}
    status = "accepted"
    bank = ns.Bank.new({
      compat = mk(),
      observations = { Publish = function(_, d) published[#published + 1] = d; return status end },
      profile = { OwnerOf = function(_, c) return owners[c] end },
      now = function() return now end,
      after = function(s, fn) timers[#timers + 1] = { s = s, fn = fn } end,
      moduleDb = db,
    })
  end)

  it("a deposit and a withdrawal become observations; a move doesn't", function()
    logs[1] = { item("deposit", "Ann", 20, 2), item("withdraw", "Bob", 5, 0), item("move", "Cy", 3, 0) }
    money = { { "deposit", "Ann", 50000, 0, 0, 0, 1 }, { "repair", "Bob", 900, 0, 0, 0, 0 } }
    bank:OnLogUpdate()
    assert.equal(3, #published)
    assert.same({ kind = "bank", type = "dep", player = "Ann", tab = 1, item = 2589, count = 20, at = 8 * H },
      published[1])
    assert.same({ kind = "bank", type = "wd", player = "Bob", tab = 1, item = 2589, count = 5, at = 10 * H },
      published[2])
    assert.same({ kind = "bank", type = "dep", player = "Ann", copper = 50000, at = 9 * H }, published[3])
  end)

  it("re-reading the same log publishes nothing new", function()
    logs[1] = { item("deposit", "Ann", 20, 2) }
    bank:OnLogUpdate()
    bank:OnLogUpdate()
    assert.equal(1, #published)
  end)

  it("two identical deposits in the same hour publish 2 (ordinal)", function()
    logs[1] = { item("deposit", "Ann", 20, 0), item("deposit", "Ann", 20, 0) }
    bank:OnLogUpdate()
    assert.equal(2, #published)
    bank:OnLogUpdate()
    assert.equal(2, #published)
  end)

  it("a rejected publish is retried on the next read", function()
    logs[1] = { item("deposit", "Ann", 20, 0) }
    status = "excluded"
    bank:OnLogUpdate()
    status = "accepted"
    bank:OnLogUpdate()
    assert.equal(2, #published)
  end)

  describe("deriver", function()
    local function rec(id, by, at, extra)
      local d = { kind = "bank", type = "dep", player = "Ann-R", tab = 1, item = 2589, count = 20, at = at }
      for k, v in pairs(extra or {}) do d[k] = v end
      return { id = id, by = by, d = d }
    end
    local function derive(list)
      return ns.Activity.Deriver("bank")(list, { profile = { OwnerOf = function(_, c) return owners[c] end } })
    end

    it("readers at 10:20 (0 h ago) and 11:05 (0 h ago) merge into one entry (+-1 bucket)", function()
      local out = derive({ rec("a", "bob", 10 * H), rec("b", "cy", 11 * H) })
      assert.equal(1, #out)
      assert.is_true(out[1].counted)
      assert.equal(20, out[1].value)
      assert.equal("bank.items", out[1].type)
      assert.is_true(out[1].net)
      -- two buckets apart do not merge
      assert.equal(2, #derive({ rec("a", "bob", 10 * H), rec("b", "cy", 12 * H) }))
    end)

    it("a depositor-only report is unpaired; another reader makes it counted", function()
      owners["Ann-R"] = "ann"
      local one = derive({ rec("a", "ann", 10 * H) })
      assert.is_false(one[1].counted)
      assert.equal("unpaired", one[1].why)
      assert.equal("Ann-R", one[1].char)
      local two = derive({ rec("a", "ann", 10 * H), rec("b", "bob", 10 * H) })
      assert.equal(1, #two)
      assert.is_true(two[1].counted)
      -- a lone report from someone else, or an unknown depositor, counts
      assert.is_true(derive({ rec("b", "bob", 10 * H) })[1].counted)
      owners["Ann-R"] = nil
      assert.is_true(derive({ rec("a", "ann", 10 * H) })[1].counted)
    end)

    it("same-profile observations never cluster; withdrawals are negative; money has no tab", function()
      assert.equal(2, #derive({ rec("a", "bob", 10 * H), rec("b", "bob", 10 * H) }))
      local wd = derive({ rec("a", "bob", 10 * H, { type = "wd" }) })
      assert.equal(-20, wd[1].value)
      local g = derive({ { id = "m", by = "bob", d = { kind = "bank", type = "dep", player = "Ann-R",
        copper = 5000, at = 10 * H } } })
      assert.equal("bank.gold", g[1].type)
      assert.is_nil(g[1].tab)
    end)

    it("tab not in donations goes to rows with why 'tab not counted' (through Ledger)", function()
      owners["Ann-R"] = "ann"
      local list = {
        rec("a", "bob", 10 * H, { tab = 1 }), rec("b", "bob", 10 * H, { tab = 3, count = 7 }),
        { id = "m", by = "bob", d = { kind = "bank", type = "dep", player = "Ann-R", copper = 5000, at = 10 * H } },
      }
      for _, id in ipairs({ "bank.gold", "bank.items" }) do
        if not ns.Activity.Get(id) then error("bank types not registered") end
      end
      local ledger = ns.Ledger.new({
        activity = ns.Activity,
        observations = { List = function() return list end, changes = 0 },
        profile = { OwnerOf = function(_, c) return owners[c] end, CharsOf = function() return { "Ann-R" } end },
        roster = { RankIndex = function() end, ConfigList = function(_, k) return k == "donations" and { 3 } or {} end },
      })
      ns.Observations = { KINDS = { bank = true } }
      local r = ledger:Query({ includeUncounted = true })
      local why = {}
      for _, row in ipairs(r.rows) do why[row.tab or "money"] = row.why or "counted" end
      assert.equal("tab not counted", why[1])
      assert.equal("counted", why[3])
      assert.equal("counted", why.money)
      assert.equal(7, r.byProfile.ann["bank.items"])
      assert.equal(5000, r.byProfile.ann["bank.gold"])
    end)
  end)

  it("a secret name drops that entry only (Review Focus 1)", function()
    secrets["Secret"] = true
    logs[1] = { item("deposit", "Secret", 20, 0), item("deposit", "Ann", 3, 0) }
    money = { { "deposit", "Secret", 100, 0, 0, 0, 0 }, { "deposit", "Ann", 200, 0, 0, 0, 0 } }
    assert.has_no.errors(function() bank:OnLogUpdate() end)
    assert.equal(2, #published)
    assert.equal("Ann", published[1].player)
    assert.equal("Ann", published[2].player)
  end)

  it("a secret entry count or a missing API reads as nil", function()
    local compat = mk()
    secrets[1] = true
    logs[1] = { item("deposit", "Ann", 20, 0) }
    assert.is_nil(compat:BankLog(1))
    secrets[1] = nil
    env.GetNumGuildBankTransactions = nil
    assert.is_nil(compat:BankLog(1))
    env.GetNumGuildBankMoneyTransactions = nil
    assert.is_nil(compat:BankMoneyLog())
    assert.has_no.errors(function() bank:OnLogUpdate() end)
  end)

  it("ago converts years, months, days, hours (month 30 d, year 365 d)", function()
    logs[1] = { { "deposit", "Ann", LINK, 1, 0, 0, 1, 2, 3, 4 } }
    local e = mk():BankLog(1)[1]
    assert.equal(((365 + 60 + 3) * 24 + 4) * 3600, e.ago)
    assert.equal(2589, e.item)
  end)

  it("OnOpen queries every tab and the money log, ticks each 60 s, and stops on close", function()
    env.Enum = nil
    bank.ctx.compat:SetBankOpen(true)
    bank:OnOpen()
    assert.same({ 1, 2, 7 }, queried)
    assert.equal(1, #timers)
    assert.equal(60, timers[1].s)
    local t = table.remove(timers)
    t.fn()
    assert.equal(6, #queried)
    assert.equal(1, #timers)
    bank:OnClose()
    table.remove(timers).fn()
    assert.equal(6, #queried)
    assert.equal(0, #timers)
  end)

  it("OnOpen prunes seen keys older than 400 days", function()
    db.bankSeen.old = { { b = 1, t = now - 34560001 } }
    db.bankSeen.new = { { b = 1, t = now - 100 }, { b = 2, t = now - 34560001 } }
    db.bankSeen.flat = now
    bank:OnOpen()
    assert.is_nil(db.bankSeen.old)
    assert.is_nil(db.bankSeen.flat)
    assert.equal(1, #db.bankSeen.new)
  end)

  it("compat bank open flag follows events", function()
    local c = mk()
    env.Enum = { PlayerInteractionType = { GuildBanker = 10 } }
    assert.is_false(c:BankOpen())
    c:HandleBankEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 10)
    assert.is_true(c:BankOpen())
    c:HandleBankEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 3)
    assert.is_true(c:BankOpen())
    c:HandleBankEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 10)
    assert.is_false(c:BankOpen())
    c:HandleBankEvent("GUILDBANKFRAME_OPENED")
    assert.is_true(c:BankOpen())
    c:HandleBankEvent("GUILDBANKFRAME_CLOSED")
    assert.is_false(c:BankOpen())
  end)
  describe("hour-edge re-reads", function()
    -- an entry made at absolute time t0, as the game reports it at the current clock
    local function entryAt(t0, name, count)
      return item("deposit", name or "Ann", count or 20, math.floor((now - t0) / H))
    end

    it("one deposit read at 10:55 and again at 11:05 by the same client publishes once", function()
      now = 10 * H + 55 * 60
      logs[1] = { item("deposit", "Ann", 20, 0) }
      bank:OnLogUpdate()
      now = 11 * H + 5 * 60
      logs[1] = { item("deposit", "Ann", 20, 0) }   -- still "0 hours ago" on its own clock edge
      bank:OnLogUpdate()
      logs[1] = { item("deposit", "Ann", 20, 1) }
      bank:OnLogUpdate()
      assert.equal(1, #published)
    end)

    it("bank open for 2 h with 60 s ticks publishes each entry once", function()
      local start = 9 * H + 30 * 60
      now = start
      local times = { start - 100, start - 50 * 60, start + 20 * 60, start + 70 * 60 }
      for _ = 1, 120 do
        logs[1], money = {}, {}
        for i, t0 in ipairs(times) do
          if t0 <= now then logs[1][#logs[1] + 1] = entryAt(t0, "P" .. i, 5) end
        end
        money = { { "deposit", "Ann", 900, 0, 0, 0, math.floor((now - (start - 10)) / H) } }
        bank:OnLogUpdate()
        now = now + 60
      end
      assert.equal(5, #published)
    end)

    it("two identical deposits stay 2 across an hour edge", function()
      now = 10 * H + 50 * 60
      logs[1] = { item("deposit", "Ann", 20, 0), item("deposit", "Ann", 20, 0) }
      bank:OnLogUpdate()
      now = 11 * H + 10 * 60
      logs[1] = { item("deposit", "Ann", 20, 0), item("deposit", "Ann", 20, 1) }
      bank:OnLogUpdate()
      now = 11 * H + 30 * 60
      logs[1] = { item("deposit", "Ann", 20, 1), item("deposit", "Ann", 20, 1) }
      bank:OnLogUpdate()
      assert.equal(2, #published)
    end)

    it("a third identical deposit after an edge is still published", function()
      now = 10 * H + 50 * 60
      logs[1] = { item("deposit", "Ann", 20, 0), item("deposit", "Ann", 20, 0) }
      bank:OnLogUpdate()
      now = 11 * H + 10 * 60
      logs[1] = { item("deposit", "Ann", 20, 0), item("deposit", "Ann", 20, 1), item("deposit", "Ann", 20, 1) }
      bank:OnLogUpdate()
      assert.equal(3, #published)
    end)

    it("an invalid publish is remembered, logged once, not retried", function()
      local errs = {}
      ns.OnError = function(m) errs[#errs + 1] = m end
      status = "invalid"
      logs[1] = { item("deposit", "Ann", 20, 0) }
      bank:OnLogUpdate()
      bank:OnLogUpdate()
      assert.equal(1, #published)
      assert.equal(1, #errs)
    end)

    it("two clients reading either side of the edge merge through the deriver", function()
      local function reader(at)
        local out = {}
        local b = ns.Bank.new({
          compat = mk(), observations = { Publish = function(_, d) out[#out + 1] = d; return "accepted" end },
          profile = {}, now = function() return at end, after = function() end, moduleDb = {},
        })
        logs[1] = { item("deposit", "Ann-R", 20, 0) }
        b:OnLogUpdate()
        return out[1]
      end
      local a, b = reader(10 * H + 20 * 60), reader(11 * H + 5 * 60)
      assert.not_equal(a.at, b.at)
      local out = ns.Activity.Deriver("bank")({ { id = "a", by = "bob", d = a }, { id = "b", by = "cy", d = b } },
        { profile = { OwnerOf = function() end } })
      assert.equal(1, #out)
      assert.is_true(out[1].counted)
    end)
  end)

  it("a repeated OnOpen with no close keeps exactly one ticker", function()
    bank.ctx.compat:SetBankOpen(true)
    bank:OnOpen()
    bank:OnOpen()
    queried = {}
    local pending = timers
    timers = {}
    for _, t in ipairs(pending) do t.fn() end
    assert.equal(3, #queried)
    assert.equal(1, #timers)
  end)

  it("the ticker stops once the bank is no longer open", function()
    bank.ctx.compat:SetBankOpen(true)
    bank:OnOpen()
    bank.ctx.compat:SetBankOpen(false)
    queried = {}
    table.remove(timers).fn()
    assert.equal(0, #queried)
    assert.equal(0, #timers)
  end)

  describe("Observations.Validate for bank", function()
    local V
    before_each(function()
      local n = {}
      loadAddonFile(n, "Guildhearth/Core/Util.lua")
      loadAddonFile(n, "Guildhearth/Core/Leaderboard/Observations.lua")
      V = n.Observations.Validate
    end)
    local function it_(o) local d = { kind = "bank", type = "dep", player = "Ann", tab = 1, item = 2589, count = 20, at = 3600 }
      for k, v in pairs(o) do if v == "nil" then d[k] = nil else d[k] = v end end
      return d end
    local function m(o) local d = { kind = "bank", type = "dep", player = "Ann", copper = 500, at = 3600 }
      for k, v in pairs(o) do if v == "nil" then d[k] = nil else d[k] = v end end
      return d end
    it("accepts good entries and enforces bounds", function()
      assert.is_true(V(it_({})))
      assert.is_true(V(m({})))
      assert.is_false(V(it_({ tab = 0 })))
      assert.is_false(V(it_({ tab = 9 })))
      assert.is_false(V(it_({ item = 0 })))
      assert.is_false(V(it_({ item = 10000001 })))
      assert.is_false(V(it_({ count = 0 })))
      assert.is_false(V(it_({ count = 10001 })))
      assert.is_true(V(it_({ count = 10000, item = 10000000, tab = 8 })))
      assert.is_false(V(it_({ copper = 5 })))
      assert.is_false(V(m({ copper = 0 })))
      assert.is_false(V(m({ copper = 100000000001 })))
      assert.is_true(V(m({ copper = 100000000000 })))
      assert.is_false(V(m({ count = 1 })))
      assert.is_false(V(m({ item = 1 })))
      assert.is_false(V(it_({ type = "move" })))
    end)
  end)
end)
