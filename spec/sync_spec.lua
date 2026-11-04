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

  it("tie-break loser replying first does not suppress the winner", function()
    local a = node("Alice-Realm", { random = function() return 3 end })
    local b = node("Bob-Realm", { random = function() return 1 end })
    a.set:Apply(rec({ v = 3, t = 1200, d = { x = "win" } }))
    b.set:Apply(rec({ v = 3, t = 1100, d = { x = "lose" } }))
    local c = node("Carol-Realm")
    c.sync:Start()
    wait(1)
    assert.equal("lose", c.set:Get("a").d.x)
    wait(3)
    assert.equal("win", c.set:Get("a").d.x)
  end)

  it("same-version different-t copies converge after a REQ", function()
    local a, b = node("Alice-Realm"), node("Bob-Realm")
    a.set:Apply(rec({ v = 2, t = 1200, d = { x = "new" } }))
    b.set:Apply(rec({ v = 2, t = 1100, d = { x = "old" } }))
    b.sync:Start()
    wait(1)
    assert.equal("new", b.set:Get("a").d.x)
    assert.equal("new", a.set:Get("a").d.x)
  end)

  it("an invalid peer record does not suppress a good pending one", function()
    local a = node("Alice-Realm", { random = function() return 3 end })
    a.set:Apply(rec({ v = 3 }))
    local b = node("Bob-Realm")
    local c = node("Carol-Realm")
    c.sync:Start()
    b.comm:Send("test", "REC", { rs = { { id = "a", v = 9, t = 1, exp = 5000, del = "no" } } })
    wait(3)
    assert.is_not_nil(c.set:Get("a"))
  end)
  -- I1: paged digest, purge before digest, rate-limited Start.
  local function countKind(n, kind)
    local c = { n = 0, payloads = {} }
    local orig = n.comm.Send
    n.comm.Send = function(self, m, k, p)
      if k == kind then c.n = c.n + 1; c.payloads[#c.payloads + 1] = p end
      return orig(self, m, k, p)
    end
    return c
  end

  it("syncs 500 records between two members (digest is paged under the chunk cap)", function()
    bus = fakes.bus(clock, timers, { burst = 1e6 })
    local a, c = node("Alice-Realm"), node("Carol-Realm")
    for i = 1, 500 do
      local id = string.format("abcdef012345:%d", i)
      a.set:Apply(rec({ id = id, v = 2, t = 1100 }))
      c.set:Apply(rec({ id = id, v = 1 }))
    end
    local reqs = countKind(c, "REQ")
    c.sync:Start()
    assert.is_true(reqs.n > 1)
    wait(5)
    local behind = 0
    for i = 1, 500 do
      if c.set:Get(string.format("abcdef012345:%d", i)).v ~= 2 then behind = behind + 1 end
    end
    assert.equal(0, behind)
  end)

  it("REQ pages partition the id space without gaps or overlap", function()
    local c = node("Carol-Realm")
    for i = 1, 120 do c.set:Apply(rec({ id = string.format("r%03d", i) })) end
    local reqs = countKind(c, "REQ")
    c.sync:Start()
    assert.equal(3, reqs.n)
    local p = reqs.payloads
    assert.is_nil(p[1].after); assert.equal("r050", p[1].to)
    assert.equal("r050", p[2].after); assert.equal("r100", p[2].to)
    assert.equal("r100", p[3].after); assert.is_nil(p[3].to)
    local total = 0
    for _, pg in ipairs(p) do for _ in pairs(pg.have) do total = total + 1 end end
    assert.equal(120, total)
  end)

  it("a peer answers a ranged REQ only with ids inside (after, to]", function()
    local a = node("Alice-Realm")
    for i = 1, 10 do a.set:Apply(rec({ id = string.format("r%02d", i) })) end
    local b = node("Bob-Realm")
    local got = {}
    b.comm:On("test", "REC", function(p) for _, r in ipairs(p.rs) do got[#got + 1] = r.id end end)
    b.comm:Send("test", "REQ", { have = {}, after = "r05", to = "r08" })
    wait(1)
    table.sort(got)
    assert.same({ "r06", "r07", "r08" }, got)
  end)

  it("a REQ without a range (older peers) still covers every id", function()
    local a = node("Alice-Realm")
    for i = 1, 3 do a.set:Apply(rec({ id = "r" .. i })) end
    local b = node("Bob-Realm")
    local n = 0
    b.comm:On("test", "REC", function(p) n = n + #p.rs end)
    b.comm:Send("test", "REQ", { have = {} })
    wait(1)
    assert.equal(3, n)
  end)

  it("Start purges expired records before building the digest", function()
    local c = node("Carol-Realm")
    c.store["old"] = rec({ id = "old", exp = 900 })
    c.set:Apply(rec({ id = "live" }))
    local reqs = countKind(c, "REQ")
    c.sync:Start()
    assert.is_nil(c.store["old"])
    assert.is_nil(reqs.payloads[1].have["old"])
    assert.is_not_nil(reqs.payloads[1].have["live"])
  end)

  it("Start runs at most once per minute per set, with one trailing run", function()
    local c = node("Carol-Realm")
    local reqs = countKind(c, "REQ")
    assert.is_true(c.sync:Start())
    assert.is_false(c.sync:Start())
    wait(10)
    assert.is_false(c.sync:Start())
    assert.equal(1, reqs.n)
    wait(50)
    assert.equal(2, reqs.n)  -- the coalesced trailing run
    wait(120)
    assert.equal(2, reqs.n)
  end)
end)
