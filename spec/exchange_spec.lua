describe("Exchange", function()
  local fakes = require("spec.helpers.fakes")
  local clock, timers, bus, nodes, ns0

  local function mkns()
    local ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log", "Profile" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    for _, f in ipairs({ "Listing", "Format", "MailDrafts", "Exchange" }) do
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
    })
    n.profile:SeeCharacter(name)
    if o.consent ~= false then n.profile:Consent({}) end
    n.logStore = {}
    n.log = ns.Log.new(n.logStore, clock.now, function() return "" end)
    n.moduleDb = {}
    n.ex = ns.Exchange.Create({
      compat = compat, comm = bus:join(name), now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = n.log, roster = n.roster, profile = n.profile,
      playerChar = name, moduleDb = n.moduleDb,
    })
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
    assert.equal(0, #a.ex:List("all"))
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
    local sent = 0
    local orig = a.ex.sync.comm.Send
    a.ex.sync.comm.Send = function(self, ...) sent = sent + 1; return orig(self, ...) end
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
    a.ex:Start(); clock.advance(10); timers.run(clock)
    assert.is_nil(b.ex:Get("imp:1"))
    a.ex:RemoveImported("imp:1")
    assert.equal(0, #a.ex:List("all"))
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
end)
