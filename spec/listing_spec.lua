describe("Exchange.Listing", function()
  local L, ns
  local function good(o)
    local d = { kind = "WTS", item = "Linen Cloth", qty = 20, mats = false, cod = false }
    for k, v in pairs(o or {}) do d[k] = v end
    return d
  end
  local function ctx(o)
    local c = { now = 1000, ownerOf = function() return "p1" end, isOfficer = function() return true end }
    for k, v in pairs(o or {}) do c[k] = v end
    return c
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Listing.lua")
    L = ns.Exchange.Listing
  end)

  it("Validate rejects bad kind, empty item, qty 0, note > 200", function()
    assert.is_true((L.Validate(good())))
    assert.is_false((L.Validate(good({ kind = "X" }))))
    assert.is_false((L.Validate(good({ item = "" }))))
    assert.is_false((L.Validate(good({ qty = 0 }))))
    assert.is_false((L.Validate(good({ note = string.rep("a", 201) }))))
    assert.is_true((L.Validate(good({ note = string.rep("a", 200) }))))
  end)

  it("Validate accepts src=\"discord\" with poster, rejects unknown src and poster > 64", function()
    assert.is_true((L.Validate(good({ src = "discord", poster = "Bob" }))))
    assert.is_false((L.Validate(good({ src = "other" }))))
    assert.is_false((L.Validate(good({ src = "discord", poster = string.rep("a", 65) }))))
  end)

  it("Validate returns false without raising on malformed payloads", function()
    local ok, err = L.Validate("nope")
    assert.is_false(ok); assert.is_string(err)
    assert.is_false((L.Validate(nil)))
    assert.is_false((L.Validate(good({ qty = 2.5 }))))
    assert.is_false((L.Validate(good({ mats = "yes" }))))
    assert.is_false((L.Validate(good({ cod = 1 }))))
    assert.is_false((L.Validate(good({ item = 5 }))))
    assert.is_false((L.Validate(good({ qty = 10000 }))))
    assert.is_true((L.Validate(good({ extra = "fwd" }))))
    local ok2 = L.CheckIncoming({ id = "a", v = 1, t = 1, by = "p", char = "c", exp = 2, d = "x" }, nil, ctx())
    assert.is_false(ok2)
  end)

  it("New sets 7-day expiry", function()
    local r = L.New(good(), "p1", "Bob-Realm", 1000, 7)
    assert.equals("p1:7", r.id)
    assert.equals(1, r.v)
    assert.equals(1000, r.t)
    assert.equals(1000 + 604800, r.exp)
    assert.equals("p1", r.by)
    assert.equals("Bob-Realm", r.char)
  end)

  it("Renew resets expiry and bumps version", function()
    local r = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local n = L.Renew(r, "Bob-Realm", 5000)
    assert.equals(2, n.v)
    assert.equals(5000 + 604800, n.exp)
    assert.equals(5000, n.t)
    assert.equals(1, r.v)
  end)

  it("Edit keeps expiry", function()
    local r = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local n = L.Edit(r, { qty = 5, note = "hi" }, "Alt-Realm", 3000)
    assert.equals(2, n.v)
    assert.equals(r.exp, n.exp)
    assert.equals(3000, n.t)
    assert.equals(5, n.d.qty)
    assert.equals("hi", n.d.note)
    assert.equals(20, r.d.qty)
    assert.equals("Alt-Realm", n.char)
    local c = L.Edit(n, { qty = false, note = false }, "Alt-Realm", 3001)
    assert.is_nil(c.d.qty); assert.is_nil(c.d.note)
  end)

  it("Remove makes tombstone, officer removal flags and re-owns", function()
    local r = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local own = L.Remove(r, "Bob-Realm", 2000, false)
    assert.is_true(own.del); assert.equals(2, own.v); assert.equals("p1", own.by)
    assert.is_nil(own.d.offRemove)
    local off = L.Remove(r, "Off-Realm", 2000, true, "p9")
    assert.is_true(off.d.offRemove); assert.equals("p9", off.by)
    assert.is_false(r.del)
    assert.has_error(function() L.Remove(r, "Off-Realm", 2000, true) end)
  end)

  it("rejects listing with exp beyond 8 days", function()
    local r = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    r.exp = r.t + 691201
    local ok, why = L.CheckIncoming(r, nil, ctx())
    assert.is_false(ok); assert.equals("exp too far", why)
    r.exp = r.t + 691200
    assert.is_true((L.CheckIncoming(r, nil, ctx())))
  end)

  it("rejects edit from different profile", function()
    local ex = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local inc = L.Edit(ex, { qty = 1 }, "Eve-Realm", 2000)
    inc.by = "p2"
    local ok, why = L.CheckIncoming(inc, ex, ctx())
    assert.is_false(ok); assert.equals("not owner", why)
    inc.by = "p1"
    assert.is_true((L.CheckIncoming(inc, ex, ctx())))
  end)

  it("accepts officer removal by officer", function()
    local ex = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local off = L.Remove(ex, "Off-Realm", 2000, true, "p9")
    local ok = L.CheckIncoming(off, ex, ctx({ isOfficer = function() return true end }))
    assert.is_true(ok)
  end)

  it("rejects officer removal by known non-officer", function()
    local ex = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local off = L.Remove(ex, "Off-Realm", 2000, true, "p9")
    local ok, why = L.CheckIncoming(off, ex, ctx({ isOfficer = function() return false end }))
    assert.is_false(ok); assert.equals("not officer", why)
  end)

  it("accepts officer removal with unknown rank as officer unverified", function()
    local ex = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local off = L.Remove(ex, "Off-Realm", 2000, true, "p9")
    local ok, why = L.CheckIncoming(off, ex, ctx({ isOfficer = function() return nil end }))
    assert.is_true(ok); assert.equals("officer unverified", why)
  end)

  it("tombstone skips payload validation", function()
    local ex = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    local t = L.Remove(ex, "Bob-Realm", 2000, false)
    t.d = {}
    assert.is_true((L.CheckIncoming(t, ex, ctx())))
    t.d = "junk"
    assert.is_true((L.CheckIncoming(t, ex, ctx())))
  end)

  it("CanEdit and CanOfficerRemove", function()
    local r = L.New(good(), "p1", "Bob-Realm", 1000, 1)
    assert.is_true(L.CanEdit(r, "p1"))
    assert.is_false(L.CanEdit(r, "p2"))
    assert.is_false(L.CanEdit(L.Remove(r, "Bob-Realm", 2, false), "p1"))
    assert.is_false(L.CanEdit(L.New(good({ src = "discord" }), "p1", "B", 1, 2), "p1"))
    assert.is_true(L.CanOfficerRemove(true))
    assert.is_false(L.CanOfficerRemove(false))
    assert.is_false(L.CanOfficerRemove(nil))
  end)
end)
