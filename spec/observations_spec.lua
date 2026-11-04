describe("Observations", function()
  local fakes = require("spec.helpers.fakes")
  local clock, timers, bus, nodes

  local function node(name, o)
    o = o or {}
    local ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log", "Profile" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Observations.lua")
    local n = { name = name, ns = ns }
    n.roster = { IsOnline = function() end, IsOfficer = function() end }
    local personal = ns.DB.Init().personal
    n.profSet = ns.ReplicatedSet.new("profiles", {}, { now = clock.now })
    n.profile = ns.Profile.new({
      personal = personal, set = n.profSet, now = clock.now, roster = n.roster,
      random = function() return o.id or 7 end, playerChar = name, defaultRealm = "Realm",
      guildKey = "Guild-Realm",
    })
    n.profile:SeeCharacter(name)
    n.profile:Consent(o.excluded and { name } or {})
    n.logStore = {}
    n.log = ns.Log.new(n.logStore, clock.now, function() return "" end)
    n.comm = bus:join(name)
    n.ctx = {
      comm = n.comm, now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = n.log, roster = n.roster, profile = n.profile, playerChar = name, db = {},
    }
    n.obs = ns.Observations.New(n.ctx)
    nodes[name] = n
    return n
  end

  before_each(function()
    clock = fakes.clock(1000000)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    nodes = {}
  end)

  local function trade(at) return { kind = "trade", at = at or clock.now(), copper = 5000, with = "Bob" } end

  it("Validate accepts a trade payload", function()
    local n = node("Alice-Realm")
    assert.is_true(n.ns.Observations.Validate({ kind = "trade", at = 100, copper = 5000,
      items = { { id = 1, n = 2 } }, with = "Bob-Realm" }))
  end)

  it("rejects unknown kind, nested tables, a 65-byte string, and items with 7 entries", function()
    local V = node("Alice-Realm").ns.Observations.Validate
    assert.is_false((V({ kind = "bogus", at = 1 })))
    assert.is_false((V({ kind = "trade", at = 1, extra = { 1 } })))
    assert.is_false((V({ kind = "trade", at = 1, with = string.rep("x", 65) })))
    assert.is_true((V({ kind = "trade", at = 1, with = string.rep("x", 64) })))
    local items = {}
    for i = 1, 7 do items[i] = { id = i, n = 1 } end
    assert.is_false((V({ kind = "trade", at = 1, items = items })))
    items[7] = nil
    assert.is_true((V({ kind = "trade", at = 1, items = items })))
    assert.is_false((V({ kind = "trade", at = 1.5 })))
    assert.is_false((V({ kind = "trade", at = 1, copper = 0 / 0 })))
  end)

  it("Publish replicates to a peer with an observe log entry", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local st, rec = a.obs:Publish(trade())
    assert.equal("accepted", st)
    assert.equal(rec.d.kind, b.obs:List("trade")[1].d.kind)
    assert.equal(1, #a.ctx.syncs)
    local e = b.logStore[#b.logStore]
    assert.equal("observe", e.action)
    assert.equal("core.observations", e.set)
    assert.equal("trade", e.after.kind)
    local _, rec2 = a.obs:Publish(trade())
    assert.not_equal(rec.id, rec2.id)
  end)

  it("Publish refuses from an excluded character", function()
    local a = node("Alice-Realm", { excluded = true })
    assert.equal("excluded", (a.obs:Publish(trade())))
    assert.equal(0, #a.obs:List())
  end)

  local function forge(from, rec)
    from.comm:Send("core.observations", "REC", { rs = { rec } })
  end

  it("incoming record with d.at 2 days ahead is rejected (Review Focus 3)", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local now = clock.now()
    forge(a, { id = "x:o1", v = 1, t = now, exp = now + 1000, by = a.profile:Id(), char = "Alice-Realm",
      d = trade(now + 2 * 86400) })
    assert.equal(0, #b.obs:List())
    assert.equal("rejected", b.logStore[#b.logStore].result)
  end)

  it("incoming record whose char belongs to another profile is rejected", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local now = clock.now()
    -- Bob's client knows Alice-Realm belongs to profile "aaaa"
    b.profSet:Apply({ id = "aaaa", v = 1, t = now, exp = now + 100000, by = "aaaa", char = "Carol-Realm",
      d = { chars = { "Carol-Realm" } } })
    local owner = b.profile:OwnerOf("Carol-Realm")
    assert.is_truthy(owner)
    forge(a, { id = "y:o1", v = 1, t = now, exp = now + 1000, by = "someone-else",
      char = "Carol-Realm", d = trade(now) })
    assert.equal(0, #b.obs:List())
    -- the true owner is accepted
    forge(a, { id = "z:o1", v = 1, t = now, exp = now + 1000, by = owner,
      char = "Carol-Realm", d = trade(now) })
    assert.equal(1, #b.obs:List())
  end)

  it("tombstones without a payload still bucket and sync", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local now = clock.now()
    forge(a, { id = "t:o1", v = 1, t = now, exp = now + 1000, by = a.profile:Id(), char = "Alice-Realm", del = true })
    assert.equal(0, #b.obs:List())
    assert.is_not_nil(b.obs.set:Get("t:o1"))
  end)


  it("ids differ for two publishes in the same second", function()
    local a = node("Alice-Realm", { id = 1 })
    local _, r1 = a.obs:Publish(trade())
    local _, r2 = a.obs:Publish(trade())
    assert.not_equal(r1.id, r2.id)
    assert.is_true(#r1.id <= 64)
  end)

  it("ids differ after a store reset for the same profile and time", function()
    local a = node("Alice-Realm", { id = 1 })
    local _, r1 = a.obs:Publish(trade())
    local ctx2 = {}
    for k, v in pairs(a.ctx) do ctx2[k] = v end
    ctx2.db, ctx2.syncs = {}, nil
    local fresh = a.ns.Observations.New(ctx2)
    local _, r2 = fresh:Publish(trade())
    assert.not_equal(r1.id, r2.id)
  end)

  it("accepts d.at exactly now + 86400 and rejects +86401", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local now = clock.now()
    local by = a.profile:Id()
    forge(a, { id = "ok:o1", v = 1, t = now, exp = now + 100000, by = by, char = "Alice-Realm", d = trade(now + 86400) })
    forge(a, { id = "no:o1", v = 1, t = now, exp = now + 1000, by = by, char = "Alice-Realm", d = trade(now + 86401) })
    assert.is_not_nil(b.obs.set:Get("ok:o1"))
    assert.is_nil(b.obs.set:Get("no:o1"))
  end)

  describe("per-record expiry", function()
    local RETENTION = 34560000

    it("Publish takes an exp between d.at and t + 400 days; it replicates and is pruned at exp", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local now = clock.now()
      local st, rec = a.obs:Publish(trade(now), { exp = now + 2 * 86400 })
      assert.equal("accepted", st)
      assert.equal(now + 2 * 86400, rec.exp)
      assert.equal(now + 2 * 86400, b.obs.set:Get(rec.id).exp)
      -- the default stays 400 days
      local _, long = a.obs:Publish(trade(now))
      assert.equal(now + RETENTION, long.exp)
      clock.advance(2 * 86400 - 1)
      assert.equal(2, #a.obs:List("trade"))
      clock.advance(1)
      assert.equal(1, #a.obs:List("trade"))
      assert.equal(1, #b.obs:List("trade"))
      assert.equal(1, b.obs.set:Purge())
      assert.is_nil(b.obs.set:Get(rec.id))
    end)

    it("Publish refuses an exp past the retention, before d.at, or not a number", function()
      local a = node("Alice-Realm", { id = 1 })
      local now = clock.now()
      assert.equal("invalid", (a.obs:Publish(trade(now), { exp = now + RETENTION + 1 })))
      assert.equal("invalid", (a.obs:Publish(trade(now), { exp = now - 1 })))
      assert.equal("invalid", (a.obs:Publish(trade(now), { exp = 0 / 0 })))
      assert.equal("invalid", (a.obs:Publish(trade(now), { exp = "soon" })))
      assert.equal(0, #a.obs:List())
      assert.equal("accepted", (a.obs:Publish(trade(now), { exp = now + RETENTION })))
    end)

    it("a kind may declare a longer retention, which bounds its exp instead", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      a.ns.Observations.AddKind("longish", nil, { retention = RETENTION + 1000 })
      b.ns.Observations.AddKind("longish", nil, { retention = RETENTION + 1000 })
      local now = clock.now()
      local d = { kind = "longish", at = now }
      assert.equal("accepted", (a.obs:Publish(d, { exp = now + RETENTION + 1000 })))
      assert.equal("invalid", (a.obs:Publish(d, { exp = now + RETENTION + 1001 })))
      assert.equal(1, #b.obs:List("longish"))
      local by = a.profile:Id()
      forge(a, { id = "long:o9", v = 1, t = now, exp = now + RETENTION + 1001, by = by, char = "Alice-Realm", d = d })
      assert.is_nil(b.obs.set:Get("long:o9"))
      -- other kinds keep 400 days
      assert.equal("invalid", (a.obs:Publish(trade(now), { exp = now + RETENTION + 1 })))
    end)

    it("an incoming record with exp past t + 400 days or before d.at is rejected", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local now = clock.now()
      local by = a.profile:Id()
      forge(a, { id = "far:o1", v = 1, t = now, exp = now + RETENTION + 1, by = by, char = "Alice-Realm",
        d = trade(now) })
      forge(a, { id = "early:o1", v = 1, t = now, exp = now + 10, by = by, char = "Alice-Realm",
        d = trade(now + 20) })
      assert.is_nil(b.obs.set:Get("far:o1"))
      assert.is_nil(b.obs.set:Get("early:o1"))
      assert.equal("rejected", b.logStore[#b.logStore].result)
      forge(a, { id = "ok:o2", v = 1, t = now, exp = now + RETENTION, by = by, char = "Alice-Realm",
        d = trade(now) })
      assert.is_not_nil(b.obs.set:Get("ok:o2"))
    end)
  end)

  it("Publish returns invalid on a bad payload", function()
    local a = node("Alice-Realm", { id = 1 })
    local st = a.obs:Publish({ kind = "bogus", at = 1 })
    assert.equal("invalid", st)
    assert.equal(0, #a.obs:List())
  end)
end)
