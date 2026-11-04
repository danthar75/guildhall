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
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Ledger.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Bank.lua")
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
    db.bankSeen.old = now - 34560001
    db.bankSeen.new = now - 100
    bank:OnOpen()
    assert.is_nil(db.bankSeen.old)
    assert.is_not_nil(db.bankSeen.new)
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
end)
