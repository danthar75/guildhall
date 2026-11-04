describe("ReplicatedSet", function()
  local fakes = require("spec.helpers.fakes")
  local RS, clock, store, changes, set

  local function rec(o)
    local r = { id = "a", v = 1, t = 1000, by = "p1", char = "Bob-Realm", exp = 5000, del = false, d = { x = 1 } }
    for k, v in pairs(o or {}) do r[k] = v end
    return r
  end

  local function fresh()
    local s = RS.new("test", {}, { now = clock.now })
    return s
  end

  before_each(function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/ReplicatedSet.lua")
    RS = ns.ReplicatedSet
    clock = fakes.clock(1000)
    store, changes = {}, {}
    set = RS.new("test", store, {
      now = clock.now,
      onChange = function(r, old) changes[#changes + 1] = { r = r, old = old } end,
    })
  end)

  it("Apply accepts new record and fires onChange", function()
    local st, old = set:Apply(rec())
    assert.equal("accepted", st)
    assert.is_nil(old)
    assert.equal(1, #changes)
    assert.equal("a", changes[1].r.id)
    assert.is_nil(changes[1].old)
    assert.equal(1, set:Get("a").v)
  end)

  it("higher version wins", function()
    set:Apply(rec())
    local st, old = set:Apply(rec({ v = 2, d = { x = 2 } }))
    assert.equal("accepted", st)
    assert.equal(1, old.v)
    assert.equal(2, set:Get("a").v)
    assert.equal(1, changes[2].old.v)
  end)

  it("lower version is stale", function()
    set:Apply(rec({ v = 3 }))
    assert.equal("stale", (set:Apply(rec({ v = 2 }))))
    assert.equal("stale", (set:Apply(rec({ v = 3 }))))
    assert.equal(1, #changes)
  end)

  it("tie on version breaks by t then char", function()
    local a, b = rec({ t = 1000 }), rec({ t = 1001 })
    local s1, s2 = fresh(), fresh()
    s1:Apply(a); s1:Apply(b)
    s2:Apply(b); s2:Apply(a)
    assert.equal(1001, s1:Get("a").t)
    assert.equal(1001, s2:Get("a").t)

    local c, d = rec({ char = "Alice-Realm" }), rec({ char = "Zed-Realm" })
    s1, s2 = fresh(), fresh()
    s1:Apply(c); s1:Apply(d)
    s2:Apply(d); s2:Apply(c)
    assert.equal("Zed-Realm", s1:Get("a").char)
    assert.equal("Zed-Realm", s2:Get("a").char)
  end)

  it("tombstone beats live record at same v and t", function()
    local live, dead = rec(), rec({ del = true })
    local s1, s2 = fresh(), fresh()
    s1:Apply(live); s1:Apply(dead)
    s2:Apply(dead); s2:Apply(live)
    assert.is_true(s1:Get("a").del)
    assert.is_true(s2:Get("a").del)
  end)

  it("Apply rejects expired records", function()
    assert.equal("expired", (set:Apply(rec({ exp = 1000 }))))
    assert.is_nil(set:Get("a"))
  end)

  it("Apply rejects future-dated records", function()
    assert.equal("future", (set:Apply(rec({ t = 1000 + 86401 }))))
    assert.equal("accepted", (set:Apply(rec({ t = 1000 + 86400 }))))
  end)

  it("Apply rejects invalid records", function()
    assert.equal("invalid", (set:Apply(rec({ id = false }))))
    assert.equal("invalid", (set:Apply(rec({ v = "x" }))))
    assert.equal("invalid", (set:Apply(rec({ t = false }))))
    assert.equal("invalid", (set:Apply(rec({ exp = false }))))
    local s = RS.new("t", {}, { now = clock.now, validate = function() return false, "bad" end })
    assert.equal("invalid", (s:Apply(rec())))
  end)

  it("Purge drops expired records and tombstones", function()
    set:Apply(rec({ id = "live", exp = 5000 }))
    set:Apply(rec({ id = "old", exp = 2000 }))
    set:Apply(rec({ id = "tomb", exp = 2000, del = true }))
    set:Apply(rec({ id = "tomb2", exp = 5000, del = true }))
    clock.advance(1500)
    assert.equal(2, set:Purge())
    assert.is_not_nil(set:Get("live"))
    assert.is_nil(set:Get("old"))
    assert.is_nil(set:Get("tomb"))
    assert.is_not_nil(set:Get("tomb2"))
  end)

  it("Missing returns records peer lacks or has older", function()
    set:Apply(rec({ id = "a", v = 2 }))
    set:Apply(rec({ id = "b", v = 1 }))
    set:Apply(rec({ id = "c", v = 1 }))
    set:Apply(rec({ id = "d", v = 1, del = true }))
    local m = set:Missing({ a = { 1, 1000 }, b = { 1, 1000 }, c = { 5, 1000 } })
    local ids = {}
    for _, r in ipairs(m) do ids[r.id] = true end
    assert.is_true(ids.a)
    assert.is_nil(ids.b)
    assert.is_nil(ids.c)
    assert.is_true(ids.d)
    assert.equal(2, #m)
    assert.same({ a = { 2, 1000 }, b = { 1, 1000 }, c = { 1, 1000 }, d = { 1, 1000 } }, set:Digest())
  end)

  it("List sorts by t descending and hides tombstones", function()
    set:Apply(rec({ id = "a", t = 900 }))
    set:Apply(rec({ id = "b", t = 950 }))
    set:Apply(rec({ id = "c", t = 990, del = true }))
    local l = set:List()
    assert.equal(2, #l)
    assert.equal("b", l[1].id)
    assert.equal(3, #set:List(true))
  end)

  it("NextVersion increments stored version", function()
    assert.equal(1, set:NextVersion("a"))
    set:Apply(rec({ v = 4 }))
    assert.equal(5, set:NextVersion("a"))
  end)

  it("store table is mutated in place", function()
    set:Apply(rec())
    assert.is_not_nil(store.a)
    assert.equal(1, store.a.v)
    local r = rec({ v = 2 })
    set:Apply(r)
    r.v = 99
    assert.equal(2, store.a.v)
  end)

  it("Apply rejects malformed peer data without raising", function()
    set:Apply(rec())
    assert.equal("invalid", (set:Apply(rec({ char = 5 }))))
    assert.equal("invalid", (set:Apply(rec({ char = {} }))))
    assert.equal("invalid", (set:Apply(rec({ char = true }))))
    assert.equal("invalid", (set:Apply("junk")))
    assert.equal("invalid", (set:Apply(nil)))
    assert.equal("invalid", (set:Apply(rec({ del = "yes" }))))
  end)

  it("Apply rejects NaN and infinite numbers", function()
    for _, f in ipairs({ "v", "t", "exp" }) do
      for _, bad in ipairs({ 0/0, math.huge, -math.huge }) do
        assert.equal("invalid", (set:Apply(rec({ [f] = bad }))))
      end
    end
  end)

  it("Missing treats non-table digest as empty", function()
    set:Apply(rec())
    assert.equal(1, #set:Missing("x"))
    assert.equal(1, #set:Missing(nil))
  end)

  it("Missing treats non-number digest entries as absent", function()
    set:Apply(rec())
    assert.equal(1, #set:Missing({ a = "5" }))
    assert.equal(1, #set:Missing({ a = { 1 } }))
    assert.equal(1, #set:Missing({ a = { 1, 0/0 } }))
    assert.equal(1, #set:Missing({ a = {} }))
  end)

  it("Missing compares t when versions are equal", function()
    set:Apply(rec({ t = 1000 }))
    assert.equal(1, #set:Missing({ a = { 1, 900 } }))
    assert.equal(0, #set:Missing({ a = { 1, 1000 } }))
    assert.equal(0, #set:Missing({ a = { 1, 1100 } }))
  end)
end)
