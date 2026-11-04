describe("Instances", function()
  local Instances

  before_each(function()
    local ns = {}
    loadAddonFile(ns, "Guildhearth/Modules/Groups/Instances.lua")
    Instances = ns.Instances
  end)

  it("every entry has final in bosses and a unique key", function()
    local keys, encounters = {}, {}
    assert.is_true(#Instances.LIST > 0)
    for _, e in ipairs(Instances.LIST) do
      assert.is_string(e.key)
      assert.is_nil(keys[e.key], "duplicate key " .. e.key)
      keys[e.key] = true
      assert.is_true(e.kind == "dungeon" or e.kind == "raid", e.key)
      assert.is_number(e.size)
      assert.is_number(e.instanceId)
      local hasFinal = false
      for _, id in ipairs(e.bosses) do
        assert.is_number(id)
        assert.is_nil(encounters[id], "encounter in two entries: " .. id)
        encounters[id] = e.key
        if id == e.final then hasFinal = true end
      end
      assert.is_true(hasFinal, "final not in bosses: " .. e.key)
      if e.alias then
        local hasAliasFinal = false
        for _, id in ipairs(e.alias) do
          assert.is_number(id)
          assert.is_nil(encounters[id], "alias collides: " .. id)
          encounters[id] = e.key
          if id == e.aliasFinal then hasAliasFinal = true end
        end
        assert.is_true(hasAliasFinal, "aliasFinal not in alias: " .. e.key)
      else
        assert.is_nil(e.aliasFinal, e.key)
      end
      assert.equal(e, Instances.Get(e.key))
    end
  end)

  it("names and short names are plain ASCII", function()
    for _, e in ipairs(Instances.LIST) do
      for _, s in ipairs({ e.name, e.short }) do
        assert.is_string(s)
        assert.is_nil(s:find("[\128-\255]"), e.key)
      end
    end
  end)

  it("covers every wing and raid the plan names", function()
    for _, k in ipairs({ "dm_east", "dm_west", "dm_north", "strat_live", "strat_ud", "sm_gy", "sm_lib",
        "sm_arm", "sm_cath", "lbrs", "ubrs", "mc", "ony", "bwl", "zg", "aq20", "aq40", "naxx" }) do
      assert.is_table(Instances.Get(k), k)
    end
    local ud = Instances.Get("strat_ud")
    assert.equal("Stratholme (Undead)", ud.name)
    assert.equal("Strat UD", ud.short)
    assert.equal("dungeon", ud.kind)
    assert.is_nil(Instances.Get("nope"))
  end)

  it("ByEncounter(672) is MC, not final for dungeons; a dungeon final returns isFinal", function()
    local e, isFinal = Instances.ByEncounter(672)
    assert.equal("mc", e.key)
    assert.equal("raid", e.kind)
    assert.is_true(isFinal)
    e, isFinal = Instances.ByEncounter(663)
    assert.equal("mc", e.key)
    assert.is_false(isFinal)
    e, isFinal = Instances.ByEncounter(1084)
    assert.equal("ony", e.key)
    assert.is_true(isFinal)
    local ud = Instances.Get("strat_ud")
    e, isFinal = Instances.ByEncounter(ud.final)
    assert.equal(ud, e)
    assert.is_true(isFinal)
    e, isFinal = Instances.ByEncounter(ud.bosses[1] == ud.final and ud.bosses[2] or ud.bosses[1])
    assert.equal(ud, e)
    assert.is_false(isFinal)
    e, isFinal = Instances.ByEncounter(2910) -- BFD's alias set
    assert.equal("bfd", e.key)
    assert.is_true(isFinal)
    e, isFinal = Instances.ByEncounter(2916)
    assert.equal("bfd", e.key)
    assert.is_false(isFinal)
    e, isFinal = Instances.ByEncounter(2767)
    assert.equal("bfd", e.key)
    assert.is_true(isFinal)
    assert.is_nil(Instances.ByEncounter(999999))
    assert.is_nil(Instances.ByEncounter(nil))
  end)

  it("ForPicker sorts dungeons by name and raids by tier", function()
    local d = Instances.ForPicker("dungeon")
    assert.is_true(#d > 20)
    for i = 2, #d do
      assert.equal("dungeon", d[i].kind)
      assert.is_true(d[i - 1].name < d[i].name)
    end
    local r = Instances.ForPicker("raid")
    local order = {}
    for i, e in ipairs(r) do order[i] = e.key end
    assert.same({ "mc", "ony", "bwl", "zg", "aq20", "aq40", "naxx" }, order)
    -- the picker array is a copy: sorting it never reorders LIST
    r[1] = nil
    assert.equal("mc", Instances.ForPicker("raid")[1].key)
  end)
end)
