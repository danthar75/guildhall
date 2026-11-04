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

    it("prefers an active listing over a newer ended one", function()
      local live = listing({ id = "A", t = 1000 })
      local ended = listing({ id = "B", t = 2000, del = true })
      assert.equal(live, Deals.Match(transfer(), { live, ended }))
      assert.equal(live, Deals.Match(transfer(), { ended, live }))
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

  describe("CoD mail (DealWatch)", function()
    local money, published, now, mailSnap, inbox, listings, hooks, scripts, env
    local LINK2 = "|Hitem:2589::|h[Linen Cloth]|h"

    local function build(compatOver)
      local compat = {
        Safe = function(_, v) return v end,
        Money = function() return money end,
        SendMailSnapshot = function() return mailSnap and { to = mailSnap.to, cod = mailSnap.cod, items = mailSnap.items } end,
        InboxCount = function() local n = 0; for k in pairs(inbox) do if k > n then n = k end end; return n end,
        InboxCod = function(_, i) return inbox[i] end,
      }
      for k, v in pairs(compatOver or {}) do compat[k] = v end
      local w = ns.Exchange.DealWatch.new({
        compat = compat,
        exchange = { listings = { List = function() return listings end } },
        observations = { Publish = function(_, d) published[#published + 1] = d; return "ok", {} end },
        profile = { Id = function() return "ann" end,
          OwnerOf = function(_, c) return ({ ["Bob-R"] = "bob" })[c] end },
        roster = { Norm = function(_, n) return n end },
        now = function() return now end, after = function() end, env = env,
        hooksecurefunc = function(name, fn) hooks[name] = fn end,
      })
      w:InstallHooks()
      return w
    end

    before_each(function()
      loadAddonFile(ns, "Guildhall/Modules/Exchange/DealWatch.lua")
      published, now, hooks, scripts = {}, 5000, {}, {}
      money = 1000000
      env = { SendMail = function() end, TakeInboxItem = function() end, AutoLootMailItem = function() end,
        ReturnInboxItem = function() end, DeleteInboxItem = function() end }
      mailSnap = { to = "Bob-R", cod = 50000, items = { { id = 2589, n = 20 } } }
      inbox = {}
      listings = { { id = "L1", v = 1, t = 1000, by = "ann", char = "Ann-R", exp = 700000, del = false,
        d = { kind = "WTS", item = LINK2, qty = 20, cod = true, created = 1000 } } }
    end)

    it("seller CoD send publishes after MAIL_SEND_SUCCESS only", function()
      local w = build()
      hooks.SendMail("Bob-R", "s", "b")
      assert.equal(0, #published)
      w:OnEvent("MAIL_SEND_SUCCESS")
      w:OnEvent("MAIL_SEND_SUCCESS")
      assert.equal(1, #published)
      assert.same({ kind = "cod", listing = "L1", seller = "ann", buyer = "bob", item = 2589, count = 20,
        copper = 50000, at = 5000 }, published[1])
    end)

    it("a failed send (no success event) publishes nothing", function()
      local w = build()
      hooks.SendMail("Bob-R", "s", "b")
      w:OnEvent("MAIL_FAILED")
      w:OnEvent("MAIL_SEND_SUCCESS")
      assert.equal(0, #published)
    end)

    it("Era fallback: fields already cleared in the post-hook, PreClick snapshot is used", function()
      env.SendMailMailButton = { HookScript = function(_, n, fn) scripts[n] = fn end }
      local w = build()
      scripts.PreClick()
      mailSnap = nil   -- cleared by the time SendMail's post-hook runs
      hooks.SendMail("Bob-R", "s", "b")
      w:OnEvent("MAIL_SEND_SUCCESS")
      assert.equal(1, #published)
    end)

    local function codMail(o)
      local m = { sender = "Bob-R", cod = 50000, items = { { id = 2589, n = 20 } } }
      for k, v in pairs(o or {}) do m[k] = v end
      return m
    end

    it("buyer take publishes once the next inbox update shows the mail gone", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      hooks.AutoLootMailItem(1)
      assert.equal(0, #published)   -- a request only; nothing yet
      inbox[1] = nil
      money = money - 50000
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(1, #published)
      assert.same({ kind = "cod", listing = "L1", seller = "bob", buyer = "ann", item = 2589, count = 20,
        copper = 50000, at = 5000 }, published[1])
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(1, #published)
    end)

    it("a take whose next update still shows the same CoD header publishes nothing", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(0, #published)
    end)

    it("a failed take then a successful retry publishes exactly once", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      w:OnEvent("MAIL_INBOX_UPDATE")   -- failed
      hooks.TakeInboxItem(1, 1)
      hooks.AutoLootMailItem(1)
      inbox[1] = nil
      money = money - 50000
      w:OnEvent("MAIL_INBOX_UPDATE")
      w:OnEvent("MAIL_INBOX_UPDATE")
      w:OnEvent("PLAYER_MONEY")
      assert.equal(1, #published)
    end)

    it("two CoD mails taken before one inbox update publish both, matched by signature", function()
      inbox[1] = codMail()
      inbox[2] = codMail({ sender = "Bob-R", cod = 70000, items = { { id = 2589, n = 5 } } })
      listings[1].by, listings[1].char = "bob", "Bob-R"
      listings[1].d.qty = 20
      listings[2] = { id = "L2", v = 1, t = 1000, by = "bob", char = "Bob-R", exp = 700000, del = false,
        d = { kind = "WTS", item = LINK2, qty = 5, cod = true, created = 1000 } }
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      -- an addon takes mail 1 and mail 2 back to back; indexes shift by the next event
      hooks.TakeInboxItem(2, 1)
      inbox = {}
      money = money - 120000
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(2, #published)
      table.sort(published, function(x, y) return x.count > y.count end)
      assert.equal(50000, published[1].copper)
      assert.equal(70000, published[2].copper)
    end)

    it("taking attachment 2 first on a two-attachment mail publishes all items once the CoD clears", function()
      inbox[1] = codMail({ items = { { id = 2589, n = 20 }, { id = 2589, n = 20 } } })
      listings[1].by, listings[1].char = "bob", "Bob-R"
      listings[1].d.qty = 40
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 2)
      inbox[1] = nil   -- cod now 0: InboxCod no longer reports it
      money = money - 50000
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(1, #published)
      assert.equal(40, published[1].count)
    end)

    it("a send whose recipient differs from the PreClick snapshot discards it", function()
      env.SendMailMailButton = { HookScript = function(_, n, fn) scripts[n] = fn end }
      local w = build()
      scripts.PreClick()
      mailSnap = nil
      hooks.SendMail("Carl-R", "s", "b")
      w:OnEvent("MAIL_SEND_SUCCESS")
      assert.equal(0, #published)
    end)

    it("a stale PreClick snapshot (over 1 s old) is discarded", function()
      env.SendMailMailButton = { HookScript = function(_, n, fn) scripts[n] = fn end }
      local w = build()
      scripts.PreClick()
      mailSnap = nil
      now = now + 2
      hooks.SendMail("Bob-R", "s", "b")
      w:OnEvent("MAIL_SEND_SUCCESS")
      assert.equal(0, #published)
    end)

    it("a missing global is not hooked and never raises", function()
      env.AutoLootMailItem = nil
      assert.has_no.errors(function() build() end)
      assert.is_nil(hooks.AutoLootMailItem)
      assert.is_function(hooks.SendMail)
    end)

    local function realCompat(env2)
      local cns = {}
      loadAddonFile(cns, "Guildhall/Core/Util.lua")
      loadAddonFile(cns, "Guildhall/Core/Compat.lua")
      return cns.Compat.new(env2)
    end

    it("mail Returned after a failed take publishes nothing", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      w:OnEvent("MAIL_INBOX_UPDATE")   -- failed: header unchanged
      hooks.TakeInboxItem(1, 1)        -- retry, then the player clicks Return before the answer
      hooks.ReturnInboxItem(1)
      inbox[1] = nil
      w:OnEvent("MAIL_INBOX_UPDATE")
      w:OnEvent("PLAYER_MONEY")
      assert.equal(0, #published)
    end)

    it("the signature vanishing with no money drop publishes nothing", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      inbox[1] = nil
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(0, #published)
    end)

    it("unreadable money publishes nothing", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      money = nil
      hooks.TakeInboxItem(1, 1)
      inbox[1] = nil
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(0, #published)
    end)

    it("money arriving after the inbox update still settles a successful take once", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      inbox[1] = nil
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(0, #published)
      money = money - 50000
      w:OnEvent("PLAYER_MONEY")
      w:OnEvent("PLAYER_MONEY")
      assert.equal(1, #published)
    end)

    it("three identical CoD mails taken one at a time publish three observations", function()
      for i = 1, 3 do inbox[i] = codMail() end
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      for n = 3, 1, -1 do
        hooks.TakeInboxItem(1, 1)
        inbox[n] = nil
        money = money - 50000
        w:OnEvent("MAIL_INBOX_UPDATE")
      end
      assert.equal(3, #published)
    end)

    it("item id comes from the slot's itemID when the link is uncached", function()
      local c = realCompat({ SendMailNameEditBox = { GetText = function() return "Bob-R" end },
        GetSendMailCOD = function() return 50000 end,
        GetSendMailItemLink = function() return nil end,
        GetSendMailItem = function(i) if i == 1 then return "x", 2589, nil, 20 end end,
        issecretvalue = function() return false end })
      assert.same({ { id = 2589, n = 20 } }, c:SendMailSnapshot().items)
      local bad = realCompat({ SendMailNameEditBox = { GetText = function() return "Bob-R" end },
        GetSendMailCOD = function() return 50000 end,
        GetSendMailItemLink = function(i) if i == 1 then return "garbage" end end,
        GetSendMailItem = function() return "x", nil, nil, 20 end,
        issecretvalue = function() return false end })
      assert.is_nil(bad:SendMailSnapshot())
    end)

    it("an unpaid vanished take is discarded: later spends and MAIL_CLOSED publish nothing", function()
      inbox[1] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      inbox[1] = nil
      w:OnEvent("MAIL_INBOX_UPDATE")
      now = now + 10
      money = money - 50000   -- an unrelated repair bill
      w:OnEvent("PLAYER_MONEY")
      assert.equal(0, #published)
      -- and MAIL_CLOSED clears pending takes outright
      inbox[1] = codMail()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      inbox[1] = nil
      w:OnEvent("MAIL_CLOSED")
      money = money - 50000
      w:OnEvent("PLAYER_MONEY")
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(0, #published)
    end)

    it("one money drop is attributed once: S1 paid, S2 vanished unpaid, only S1 publishes", function()
      inbox[1] = codMail({ cod = 70000, items = { { id = 2589, n = 5 } } })
      inbox[2] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      listings[1].d.qty = 5
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      hooks.TakeInboxItem(2, 1)
      inbox = {}
      money = money - 70000
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(1, #published)
      assert.equal(70000, published[1].copper)
    end)

    it("two paid takes whose drops are summed both publish", function()
      inbox[1] = codMail({ cod = 70000, items = { { id = 2589, n = 5 } } })
      inbox[2] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      listings[2] = { id = "L2", v = 1, t = 1000, by = "bob", char = "Bob-R", exp = 700000, del = false,
        d = { kind = "WTS", item = LINK2, qty = 5, cod = true, created = 1000 } }
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      hooks.TakeInboxItem(2, 1)
      inbox = {}
      money = money - 120000
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(2, #published)
    end)

    it("Return cancels only one pending take (the newest with that signature)", function()
      inbox[1] = codMail()
      inbox[2] = codMail()
      listings[1].by, listings[1].char = "bob", "Bob-R"
      local w = build()
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      hooks.TakeInboxItem(2, 1)
      hooks.ReturnInboxItem(2)
      inbox = {}
      money = money - 100000
      w:OnEvent("MAIL_INBOX_UPDATE")
      assert.equal(1, #published)
    end)

    it("a slot with a name and count but no id and no link makes the snapshot nil", function()
      local c = realCompat({ SendMailNameEditBox = { GetText = function() return "Bob-R" end },
        GetSendMailCOD = function() return 50000 end,
        GetSendMailItemLink = function(i) if i == 1 then return LINK2 end end,
        GetSendMailItem = function(i) if i == 1 then return "x", 2589, nil, 20 end
          if i == 2 then return "Mystery", nil, nil, 3 end end,
        issecretvalue = function() return false end })
      assert.is_nil(c:SendMailSnapshot())
      local sec = realCompat({ SendMailNameEditBox = { GetText = function() return "Bob-R" end },
        GetSendMailCOD = function() return 50000 end,
        GetSendMailItemLink = function() return nil end,
        GetSendMailItem = function(i) if i == 1 then return "x", "SECRETID", nil, 20 end end,
        issecretvalue = function(v) return v == "SECRETID" end })
      assert.is_nil(sec:SendMailSnapshot())
    end)

    it("SendMailSnapshot: secret cod, link or count gives nil; unparseable link gives nil", function()
      local function mk(over)
        local e = { SendMailNameEditBox = { GetText = function() return "Bob-R" end },
          GetSendMailCOD = function() return 50000 end,
          GetSendMailItemLink = function(i) if i == 1 then return LINK2 end end,
          GetSendMailItem = function(i) if i == 1 then return "x", 2589, nil, 20 end end,
          issecretvalue = function() return false end }
        for k, v in pairs(over) do e[k] = v end
        return realCompat(e)
      end
      assert.equal(50000, mk({}):SendMailSnapshot().cod)
      assert.is_nil(mk({ issecretvalue = function(v) return v == 50000 end }):SendMailSnapshot())
      assert.is_nil(mk({ issecretvalue = function(v) return v == LINK2 end }):SendMailSnapshot())
      assert.is_nil(mk({ issecretvalue = function(v) return v == 20 end }):SendMailSnapshot())
      assert.is_nil(mk({ GetSendMailItemLink = function(i) if i == 1 then return LINK2 end
        if i == 2 then return "garbage" end end,
        GetSendMailItem = function(i) if i == 1 then return "x", 2589, nil, 20 end
          if i == 2 then return "y", nil, nil, 1 end end }):SendMailSnapshot())
    end)

    it("InboxCod: a secret attachment link or an unparseable link gives nil", function()
      local function mk(over)
        local e = { GetInboxHeaderInfo = function() return nil, nil, "Bob-R", "s", 0, 50000 end,
          GetInboxItemLink = function(_, i) if i == 1 then return LINK2 end end,
          GetInboxItem = function(_, i) if i == 1 then return "x", 2589, nil, 20 end end,
          issecretvalue = function() return false end }
        for k, v in pairs(over) do e[k] = v end
        return realCompat(e)
      end
      assert.equal(50000, mk({}):InboxCod(1).cod)
      assert.is_nil(mk({ issecretvalue = function(v) return v == LINK2 end }):InboxCod(1))
      assert.is_nil(mk({ GetInboxItemLink = function(_, i) if i == 2 then return "garbage" end
        if i == 1 then return LINK2 end end,
        GetInboxItem = function(_, i) if i == 1 then return "x", 2589, nil, 20 end
          if i == 2 then return "y", nil, nil, 1 end end }):InboxCod(1))
    end)

    it("CoD observations 29 days apart pair; 31 days apart don't", function()
      local function rec(id, by, at)
        return { id = id, by = by, d = { kind = "cod", listing = "L1", seller = "ann", buyer = "bob",
          item = 2589, count = 20, copper = 50000, at = at } }
      end
      local function sales(list)
        local n = 0
        for _, c in ipairs(ns.Activity.Deriver("cod")(list, {})) do
          if c.type == "exchange.sales" and c.counted then n = n + c.value end
        end
        return n
      end
      assert.equal(1, sales({ rec("o1", "ann", 5000), rec("o2", "bob", 5000 + 29 * 86400) }))
      assert.equal(0, sales({ rec("o1", "ann", 5000), rec("o2", "bob", 5000 + 31 * 86400) }))
    end)

    it("a mail with no CoD is ignored", function()
      mailSnap = nil
      inbox[1] = nil
      local w = build()
      hooks.SendMail("Bob-R", "s", "b")
      w:OnEvent("MAIL_SEND_SUCCESS")
      w:OnEvent("MAIL_INBOX_UPDATE")
      hooks.TakeInboxItem(1, 1)
      assert.equal(0, #published)
    end)

    it("a secret sender is ignored (real Compat)", function()
      local cns = {}
      loadAddonFile(cns, "Guildhall/Core/Util.lua")
      loadAddonFile(cns, "Guildhall/Core/Compat.lua")
      local real = cns.Compat.new({
        GetInboxNumItems = function() return 1 end,
        GetInboxHeaderInfo = function() return nil, nil, "SECRET", "s", 0, 50000 end,
        GetInboxItemLink = function(_, i) if i == 1 then return LINK2 end end,
        GetInboxItem = function(_, i) if i == 1 then return "x", 2589, nil, 20 end end,
        issecretvalue = function(v) return v == "SECRET" end,
      })
      listings[1].by = "bob"
      local w = build({ Safe = function(_, v) return real:Safe(v) end,
        InboxCount = function() return real:InboxCount() end,
        InboxCod = function(_, i) return real:InboxCod(i) end })
      assert.has_no.errors(function()
        w:OnEvent("MAIL_INBOX_UPDATE")
        hooks.TakeInboxItem(1, 1)
        w:OnEvent("MAIL_INBOX_UPDATE")
      end)
      assert.equal(0, #published)
    end)

    it("hook bodies never raise", function()
      local w = build({ SendMailSnapshot = function() error("boom") end, InboxCod = function() error("boom") end })
      assert.has_no.errors(function()
        hooks.SendMail("Bob-R", "s", "b")
        w:OnEvent("MAIL_INBOX_UPDATE")
        hooks.TakeInboxItem(1, 1)
        hooks.AutoLootMailItem(1)
      end)
    end)
  end)
end)
