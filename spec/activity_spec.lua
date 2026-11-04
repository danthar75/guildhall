describe("Activity", function()
  local ns
  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Activity.lua")
  end)

  local function def(id, order)
    return { id = id, label = id, unit = "count", verify = "paired", weight = 1, order = order }
  end

  it("Register rejects duplicates", function()
    ns.Activity.Register(def("a", 1))
    assert.has_error(function() ns.Activity.Register(def("a", 2)) end)
    assert.equal(1, ns.Activity.Get("a").order)
  end)

  it("Types sorts by order then id", function()
    ns.Activity.Register(def("c", 2))
    ns.Activity.Register(def("b", 2))
    ns.Activity.Register(def("z", 1))
    local ids = {}
    for _, d in ipairs(ns.Activity.Types()) do ids[#ids + 1] = d.id end
    assert.same({ "z", "b", "c" }, ids)
    assert.is_nil(ns.Activity.Get("nope"))
  end)

  it("Deriver round-trips", function()
    local fn = function() return {} end
    ns.Activity.RegisterDeriver("trade", fn)
    assert.equal(fn, ns.Activity.Deriver("trade"))
    assert.is_nil(ns.Activity.Deriver("other"))
  end)
end)
