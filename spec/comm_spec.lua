describe("Comm", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, compat, env, sent, ignored, comm, result, restricted

  local function mk(opts)
    opts = opts or {}
    opts.compat = compat
    opts.now = clock.now
    opts.after = timers.after
    opts.playerName = opts.playerName or "Me-Realm"
    opts.onIgnored = function(s, r) ignored[#ignored + 1] = { s, r } end
    return ns.Comm.new(opts)
  end

  before_each(function()
    clock = fakes.clock(100)
    timers = fakes.timers(clock)
    sent, ignored, result, restricted = {}, {}, 0, 0
    compat, env = fakes.compat({
      C_ChatInfo = { SendAddonMessage = function(p, m, ch)
        if result ~= 0 then return result end
        sent[#sent + 1] = { p, m, ch }
        return 0
      end },
      Enum = { AddOnRestrictionType = { Chat = 1 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function() return restricted end },
    })
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Serialize.lua")
    loadAddonFile(ns, "Guildhall/Core/Comm.lua")
    comm = mk({ burst = 100 })
  end)

  local function deliver(line, sender)
    comm:Receive("Guildhall", line, "GUILD", sender or "Other-Realm")
  end

  it("remembers the last few distinct raw senders for diagnostics", function()
    for _, s in ipairs({ "A-Realm", "A-Realm", "B C-Realm", "D", "E", "F", "G" }) do deliver("junk", s) end
    assert.same({ "B C-Realm", "D", "E", "F", "G" }, comm.recentSenders)
  end)

  local function big()
    local t = {}
    for i = 1, 400 do t[i] = "item" .. i end
    return t
  end

  it("small message is one line <= 255 bytes", function()
    comm:Send("ex", "post", { a = 1 })
    assert.equals(1, #sent)
    assert.is_true(#sent[1][2] <= 255)
    assert.equals("Guildhall", sent[1][1])
    assert.equals("GUILD", sent[1][3])
  end)

  it("large payload splits and reassembles in order", function()
    local got
    comm:On("ex", "post", function(p, s) got = { p = p, s = s } end)
    local payload = big()
    comm:Send("ex", "post", payload)
    assert.is_true(#sent > 1)
    for _, l in ipairs(sent) do assert.is_true(#l[2] <= 255) end
    for _, l in ipairs(sent) do deliver(l[2]) end
    assert.same(payload, got.p)
    assert.equals("Other-Realm", got.s)
  end)

  it("reassembles out-of-order chunks", function()
    local got
    comm:On("ex", "post", function(p) got = p end)
    local payload = big()
    comm:Send("ex", "post", payload)
    for i = #sent, 1, -1 do deliver(sent[i][2]) end
    assert.same(payload, got)
  end)

  it("drops incomplete chunk sets after 30s", function()
    local called = 0
    comm:On("ex", "post", function() called = called + 1 end)
    comm:Send("ex", "post", big())
    for i = 1, #sent - 1 do deliver(sent[i][2]) end
    clock.advance(31)
    deliver(sent[#sent][2])
    assert.equals(0, called)
  end)

  it("ignores unknown module/kind", function()
    comm:Send("zz", "nope", { 1 })
    assert.has_no.errors(function() deliver(sent[1][2]) end)
    assert.same({ "Other-Realm", "unknown zz/nope" }, ignored[1])
  end)

  it("ignores own messages and other prefixes", function()
    local called = 0
    comm:On("ex", "post", function() called = called + 1 end)
    comm:Send("ex", "post", { 1 })
    deliver(sent[1][2], "Me-Realm")
    comm:Receive("Other", sent[1][2], "GUILD", "Other-Realm")
    comm:Receive("Guildhall", sent[1][2], "PARTY", "Other-Realm")
    assert.equals(0, called)
    deliver(sent[1][2])
    assert.equals(1, called)
  end)

  it("burst then throttles at refill rate", function()
    comm = mk()
    for i = 1, 12 do comm:Send("ex", "post", { i }) end
    assert.equals(10, #sent)
    assert.equals(2, comm:Pending())
    clock.advance(1); timers.run(clock)
    assert.equals(11, #sent)
    clock.advance(1); timers.run(clock)
    assert.equals(12, #sent)
    assert.equals(0, comm:Pending())
  end)

  it("lockdown keeps queue and retries until lifted", function()
    restricted = 2
    comm:Send("ex", "post", { 1 })
    assert.equals(0, #sent)
    assert.equals(1, comm:Pending())
    clock.advance(5); timers.run(clock)
    assert.equals(0, #sent)
    restricted = 0
    clock.advance(5); timers.run(clock)
    assert.equals(1, #sent)
    assert.equals(0, comm:Pending())
  end)

  it("throttle requeues at front and retries after 2s", function()
    result = 3
    comm:Send("ex", "post", { 1 })
    assert.equals(1, comm:Pending())
    result = 0
    clock.advance(1); timers.run(clock)
    assert.equals(0, #sent)
    clock.advance(1); timers.run(clock)
    assert.equals(1, #sent)
  end)

  it("send error drops the message", function()
    result = 99
    comm:Send("ex", "post", { 1 })
    assert.equals(0, comm:Pending())
    assert.same({ nil, "send error" }, ignored[1])
  end)

  it("ignores nil/secret/garbage arguments", function()
    env.issecretvalue = function(v) return v == "SECRET" end
    assert.has_no.errors(function()
      comm:Receive("Guildhall", "1:1/1:x", "GUILD", nil)
      comm:Receive("Guildhall", "1:1/1:x", "GUILD", "SECRET")
      comm:Receive("Guildhall", 42, "GUILD", "A-B")
      comm:Receive(nil, nil, nil, nil)
    end)
    assert.equals(0, #ignored)
  end)

  it("reports bad chunk headers and bad payloads", function()
    deliver("garbage")
    deliver("1:3/2:x")
    deliver("1:1/0:x")
    deliver("1:1/9999:x")
    assert.equals(4, #ignored)
    for _, i in ipairs(ignored) do assert.equals("bad chunk", i[2]) end
    ignored = {}
    deliver("2:1/1:not-serialized")
    assert.equals("bad payload", ignored[1][2])
  end)

  it("catches handler errors", function()
    comm:On("ex", "post", function() error("boom") end)
    comm:Send("ex", "post", { 1 })
    assert.has_no.errors(function() deliver(sent[1][2]) end)
    assert.truthy(ignored[1][2]:find("handler error: ", 1, true))
  end)

  it("dispatches newer protocol versions", function()
    local got
    comm:On("ex", "post", function(p) got = p end)
    local line = "1:1/1:" .. ns.Serialize.Encode({ pv = 2, m = "ex", k = "post", p = { 7 }, extra = 1 })
    deliver(line)
    assert.same({ 7 }, got)
  end)
  it("Halt drops the queue and makes Send, Pump and Receive no-ops (I3)", function()
    restricted = 1 -- lockdown: lines stay queued
    comm:Send("m", "k", { x = 1 })
    assert.equal(1, comm:Pending())
    local got = 0
    comm:On("m", "k", function() got = got + 1 end)
    comm:Halt()
    assert.equal(0, comm:Pending())
    restricted = 0
    assert.is_false(comm:Send("m", "k", { x = 2 }))
    comm:Pump()
    clock.advance(10); timers.run(clock)
    assert.equal(0, #sent)
    local other = mk({ playerName = "Other-Realm" })
    local lines = {}
    env.C_ChatInfo.SendAddonMessage = function(p, m) lines[#lines + 1] = m; return 0 end
    other:Send("m", "k", { x = 3 })
    deliver(lines[1])
    assert.equal(0, got)
  end)
end)
