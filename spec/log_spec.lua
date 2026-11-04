describe("Log", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, store, log
  local DAY = 86400

  local function fmt(t) return os.date("!%Y-%m-%d %H:%M:%S", t) end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Log.lua")
    clock = fakes.clock(1700000000)
    store = {}
    log = ns.Log.new(store, clock.now, fmt)
  end)

  it("Add stamps time", function()
    log:Add({ action = "set", result = "accepted" })
    assert.equal(1700000000, store[1].t)
    log:Add({ action = "set", result = "accepted", t = 1699999000 })
    assert.equal(1699999000, store[2].t)
  end)

  it("prunes by age", function()
    log:Add({ action = "old", t = clock.now() - 31 * DAY })
    log:Add({ action = "new", t = clock.now() - DAY })
    log:Add({ action = "old2", t = clock.now() - 40 * DAY })
    assert.equal(1, #store)
    assert.equal("new", store[1].action)
  end)

  it("prunes beyond 5000 oldest first", function()
    for i = 1, 5003 do log:Add({ action = "a" .. i, t = clock.now() - 5100 + i }) end
    assert.equal(5000, #store)
    assert.equal("a4", store[1].action)
    assert.equal("a5003", store[5000].action)
  end)

  it("mutates the store in place", function()
    for i = 1, 5002 do store[i] = { t = clock.now(), action = "x" .. i } end
    log:Prune()
    assert.equal(5000, #store)
    assert.equal("x3", store[1].action)
  end)

  it("Query filters by char matching author or relayer", function()
    log:Add({ id = "i1", author = "P1", authorChar = "Alice", relayer = "Bob", action = "a", result = "accepted" })
    log:Add({ id = "i2", author = "P2", authorChar = "Carol", relayer = "Alice", action = "b", result = "ignored" })
    log:Add({ id = "i3", author = "P1", authorChar = "Dave", action = "c", result = "accepted" })
    assert.equal(3, #log:Query())
    assert.equal(3, #log:Query({}))
    assert.equal("i3", log:Query()[1].id)
    local r = log:Query({ char = "Alice" })
    assert.equal(2, #r)
    assert.equal("i2", r[1].id)
    assert.equal(1, #log:Query({ char = "Bob" }))
    assert.equal(2, #log:Query({ author = "P1" }))
    assert.equal(1, #log:Query({ author = "P1", char = "Alice" }))
    assert.equal(1, #log:Query({ id = "i2" }))
    assert.equal(0, #log:Query({ id = "i2", author = "P1" }))
  end)

  it("Export includes relayer and before/after", function()
    log:Add({ action = "edit", result = "accepted", id = "x1", v = 3, author = "P1", authorChar = "Alice",
      relayer = "Bob", reason = "ok", before = { name = "Old", n = 1 }, after = { name = "New", n = 2 } })
    local out = log:Export(log:Query())
    assert.equal(fmt(1700000000) .. " | edit | accepted | x1 v3 | P1/Alice via Bob | ok\n" ..
      "  before: n=1 name=Old\n  after: n=2 name=New", out)
  end)

  it("Export omits absent optionals and does not raise on odd types", function()
    log:Add({ action = "x", result = "ignored" })
    local out = log:Export(log:Query())
    assert.is_nil(out:find("nil"))
    assert.has_no.errors(function()
      log:Export({ { t = 5, action = 7, result = true, reason = 42, id = {}, v = "z", author = 1, authorChar = false,
        relayer = 3, before = { a = {}, [1] = "p", f = print }, after = "junk" } })
    end)
    assert.equal("", log:Export({}))
  end)
end)
