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
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Core/ReplicatedSet.lua")
    loadAddonFile(ns, "Guildhearth/Core/Sync.lua")
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

  describe("day buckets", function()
    local DAY = 86400
    local function bucket(r) return tostring(math.floor(r.d.at / DAY)) end

    local function bnode(name, o)
      o = o or {}
      local n = { name = name, applied = {}, store = {} }
      n.comm = bus:join(name)
      n.set = ns.ReplicatedSet.new("t", n.store, { now = clock.now })
      n.sync = ns.Sync.new({
        comm = n.comm, set = n.set, module = "test", after = timers.after,
        random = o.random or function(lo) return lo end,
        playerName = name, bucket = bucket,
      })
      nodes[name] = n
      return n
    end

    -- a record observed on day `day` (records live far beyond the test clock)
    local function obs(id, day, o)
      local r = rec({ id = id, exp = 1e9, d = { at = day * DAY + 100 } })
      for k, v in pairs(o or {}) do r[k] = v end
      return r
    end

    -- steps the clock a second at a time so timers scheduled by earlier timers also run
    local function settle(secs) for _ = 1, secs do wait(1) end end

    -- chunks of `kind` that member n queues on Comm (each Send adds its chunks to the queue tail)
    local function countChunks(n, kind)
      local c = { n = 0, chunks = 0 }
      local orig = n.comm.Send
      n.comm.Send = function(self, m, k, p)
        local before = self.tail
        local ok = orig(self, m, k, p)
        if k == kind then c.n = c.n + 1; c.chunks = c.chunks + (self.tail - before) end
        return ok
      end
      return c
    end

    local function size(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

    -- 300 records, 10 per day over days 1..30
    local function fill(n)
      for i = 1, 300 do n.set:Apply(obs(string.format("o%03d", i), (i - 1) % 30 + 1)) end
    end

    it("login sends one DAYS message and no REQ when in step", function()
      local a, b = bnode("Alice-Realm"), bnode("Bob-Realm")
      fill(a); fill(b)
      local days = { countKind(a, "DAYS"), countKind(b, "DAYS") }
      local reqs = { countKind(a, "REQ"), countKind(b, "REQ") }
      assert.is_true(b.sync:Start())
      settle(10)
      assert.equal(1, days[1].n + days[2].n)
      assert.equal(0, reqs[1].n + reqs[2].n)
      local n = 0
      for _ in pairs(days[2].payloads[1].h) do n = n + 1 end
      assert.equal(30, n)
    end)

    it("only differing days exchange records", function()
      local a, b = bnode("Alice-Realm"), bnode("Bob-Realm")
      fill(a); fill(b)
      a.set:Apply(obs("extra", 5))
      local bReqs = countKind(b, "REQ")   -- B's REQs are what A receives
      local aRecs = countKind(a, "REC")
      b.sync:Start()
      settle(10)
      assert.is_not_nil(b.set:Get("extra"))
      assert.is_true(bReqs.n > 0)
      for _, p in ipairs(bReqs.payloads) do assert.same({ "5" }, p.days) end
      local n = 0
      for _, p in ipairs(aRecs.payloads) do
        for _, r in ipairs(p.rs) do
          n = n + 1
          assert.equal("5", bucket(r))
        end
      end
      assert.equal(1, n)
    end)

    it("the side that is behind catches up too", function()
      local a, b = bnode("Alice-Realm"), bnode("Bob-Realm")
      fill(a); fill(b)
      b.set:Apply(obs("o007", 7, { v = 2, d = { at = 7 * DAY + 100, x = "new" } }))
      a.sync:Start()
      settle(10)
      assert.equal(2, a.set:Get("o007").v)
      assert.equal("new", a.set:Get("o007").d.x)
    end)

    it("a day only the receiver holds still reaches the DAYS sender", function()
      local a, b = bnode("Alice-Realm"), bnode("Bob-Realm")
      fill(a); fill(b)
      a.set:Apply(obs("lonely", 40))
      b.sync:Start()
      settle(10)
      assert.is_not_nil(b.set:Get("lonely"))
    end)

    it("an empty newcomer receives every day in one sync", function()
      local a, c = bnode("Alice-Realm"), bnode("Carol-Realm")
      fill(a)
      local reqs = countKind(a, "REQ")
      c.sync:Start()
      settle(400)
      assert.equal(300, size(c.store))
      assert.equal(0, reqs.n)   -- days Carol lacks go straight to records, no digest
    end)

    it("three peers and an empty newcomer: no digest REQs, newcomer catches up", function()
      local a = bnode("Alice-Realm", { random = function() return 1 end })
      local b = bnode("Bob-Realm", { random = function() return 3 end })
      local d = bnode("Dave-Realm", { random = function() return 5 end })
      fill(a); fill(b); fill(d)
      local c = bnode("Carol-Realm")
      local reqs = { countChunks(a, "REQ"), countChunks(b, "REQ"), countChunks(d, "REQ"), countChunks(c, "REQ") }
      c.sync:Start()
      settle(600)
      assert.equal(300, size(c.store))
      local chunks = 0
      for _, r in ipairs(reqs) do chunks = chunks + r.chunks end
      assert.equal(0, chunks)
    end)

    it("a DAYS range only covers its own days", function()
      local a = bnode("Alice-Realm")
      local b = { comm = bus:join("Bob-Realm") }
      a.set:Apply(obs("x", 1)); a.set:Apply(obs("y", 9))
      local recs = countKind(a, "REC")
      b.comm:Send("test", "DAYS", { h = {}, after = "5" })   -- covers days after "5" only
      settle(10)
      local ids = {}
      for _, p in ipairs(recs.payloads) do for _, r in ipairs(p.rs) do ids[#ids + 1] = r.id end end
      assert.same({ "y" }, ids)
    end)

    it("a peer drops its delayed digest when another peer sent the same one first", function()
      local a = bnode("Alice-Realm", { random = function() return 1 end })
      local b = bnode("Bob-Realm", { random = function() return 3 end })
      local c = bnode("Carol-Realm")
      fill(a); fill(b); fill(c)
      a.set:Apply(obs("extra", 5)); b.set:Apply(obs("extra", 5))
      local aReqs, bReqs = countKind(a, "REQ"), countKind(b, "REQ")
      c.sync:Start()
      settle(20)
      assert.is_not_nil(c.set:Get("extra"))
      assert.equal(1, aReqs.n)
      assert.equal(0, bReqs.n)
    end)

    it("day hashes format integers with %d and other numbers with %.17g", function()
      local a = bnode("Alice-Realm")
      local U = ns.Util
      assert.equal(U.Hash("a:1:1000;"), a.sync:_dayHash({ a = { 1, 1000 } }))
      assert.equal(U.Hash("a:1:" .. string.format("%.17g", 1000.1) .. ";"), a.sync:_dayHash({ a = { 1, 1000.1 } }))
      assert.equal(U.Hash("a:1:1000;b:2:1700000000;"), a.sync:_dayHash({ b = { 2, 1700000000 }, a = { 1, 1000 } }))
    end)

    it("Start returns false when a DAYS message cannot be sent", function()
      local a = bnode("Alice-Realm")
      a.set:Apply(obs("x", 1))
      a.comm.Send = function() return false end
      assert.is_false(a.sync:Start())
    end)

    it("a large day is paged by PAGE ids, each page naming only that day", function()
      local a, b = bnode("Alice-Realm"), bnode("Bob-Realm")
      for i = 1, 120 do a.set:Apply(obs(string.format("r%03d", i), 3)) end
      a.set:Apply(obs("s1", 4))
      for i = 1, 120 do b.set:Apply(obs(string.format("r%03d", i), 3, { v = 0 })) end
      b.set:Apply(obs("s1", 4, { v = 0 }))
      local reqs = countKind(a, "REQ")
      b.sync:Start()
      wait(1)   -- Alice's delayed digest goes out
      local day3, total = 0, 0
      for _, p in ipairs(reqs.payloads) do
        local n = 0
        for _ in pairs(p.have) do n = n + 1 end
        assert.is_true(n <= 50)
        total = total + n
        if p.days[1] == "3" then day3 = day3 + 1; assert.same({ "3" }, p.days) end
      end
      assert.equal(3, day3)
      assert.equal(121, total)
    end)

    it("counter-REQs are rate-limited per day", function()
      local a = bnode("Alice-Realm")
      local b = { comm = bus:join("Bob-Realm") }   -- a bare peer that never answers
      local reqs = countKind(a, "REQ")
      local have = { x = { 2, 1000 } }
      b.comm:Send("test", "REQ", { have = have, days = { "2" } })
      b.comm:Send("test", "REQ", { have = have, days = { "2" } })
      assert.equal(1, reqs.n)
      wait(61)
      b.comm:Send("test", "REQ", { have = have, days = { "2" } })
      assert.equal(2, reqs.n)
    end)

    it("5,000 records over 400 days go out as two DAYS messages of 200 days", function()
      local a = bnode("Alice-Realm")
      local b = { comm = bus:join("Bob-Realm") }
      for i = 1, 5000 do a.set:Apply(obs(string.format("obs:%05d", i), 20000 + i % 400)) end
      local got = {}
      b.comm:On("test", "DAYS", function(p) got[#got + 1] = p end)
      local reqs = countKind(a, "REQ")
      local chunks = countChunks(a, "DAYS")
      assert.is_true(a.sync:Start())
      assert.equal(2, #got)
      assert.equal(0, reqs.n)
      assert.equal(200, size(got[1].h)); assert.equal(200, size(got[2].h))
      assert.is_nil(got[1].after); assert.equal(got[1].to, got[2].after); assert.is_nil(got[2].to)
      assert.is_true(chunks.chunks <= 40)
    end)

    it("malformed DAYS and REQ days payloads are ignored safely", function()
      local a, b = bnode("Alice-Realm"), bnode("Bob-Realm")
      a.set:Apply(obs("x", 1))
      assert.has_no.errors(function()
        b.comm:Send("test", "DAYS", "junk")
        b.comm:Send("test", "DAYS", { h = "junk" })
        b.comm:Send("test", "DAYS", { h = { [1] = 5, x = "y" } })
        b.comm:Send("test", "DAYS", { h = {}, after = 7, to = {} })
        b.comm:Send("test", "REQ", { have = {}, days = { 5, {} } })
        settle(10)
      end)
    end)

    it("a set without bucket never answers DAYS", function()
      local a = node("Alice-Realm")
      a.set:Apply(rec())
      local b = node("Bob-Realm")
      local reqs = countKind(a, "REQ")
      b.comm:Send("test", "DAYS", { h = {} })
      settle(10)
      assert.equal(0, reqs.n)
    end)
  end)
end)
