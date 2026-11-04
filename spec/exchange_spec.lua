describe("Exchange", function()
  local fakes = require("spec.helpers.fakes")
  local clock, timers, bus, nodes, ns0

  local function mkns()
    local ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log", "Profile" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Observations.lua")
    for _, f in ipairs({ "Listing", "Format", "MailDrafts", "Deals", "Exchange" }) do
      loadAddonFile(ns, "Guildhall/Modules/Exchange/" .. f .. ".lua")
    end
    return ns
  end

  -- node(name, o): o.trial, o.consent (default true), o.officer, o.mailbox, o.online{}, o.id
  local function node(name, o)
    o = o or {}
    local ns = mkns()
    local n = { name = name, ns = ns, opened = {}, online = o.online or {}, officers = {} }
    n.roster = {
      IsOnline = function(_, c) return n.online[c] end,
      IsOfficer = function(_, c) return n.officers[c] end,
    }
    local compat, env = fakes.compat({
      IsTrialAccount = function() return o.trial end,
      ChatFrameUtil = { OpenChat = function(t) n.opened[#n.opened + 1] = t end },
      MailFrameTab_OnClick = function() end,
      SendMailNameEditBox = { SetText = function(_, t) n.mailTo = t end },
      SendMailSubjectEditBox = { SetText = function(_, t) n.mailSubject = t end },
      SendMailBodyEditBox = { SetText = function(_, t) n.mailBody = t end },
    })
    n.compat = compat
    if o.mailbox then compat:SetMailboxOpen(true) end
    local personal = ns.DB.Init().personal
    n.profSet = ns.ReplicatedSet.new("profiles", {}, { now = clock.now })
    local ids = o.id
    n.profile = ns.Profile.new({
      personal = personal, set = n.profSet, now = clock.now, roster = n.roster,
      random = function() return ids or 7 end, playerChar = name, defaultRealm = "Realm",
      guildKey = "Guild-Realm",
    })
    n.profile:SeeCharacter(name)
    if o.consent ~= false then n.profile:Consent({}) end
    n.logStore = {}
    n.log = ns.Log.new(n.logStore, clock.now, function() return "" end)
    n.moduleDb = {}
    local comm = bus:join(name)
    local ctx = {
      compat = compat, comm = comm, now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = n.log, roster = n.roster, profile = n.profile,
      playerChar = name, moduleDb = n.moduleDb,
    }
    n.obs = ns.Observations.New({ comm = comm, now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = n.log, roster = n.roster, profile = n.profile,
      playerChar = name, db = {} })
    ctx.observations = n.obs
    n.ex = ns.Exchange.Create(ctx)
    nodes[name] = n
    return n
  end

  local function post(n, d)
    local ok, rec = n.ex:Post(d or { kind = "WTS", item = "Linen Cloth", mats = false, cod = false })
    assert.is_true(ok, tostring(rec))
    return rec
  end

  before_each(function()
    clock = fakes.clock(1000)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    nodes = {}
  end)

  it("post on A appears on B with create log entry relayed by A", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    assert.is_not_nil(b.ex:Get(rec.id))
    local e = b.logStore[#b.logStore]
    assert.equal("create", e.action)
    assert.equal("accepted", e.result)
    assert.equal("Alice-Realm", e.relayer)
    assert.equal("exchange.listings", e.set)
    assert.equal("create", a.logStore[1].action)
  end)

  it("Post refuses on trial account", function()
    local a = node("Alice-Realm", { trial = true })
    local ok, err = a.ex:Post({ kind = "WTS", item = "x", mats = false, cod = false })
    assert.is_false(ok); assert.equal("trial", err)
  end)

  it("Post refuses before consent", function()
    local a = node("Alice-Realm", { consent = false })
    local ok, err = a.ex:Post({ kind = "WTS", item = "x", mats = false, cod = false })
    assert.is_false(ok); assert.equal("consent", err)
  end)

  it("posting, editing, renewing and removing from an excluded character is refused (I4)", function()
    local a = node("Alice-Realm", { id = 1 })
    local rec = post(a)
    -- the player later unchecks this character ("Change..." in Settings)
    a.profile.p.chars["Alice-Realm"].included = nil
    a.profile:Consent({ "Alice-Realm" })
    local before = #a.logStore
    local ok, err = a.ex:Post({ kind = "WTS", item = "x", mats = false, cod = false })
    assert.is_false(ok); assert.equal("excluded", err)
    for _, fn in ipairs({ "Renew", "Remove" }) do
      ok, err = a.ex[fn](a.ex, rec.id)
      assert.is_false(ok); assert.equal("excluded", err)
    end
    ok, err = a.ex:Edit(rec.id, { note = "hi" })
    assert.is_false(ok); assert.equal("excluded", err)
    assert.equal(before, #a.logStore) -- nothing was published
  end)

  it("Post returns the validation error", function()
    local a = node("Alice-Realm")
    local ok, err = a.ex:Post({ kind = "XX", item = "x", mats = false, cod = false })
    assert.is_false(ok); assert.equal("bad kind", err)
  end)

  it("List mine includes listings from linked alts", function()
    local a = node("Alice-Realm", { id = 1 })
    local r1 = post(a)
    clock.advance(10)
    local _, r2 = a.ex:Post({ kind = "LF", item = "Copper", mats = true, cod = false })
    -- a listing by this profile posted from an alt character
    a.ex.listings:Apply({ id = r1.by .. ":99", v = 1, t = 1005, by = r1.by, char = "Alt-Realm",
      exp = 5000, del = false, d = { kind = "LF", item = "Alt thing", mats = false, cod = false } })
    a.ex.listings:Apply({ id = "other:1", v = 1, t = 1005, by = "other", char = "O-Realm",
      exp = 5000, del = false, d = { kind = "LF", item = "Not mine", mats = false, cod = false } })
    assert.equal(3, #a.ex:List("mine"))
    assert.equal(4, #a.ex:List("all"))
    assert.equal(r2.id, a.ex:List("all")[1].id)
    assert.equal(3, #a.ex:List("LF"))
    assert.equal(1, #a.ex:List("WTS"))
  end)

  local function peerListing(n, chars)
    n.profSet:Apply({ id = "peer", v = 1, t = 1000, by = "peer", exp = 99999, d = { chars = chars } })
    local rec = { id = "peer:1", v = 1, t = 1000, by = "peer", char = chars[1], exp = 5000, del = false,
      d = { kind = "WTS", item = "Thing", mats = false, cod = false } }
    n.ex.listings:Apply(rec)
    return rec
  end

  it("Contact whispers online alt of owner", function()
    local a = node("Alice-Realm")
    local rec = peerListing(a, { "Main-Realm", "Alt-Realm" })
    a.online["Alt-Realm"] = true
    assert.equal("whisper", a.ex:Contact(rec))
    assert.truthy(a.opened[1]:match("^/w Alt%-Realm "))
  end)

  it("Contact drafts mail when owner offline and no mailbox", function()
    local a = node("Alice-Realm")
    local rec = peerListing(a, { "Main-Realm" })
    a.online["Main-Realm"] = false
    assert.equal("drafted", a.ex:Contact(rec))
    assert.equal(1, a.ex.drafts:Count())
    assert.equal("Main-Realm", a.ex:OnMailShow().to)
    assert.equal(0, #a.opened)
    a.ex:DismissDraft(a.ex:OnMailShow().id)
    assert.is_nil(a.ex:OnMailShow())
  end)

  it("Contact fills mail when mailbox open", function()
    local a = node("Alice-Realm", { mailbox = true })
    local rec = peerListing(a, { "Main-Realm" })
    a.online["Main-Realm"] = false
    assert.equal("mail", a.ex:Contact(rec))
    assert.equal("Main-Realm", a.mailTo)
    assert.equal(0, a.ex.drafts:Count())
  end)

  it("Contact whispers when owner status unknown", function()
    local a = node("Alice-Realm")
    local rec = peerListing(a, { "Main-Realm" })
    assert.equal("unknown", (a.ex:Status(rec)))
    assert.equal("whisper", a.ex:Contact(rec))
  end)

  it("FillDraft fills mail and removes the draft", function()
    local a = node("Alice-Realm")
    local rec = peerListing(a, { "Main-Realm" })
    a.online["Main-Realm"] = false
    a.ex:Contact(rec)
    assert.is_true(a.ex:FillDraft(a.ex:OnMailShow()))
    assert.equal("Main-Realm", a.mailTo)
    assert.equal(0, a.ex.drafts:Count())
  end)

  it("officer remove logged as officer-remove", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    b.officers["Bob-Realm"] = true
    a.officers["Bob-Realm"] = true
    clock.advance(5)
    local ok = b.ex:OfficerRemove(rec.id)
    assert.is_true(ok)
    assert.equal("officer-remove", a.logStore[#a.logStore].action)
    assert.equal("Bob-Realm", a.logStore[#a.logStore].relayer)
    assert.equal("officer-remove", b.logStore[#b.logStore].action)
    assert.equal(b.profile:Id(), a.logStore[#a.logStore].author)
    assert.equal(rec.by, a.ex.listings:Get(rec.id).by)
    assert.equal(0, #a.ex:List("all"))
  end)

  it("officer removal and a same-version owner renew converge in either order (M2)", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    local L = a.ns.Exchange.Listing
    local off = L.Remove(rec, "Bob-Realm", 1005, true, b.profile:Id())
    local renew = L.Renew(rec, "Alice-Realm", 1010)
    local c, d = node("Carol-Realm", { id = 3 }), node("Dave-Realm", { id = 4 })
    c.officers["Bob-Realm"] = true; d.officers["Bob-Realm"] = true
    local cp = a.ns.Util.DeepCopy
    c.ex.sync:_onRec({ rs = { cp(rec) } }, "Alice-Realm"); d.ex.sync:_onRec({ rs = { cp(rec) } }, "Alice-Realm")
    c.ex.sync:_onRec({ rs = { cp(off) } }, "Bob-Realm"); c.ex.sync:_onRec({ rs = { cp(renew) } }, "Alice-Realm")
    d.ex.sync:_onRec({ rs = { cp(renew) } }, "Alice-Realm"); d.ex.sync:_onRec({ rs = { cp(off) } }, "Bob-Realm")
    local cr, dr = c.ex.listings:Get(rec.id), d.ex.listings:Get(rec.id)
    assert.equal(1010, cr.t); assert.equal(1010, dr.t)
    assert.is_false(cr.del); assert.is_false(dr.del)
  end)

  it("an officer removal from a name the read roster does not know is rejected (M1)", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    b.roster.HasRanks = function() return true end
    local off = a.ns.Exchange.Listing.Remove(rec, "Forger-Realm", 1005, true, "ffffffffffff")
    b.ex.sync:_onRec({ rs = { off } }, "Forger-Realm")
    assert.is_false(b.ex.listings:Get(rec.id).del)
    assert.equal("not officer", b.logStore[#b.logStore].reason)
  end)

  it("OfficerRemove refuses non-officers and own listings", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    local ok, err = b.ex:OfficerRemove(rec.id)
    assert.is_false(ok); assert.equal("not officer", err)
    a.officers["Alice-Realm"] = true
    ok, err = a.ex:OfficerRemove(rec.id)
    assert.is_false(ok); assert.equal("not officer", err)
  end)

  it("Edit by a non-owner is refused", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    local ok, err = b.ex:Edit(rec.id, { item = "Hax" })
    assert.is_false(ok); assert.equal("not owner", err)
    assert.is_false((b.ex:Renew(rec.id))); assert.is_false((b.ex:Remove(rec.id)))
    assert.equal("Linen Cloth", a.ex:Get(rec.id).d.item)
  end)

  it("Edit, Renew and Remove log edit, renew and remove", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    clock.advance(10)
    assert.is_true((a.ex:Edit(rec.id, { item = "Silk" })))
    assert.equal("edit", b.logStore[#b.logStore].action)
    assert.equal("Linen Cloth", b.logStore[#b.logStore].before.item)
    assert.equal("Silk", b.logStore[#b.logStore].after.item)
    local ok, err = a.ex:Edit(rec.id, { kind = "bad" })
    assert.is_false(ok); assert.equal("bad kind", err)
    clock.advance(10)
    assert.is_true((a.ex:Renew(rec.id)))
    assert.equal("renew", b.logStore[#b.logStore].action)
    clock.advance(10)
    assert.is_true((a.ex:Remove(rec.id)))
    assert.equal("remove", b.logStore[#b.logStore].action)
    assert.equal(0, #b.ex:List("all"))
  end)

  it("log entries hold copies of payloads", function()
    local a = node("Alice-Realm", { id = 1 })
    local rec = post(a)
    clock.advance(10)
    a.ex:Edit(rec.id, { item = "Silk" })
    local e = a.logStore[#a.logStore]
    a.ex:Get(rec.id).d.item = "MUTATED"
    assert.equal("Silk", e.after.item)
    assert.equal("Linen Cloth", e.before.item)
  end)

  it("invalid incoming records are logged as rejected", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = post(a)
    local bad = { id = rec.id, v = 2, t = 1100, by = "intruder", char = "X-Realm", exp = 5000, del = false, d = rec.d }
    b.ex.sync:_applyOne(bad, "X-Realm")
    local e = b.logStore[#b.logStore]
    assert.equal("rejected", e.result); assert.equal("not owner", e.reason)
  end)

  it("expired listings are hidden and purged on Start", function()
    local a = node("Alice-Realm", { id = 1 })
    local rec = post(a)
    clock.advance(604800 + 1)
    assert.equal(0, #a.ex:List("all"))
    assert.is_not_nil(a.moduleDb.listings[rec.id])
    a.ex:Start()
    assert.is_nil(a.moduleDb.listings[rec.id])
  end)

  it("imported records appear in List all but not mine, and are never sent", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local lines = {}
    local oc = a.ex.sync.comm.compat
    local osend = oc.SendAddon
    oc.SendAddon = function(self, prefix, line, ...) lines[#lines + 1] = line; return osend(self, prefix, line, ...) end
    a.online["Alice-Realm"] = true
    a.moduleDb.imported["imp:1"] = { id = "imp:1", v = 1, t = 1000, by = a.profile:Id(), exp = 5000, del = false,
      d = { kind = "WTS", item = "Discord thing", mats = false, cod = false, src = "discord", poster = "Zed" } }
    assert.equal(1, #a.ex:List("all"))
    assert.equal(0, #a.ex:List("mine"))
    assert.is_false((a.ex:Edit("imp:1", { item = "x" })))
    local rec = a.ex:List("all")[1]
    local status, char = a.ex:Status(rec)
    assert.equal("unknown", status); assert.is_nil(char)
    assert.equal("no-contact", a.ex:Contact(rec))
    assert.equal(0, #a.opened)
    post(a)
    b.ex:Start(); clock.advance(10); timers.run(clock)
    assert.is_true(#lines > 0)
    for _, l in ipairs(lines) do assert.is_nil(l:find("imp:1", 1, true)) end
    assert.is_nil(b.ex:Get("imp:1"))
    assert.equal(1, #b.ex:List("all"))
    a.ex:RemoveImported("imp:1")
    assert.equal(1, #a.ex:List("all"))
  end)

  it("imported record with an online guildmate char reports that guildmate", function()
    local a = node("Alice-Realm", { id = 1 })
    a.online["Alice-Realm"] = true; a.online["Zed-Realm"] = true
    local rec = { id = "imp:2", v = 1, t = 1000, by = a.profile:Id(), char = "Zed-Realm", exp = 5000, del = false,
      d = { kind = "WTS", item = "X", mats = false, cod = false, src = "discord", poster = "Zed" } }
    a.moduleDb.imported["imp:2"] = rec
    local st, c = a.ex:Status(rec)
    assert.equal("online", st); assert.equal("Zed-Realm", c)
    assert.equal("whisper", a.ex:Contact(rec))
    assert.truthy(a.opened[1]:match("^/w Zed%-Realm "))
    a.online["Zed-Realm"] = false
    assert.equal("offline", (a.ex:Status(rec)))
    a.online["Zed-Realm"] = nil
    assert.equal("unknown", (a.ex:Status(rec)))
  end)

  it("actions fail when the publish is not accepted", function()
    local a = node("Alice-Realm", { id = 1 })
    local rec = post(a)
    clock.advance(604800 + 1)
    local ok, err = a.ex:Edit(rec.id, { item = "Silk" })
    assert.is_false(ok); assert.equal("expired", err)
  end)

  it("Contact on own listing is no-contact", function()
    local a = node("Alice-Realm", { id = 1 })
    local rec = post(a)
    assert.equal("no-contact", a.ex:Contact(rec))
    assert.equal(0, #a.opened)
  end)

  it("a combined edit and renew keeps before/after in the log", function()
    local a = node("Alice-Realm", { id = 1 })
    local rec = post(a)
    clock.advance(10)
    local new = a.ex.listings:Get(rec.id)
    local r = a.ns.Exchange.Listing.Renew(a.ns.Util.DeepCopy(new), "Alice-Realm", clock.now())
    r.d.item = "Silk"
    a.ex.sync:Publish(r)
    local e = a.logStore[#a.logStore]
    assert.equal("renew", e.action)
    assert.equal("Silk", e.after.item); assert.equal("Linen Cloth", e.before.item)
  end)

  it("registers the module and OnLogin guards missing services", function()
    local ns = mkns()
    ns.RegisterModule = function(name, def) ns.reg = { name = name, def = def } end
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Exchange.lua")
    assert.equal("Exchange", ns.reg.name)
    assert.equal("Exchange", ns.reg.def.tab.title)
    ns.reg.def.OnLogin(ns)
    assert.is_nil(ns.exchange)
  end)
  describe("manual deals and witnesses", function()
    local LINK = "|Hitem:2589::|h[Linen Cloth]|h"
    local function wts(n, kind) return post(n, { kind = kind or "WTS", item = LINK, qty = 20, mats = false, cod = false }) end
    local function ids(n) return n.profile:Id() end
    local function derive(n)
      local out = {}
      for _, kind in ipairs({ "manual" }) do
        for _, c in ipairs(n.ns.Activity.Deriver(kind)(n.obs:List(kind), {})) do out[#out + 1] = c end
      end
      return out
    end

    it("RecordDeal on someone else's listing with me as partner works; a third party is refused", function()
      local a, b, c = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 }), node("Cy-Realm", { id = 3 })
      local rec = wts(a)
      local ok, o = b.ex:RecordDeal(rec.id, ids(a), 20, 50000)
      assert.is_true(ok, tostring(o))
      assert.equal("manual", o.d.kind)
      assert.equal(ids(a), o.d.seller); assert.equal(ids(b), o.d.buyer)
      assert.equal(2589, o.d.item)
      local ok2, why = c.ex:RecordDeal(rec.id, ids(b), 20, 50000)
      assert.is_false(ok2); assert.is_string(why)
      assert.is_false((b.ex:RecordDeal(rec.id, ids(b), 20, 50000)))
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 0, 50000)))
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 20, -1)))
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 20, 1.5)))
      assert.is_false((b.ex:RecordDeal("nope", ids(a), 20, 5)))
      -- an LF listing: the owner buys
      local lf = wts(a, "LF")
      local _, o2 = b.ex:RecordDeal(lf.id, ids(a), 5, 100)
      assert.equal(ids(b), o2.d.seller); assert.equal(ids(a), o2.d.buyer)
    end)

    it("confirmation queue lists it for the partner only, and confirming pairs it", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      assert.is_true(b.ex:RecordDeal(rec.id, ids(a), 20, 50000))
      assert.equal(0, #b.ex:PendingConfirmations())
      local q = a.ex:PendingConfirmations()
      assert.equal(1, #q)
      assert.equal(rec.id, q[1].listing.id)
      for _, c in ipairs(derive(a)) do assert.is_false(c.counted) end
      assert.is_true(a.ex:ConfirmDeal(q[1].obs.id))
      assert.equal(0, #a.ex:PendingConfirmations())
      local counted = 0
      for _, c in ipairs(derive(b)) do if c.counted then counted = counted + 1 end end
      assert.equal(4, counted)
    end)

    it("decline hides it", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      b.ex:RecordDeal(rec.id, ids(a), 20, 50000)
      local q = a.ex:PendingConfirmations()
      a.ex:DeclineDeal(q[1].obs.id)
      assert.equal(0, #a.ex:PendingConfirmations())
      assert.equal(clock.now(), a.moduleDb.declined[q[1].obs.id])
    end)

    it("a 25 h old listing gets one witness from a non-owner; the owner's client doesn't witness", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      clock.advance(25 * 3600)
      a.ex:Start()
      assert.equal(0, #a.obs:List("witness"))
      b.ex:Start()
      local w = b.obs:List("witness")
      assert.equal(1, #w)
      assert.equal(rec.id, w[1].d.listing); assert.equal(ids(a), w[1].d.owner)
      assert.equal(rec.t, w[1].d.at)
      b.ex:Start(); b.ex:_witness()
      assert.equal(1, #b.obs:List("witness"))
    end)

    it("a 23 h old listing gets no witness", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      wts(a)
      clock.advance(23 * 3600)
      b.ex:Start()
      assert.equal(0, #b.obs:List("witness"))
    end)

    it("a listing with both a witness and a deal counts once", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      b.ex:RecordDeal(rec.id, ids(a), 20, 50000)
      a.ex:ConfirmDeal(a.ex:PendingConfirmations()[1].obs.id)
      local function count(n)
        local k = 0
        for _, c in ipairs(n.ns.Activity.Deriver("witness")(n.obs:List("witness"), { observations = n.obs })) do
          if c.type == "exchange.listings" then k = k + 1; assert.equal(ids(a), c.profile) end
        end
        return k
      end
      assert.equal(1, count(b))   -- deal alone
      clock.advance(25 * 3600)
      b.ex:Start()
      assert.equal(1, #b.obs:List("witness"))
      assert.equal(1, count(b))   -- deal plus witness
    end)
  end)
  describe("fix round 1", function()
    local LINK = "|Hitem:2589::|h[Linen Cloth]|h"
    local function wts(n, kind) return post(n, { kind = kind or "WTS", item = LINK, qty = 20, mats = false, cod = false }) end
    local function ids(n) return n.profile:Id() end
    local function witnessCredits(n)
      return n.ns.Activity.Deriver("witness")(n.obs:List("witness"), { observations = n.obs })
    end
    local function countedSales(n)
      local k = 0
      for _, kind in ipairs({ "trade", "cod", "manual" }) do
        for _, c in ipairs(n.ns.Activity.Deriver(kind)(n.obs:List(kind), { observations = n.obs })) do
          if c.counted and c.type == "exchange.sales" then k = k + 1 end
        end
      end
      return k
    end

    it("a deal on a typed listing records, confirms and pairs", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local typed = post(a)
      local ok, o = b.ex:RecordDeal(typed.id, ids(a), 1, 100)
      assert.is_true(ok, tostring(o))
      assert.equal("Linen Cloth", o.d.item)
      assert.is_true(a.ex:ConfirmDeal(a.ex:PendingConfirmations()[1].obs.id))
      assert.equal(1, countedSales(a))
    end)

    it("RecordDeal refuses a listing that ended more than 48 h ago", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      a.ex:Remove(rec.id)
      assert.is_true((b.ex:RecordDeal(rec.id, ids(a), 1, 100)))
      clock.advance(3 * 86400)
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 1, 100)))
    end)

    it("CheckIncoming rejects a listing id whose prefix is not the author", function()
      local a, m = node("Alice-Realm", { id = 1 }), node("Mal-Realm", { id = 3 })
      local L = m.ns.Exchange.Listing.New({ kind = "WTS", item = LINK, qty = 1, mats = false, cod = false },
        ids(m), "Mal-Realm", clock.now(), 1)
      L.id = ids(a) .. ":900"
      m.ex.sync:Publish(L)
      assert.is_nil(a.ex:Get(L.id))
      assert.equal("bad id", a.logStore[#a.logStore].reason)
    end)

    it("observations carry the listing owner", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      local _, o = b.ex:RecordDeal(rec.id, ids(a), 20, 50000)
      assert.equal(ids(a), o.d.owner)
    end)

    it("a malformed manual observation neither crashes nor is listed", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      b.obs:Publish({ kind = "manual", listing = rec.id, seller = ids(a), buyer = ids(b), item = 2589,
        count = true, copper = 5, at = clock.now() })
      local ok, q = pcall(function() return a.ex:PendingConfirmations() end)
      assert.is_true(ok, tostring(q))
      assert.equal(0, #q)
      assert.is_false((a.ex:ConfirmDeal("x")))
    end)

    it("a manual deal on top of a paired trade is refused and counts nothing extra", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      local d = { kind = "trade", listing = rec.id, seller = ids(a), buyer = ids(b), item = 2589, count = 20,
        copper = 50000, at = clock.now(), owner = ids(a) }
      a.obs:Publish(d); b.obs:Publish(d)
      local ok, why = b.ex:RecordDeal(rec.id, ids(a), 20, 50000)
      assert.is_false(ok); assert.equal("already recorded", why)
      -- a manual observation from an older build still adds nothing and is not offered
      b.obs:Publish({ kind = "manual", listing = rec.id, seller = ids(a), buyer = ids(b), item = 2589,
        count = 20, copper = 50000, at = clock.now() })
      assert.equal(0, #a.ex:PendingConfirmations())
      a.obs:Publish({ kind = "manual", listing = rec.id, seller = ids(a), buyer = ids(b), item = 2589,
        count = 20, copper = 50000, at = clock.now() })
      assert.equal(1, countedSales(a))
    end)

    it("confirming republishes only the known fields", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      b.obs:Publish({ kind = "manual", listing = rec.id, seller = ids(a), buyer = ids(b), item = 2589,
        count = 20, copper = 50000, at = clock.now(), junk = "x" })
      assert.is_true(a.ex:ConfirmDeal(a.ex:PendingConfirmations()[1].obs.id))
      for _, o in ipairs(a.obs:List("manual")) do
        if o.by == ids(a) then assert.is_nil(o.d.junk) end
      end
    end)

    it("a purged listing still lists the confirmation from the observation's fields", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      b.ex:RecordDeal(rec.id, ids(a), 20, 50000)
      a.moduleDb.listings[rec.id] = nil
      local q = a.ex:PendingConfirmations()
      assert.equal(1, #q)
      assert.equal(rec.id, q[1].listing.id)
      assert.is_true(a.ex:ConfirmDeal(q[1].obs.id))
    end)

    it("Start prunes declines that are old or whose observation is gone", function()
      local a = node("Alice-Realm", { id = 1 })
      a.moduleDb.declined["gone"] = clock.now()
      a.ex:Start()
      assert.is_nil(a.moduleDb.declined["gone"])
    end)

    it("witness checks are debounced through ctx.after", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      b.ex:Start()
      local runs = 0
      local orig = b.ex._witness
      b.ex._witness = function(self) runs = runs + 1; return orig(self) end
      wts(a); wts(a); wts(a)
      assert.equal(0, runs)
      clock.advance(3)
      timers.run(clock)
      assert.equal(1, runs)
    end)

    it("price and count limits", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = wts(a)
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 1, 0)))
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 1, 10000000001)))
      assert.is_false((b.ex:RecordDeal(rec.id, ids(a), 10001, 5)))
      assert.is_true((b.ex:RecordDeal(rec.id, ids(a), 10000, 10000000000)))
    end)

    it("a same-profile witness gives no credit", function()
      local a = node("Alice-Realm", { id = 1 })
      local rec = wts(a)
      a.obs:Publish({ kind = "witness", listing = rec.id, owner = ids(a), at = rec.t })
      assert.equal(0, #witnessCredits(a))
    end)

    it("a forged or mismatched owner earns nothing, and a real one is credited at creation", function()
      local a, b, c = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 }), node("Cy-Realm", { id = 3 })
      local rec = wts(a)
      for i = 1, 3 do
        c.obs:Publish({ kind = "witness", listing = "fake:" .. i, owner = ids(b), at = clock.now() })
      end
      c.obs:Publish({ kind = "witness", listing = rec.id, owner = ids(c), at = clock.now() })
      assert.equal(0, #witnessCredits(a))
      clock.advance(25 * 3600)
      b.ex:Start()   -- the bogus witness does not stop the real one
      local credits = witnessCredits(a)
      assert.equal(1, #credits)
      assert.equal(ids(a), credits[1].profile); assert.equal(rec.t, credits[1].at)
    end)

    it("an id-prefix squat can't be witnessed or deal-credited to the prefix owner", function()
      local a, b, m = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 }), node("Mal-Realm", { id = 3 })
      local L = m.ns.Exchange.Listing.New({ kind = "WTS", item = LINK, qty = 1, mats = false, cod = false },
        ids(m), "Mal-Realm", clock.now(), 1)
      L.id = ids(b) .. ":900"
      m.ex.sync:Publish(L)
      m.obs:Publish({ kind = "manual", listing = L.id, seller = ids(m), buyer = ids(a), item = 2589, count = 1,
        copper = 100, at = clock.now(), owner = ids(b), listed = clock.now() })
      a.obs:Publish({ kind = "manual", listing = L.id, seller = ids(m), buyer = ids(a), item = 2589, count = 1,
        copper = 100, at = clock.now(), owner = ids(b), listed = clock.now() })
      for _, c in ipairs(witnessCredits(a)) do assert.is_not.equal(ids(b), c.profile) end
      assert.equal(0, #witnessCredits(a))
    end)
  end)
end)
