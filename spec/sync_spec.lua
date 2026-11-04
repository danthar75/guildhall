describe("Sync", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, bus, nodes

  local function rec(o)
    local r = { id = "a", v = 1, t = 1000, by = "p1", char = "Bob-Realm", exp = 5000, del = false, d = { x = 1 } }
    for k, v in pairs(o or {}) do r[k] = v end
    return r
  end

  -- a member: comm on the bus + its own set + sync, recording onApplied calls
  local function node(name, o)
    o = o or {}
    local n = { name = name, applied = {}, store = {} }
    n.comm = bus:join(name)
    n.set = ns.ReplicatedSet.new("t", n.store, { now = clock.now })
    n.sync = ns.Sync.new({
      comm = n.comm, set = n.set, module = "test",
      after = timers.after,
      random = o.random or function(lo) return lo end,
      validate = o.validate,
      playerName = name,
      onApplied = function(r, status, old, sender, reason)
        n.applied[#n.applied + 1] = { rec = r, status = status, old = old, sender = sender, reason = reason }
      end,
    })
    nodes[name] = n
    return n
  end

  local function wait(s) clock.advance(s); timers.run(clock) end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/ReplicatedSet.lua")
    loadAddonFile(ns, "Guildhall/Core/Sync.lua")
    clock = fakes.clock(1000)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    nodes = {}
  end)

  it("Publish reaches peers and applies locally", function()
    local a, b = node("Alice-Realm"), node("Bob-Realm")
    a.sync:Publish(rec())
    assert.is_not_nil(a.set:Get("a"))
    assert.is_not_nil(b.set:Get("a"))
    assert.equal("accepted", b.applied[1].status)
    assert.equal("Alice-Realm", b.applied[1].sender)
    assert.equal("accepted", a.applied[1].status)
    assert.equal("Alice-Realm", a.applied[1].sender)
  end)

  it("Publish does not send when local apply is not accepted", function()
    local a, b = node("Alice-Realm"), node("Bob-Realm")
    a.sync:Publish(rec({ v = 2 }))
    a.sync:Publish(rec({ v = 1 }))
    assert.equal(2, b.set:Get("a").v)
    assert.equal("stale", a.applied[2].status)
    assert.equal(1, #b.applied)
  end)

  it("late joiner receives missing records after REQ", function()
    local a = node("Alice-Realm")
    a.set:Apply(rec({ id = "x" })); a.set:Apply(rec({ id = "y" }))
    local c = node("Carol-Realm")
    c.sync:Start()
    assert.is_nil(c.set:Get("x"))
    wait(1)
    assert.is_not_nil(c.set:Get("x"))
    assert.is_not_nil(c.set:Get("y"))
    assert.equal("Alice-Realm", c.applied[1].sender)
  end)

  it("replies in batches of 5 records", function()
    local a = node("Alice-Realm")
    for i = 1, 12 do a.set:Apply(rec({ id = string.format("r%02d", i) })) end
    local c = node("Carol-Realm")
    local counts = {}
    c.comm:On("test", "REC", function(p) counts[#counts + 1] = #p.rs end)
    c.sync:Start()
    wait(1)
    assert.same({ 5, 5, 2 }, counts)
  end)

  it("peer reply is suppressed when another peer already sent the record", function()
    local a, b = node("Alice-Realm", { random = function() return 1 end }), node("Bob-Realm", { random = function() return 3 end })
    a.set:Apply(rec()); b.set:Apply(rec())
    local c = node("Carol-Realm")
    local fromB = 0
    local orig = b.comm.Send
    b.comm.Send = function(self, m, k, p) if k == "REC" then fromB = fromB + 1 end return orig(self, m, k, p) end
    c.sync:Start()
    wait(1)   -- Alice replies
    assert.is_not_nil(c.set:Get("a"))
    wait(3)   -- Bob's timer fires, nothing left
    assert.equal(0, fromB)
  end)

  it("a higher-version record seen suppresses only equal-or-lower pending ones", function()
    local a, b = node("Alice-Realm", { random = function() return 1 end }), node("Bob-Realm", { random = function() return 3 end })
    a.set:Apply(rec({ v = 1 })); b.set:Apply(rec({ v = 2 }))
    local c = node("Carol-Realm")
    c.sync:Start()
    wait(1); assert.equal(1, c.set:Get("a").v)
    wait(3); assert.equal(2, c.set:Get("a").v)
  end)

  it("multiple REQs during one wait merge into one pending reply", function()
    local a = node("Alice-Realm")
    a.set:Apply(rec())
    local c, d = node("Carol-Realm"), node("Dave-Realm")
    local recs = 0
    local o = a.comm.Send
    a.comm.Send = function(self, m, k, p) if k == "REC" then recs = recs + 1 end return o(self, m, k, p) end
    c.sync:Start(); d.sync:Start()
    wait(1)
    assert.equal(1, recs)
    assert.is_not_nil(c.set:Get("a")); assert.is_not_nil(d.set:Get("a"))
  end)

  it("validate failure skips apply and reports invalid with reason", function()
    local a = node("Alice-Realm")
    local b = node("Bob-Realm", { validate = function(r) return false, "bad thing" end })
    a.sync:Publish(rec())
    assert.is_nil(b.set:Get("a"))
    assert.equal("invalid", b.applied[1].status)
    assert.equal("bad thing", b.applied[1].reason)
    assert.equal("Alice-Realm", b.applied[1].sender)
  end)

  it("accepted record passes a validate reason through", function()
    local a = node("Alice-Realm")
    local b = node("Bob-Realm", { validate = function() return true, "officer unverified" end })
    a.sync:Publish(rec())
    assert.is_not_nil(b.set:Get("a"))
    assert.equal("accepted", b.applied[1].status)
    assert.equal("officer unverified", b.applied[1].reason)
  end)

  it("a throwing validator is reported invalid and does not propagate", function()
    local a = node("Alice-Realm")
    local b = node("Bob-Realm", { validate = function() error("boom") end })
    assert.has_no.errors(function() a.sync:Publish(rec()) end)
    assert.is_nil(b.set:Get("a"))
    assert.equal("invalid", b.applied[1].status)
    assert.truthy(b.applied[1].reason:find("^validate error: "))
  end)

  it("onApplied reports stale and invalid with sender", function()
    local a, b = node("Alice-Realm"), node("Bob-Realm")
    b.set:Apply(rec({ v = 5 }))
    a.sync:Publish(rec({ v = 1 }))
    a.comm:Send("test", "REC", { rs = { rec({ id = "z", exp = 1 }) } })  -- expired
    a.comm:Send("test", "REC", { rs = { { id = "" } } })
    assert.equal("stale", b.applied[1].status)
    assert.equal("Alice-Realm", b.applied[1].sender)
    assert.equal(5, b.applied[1].old.v)
    assert.equal("expired", b.applied[2].status)
    assert.equal("invalid", b.applied[3].status)
    assert.equal("Alice-Realm", b.applied[3].sender)
  end)

  it("newer local edit is not overwritten by older relayed copy", function()
    local a, b = node("Alice-Realm"), node("Bob-Realm")
    b.sync:Publish(rec({ v = 3, d = { x = 3 } }))
    a.comm:Send("test", "REC", { rs = { rec({ v = 2, d = { x = 2 } }) } })  -- older copy relayed
    assert.equal(3, b.set:Get("a").v)
    assert.equal(3, b.set:Get("a").d.x)
    assert.equal("stale", b.applied[#b.applied].status)
  end)

  it("malformed REC and REQ payloads are ignored safely", function()
    local a, b = node("Alice-Realm"), node("Bob-Realm")
    b.set:Apply(rec())
    a.comm:Send("test", "REC", "junk")
    a.comm:Send("test", "REC", { rs = "junk" })
    a.comm:Send("test", "REC", { rs = { 5, "x", { id = "" } } })
    assert.equal(1, #b.applied)
    assert.equal("invalid", b.applied[1].status)
    assert.equal("malformed", b.applied[1].reason)
    a.comm:Send("test", "REQ", { have = "junk" })
    wait(1)
    assert.is_not_nil(a.set:Get("a"))
  end)
end)
