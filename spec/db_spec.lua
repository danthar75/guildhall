describe("DB", function()
  local ns
  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Core/DB.lua")
    loadAddonFile(ns, "Guildhearth/Core/Theme.lua")
  end)

  it("DB.Init fills defaults without clobbering existing", function()
    local sv = ns.DB.Init({ personal = { profile = { id = "abc", chars = { X = { included = true } } } } })
    assert.equal(1, sv.schema)
    assert.equal("abc", sv.personal.profile.id)
    assert.is_true(sv.personal.profile.chars.X.included)
    assert.same({}, sv.personal.profile.excluded)
    assert.is_false(sv.personal.profile.consented)
    assert.same({}, sv.personal.templates)
    assert.same({}, sv.guilds)
    assert.is_table(ns.DB.Init(nil).personal)
  end)

  it("Guild scoping isolates guilds", function()
    local sv = ns.DB.Init()
    ns.DB.Module(sv, "A", "exchange").x = 1
    assert.is_nil(ns.DB.Module(sv, "B", "exchange").x)
    local g = ns.DB.Guild(sv, "A")
    assert.same({}, g.sets); assert.same({}, g.log); assert.same({}, g.cache)
    assert.equal(1, g.modules.exchange.x)
  end)

  it("Theme returns copies and merges overrides", function()
    assert.equal("Guildhearth", ns.Theme.Get("title"))
    ns.Theme.Get("accent")[1] = 0
    assert.equal(1, ns.Theme.Get("accent")[1])
    ns.Theme.Set({ title = "Emergence" })
    assert.equal("Emergence", ns.Theme.Get("title"))
    assert.is_nil(ns.Theme.Get("logo"))
  end)
end)
