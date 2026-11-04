describe("Groups KillWatch", function()
  local ns, published, timers, now, snap, secret, instKey, w

  local function build()
    return ns.Groups.KillWatch.new({
      compat = {
        Safe = function(_, v) if v == secret then return nil end return v end,
        GroupSnapshot = function() return snap end,
        InstanceKey = function() return instKey end,
      },
      observations = { Publish = function(_, d) published[#published + 1] = d; return "ok" end },
      now = function() return now end,
      after = function(s, fn) timers[#timers + 1] = { s = s, fn = fn } end,
    })
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Observations.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/KillWatch.lua")
    published, timers, now, secret, instKey = {}, {}, 10000, {}, 409
    snap = { members = { "A-R", "B-R" }, leader = "A-R", assists = {}, size = 2 }
    w = build()
  end)

  it("a successful final-boss ENCOUNTER_END publishes one kill with members and dur", function()
    w:OnZone()
    now = 10600
    w:OnEncounterEnd(672, "Ragnaros", 9, 40, 1)
    assert.equals(1, #published)
    local d = published[1]
    assert.equals("kill", d.kind); assert.equals("mc", d.instance); assert.equals(672, d.encounter)
    assert.same({ "A-R", "B-R" }, d.members); assert.equals("A-R", d.leader)
    assert.equals(600, d.dur); assert.equals(10600, d.at)
    assert.is_true(ns.Observations.Validate(d))
  end)

  it("duration comes from ENCOUNTER_START and is absent for non-final or unseen", function()
    w:OnEncounterStart(672)
    now = 10090.7
    w:OnEncounterEnd(672, "", 9, 40, 1)
    assert.equals(90, published[1].dur)
    w:OnEncounterEnd(663, "", 9, 40, 1)
    assert.is_nil(published[2].dur)
    local w2 = build()
    w2:OnEncounterEnd(1084, "", 9, 40, 1)
    assert.is_nil(published[3].dur)
  end)

  it("a wipe (success 0) publishes nothing", function()
    w:OnEncounterEnd(672, "", 9, 40, 0)
    assert.equals(0, #published)
  end)

  it("an unknown encounter publishes nothing", function()
    w:OnEncounterEnd(99999, "", 9, 40, 1)
    w:OnBossKill(99999)
    assert.equals(0, #published); assert.equals(0, #timers)
  end)

  it("secret inputs publish nothing", function()
    w:OnEncounterEnd(secret, "", 9, 40, 1)
    w:OnEncounterEnd(672, "", 9, 40, secret)
    w:OnBossKill(secret)
    w:OnEncounterStart(secret)
    assert.equals(0, #published); assert.equals(0, #timers)
  end)

  it("BOSS_KILL alone publishes after 5 s", function()
    w:OnBossKill(672)
    assert.equals(5, timers[1].s)
    assert.equals(0, #published)
    timers[1].fn()
    assert.equals(1, #published)
  end)

  it("BOSS_KILL with an ENCOUNTER_END does not double", function()
    w:OnBossKill(672)
    now = 10002
    w:OnEncounterEnd(672, "", 9, 40, 1)
    timers[1].fn()
    assert.equals(1, #published)
  end)

  it("a late ENCOUNTER_END after the fallback does not double, but a kill 600 s later does", function()
    w:OnBossKill(672)
    now = 10005
    timers[1].fn()
    now = 10007
    w:OnEncounterEnd(672, "", 9, 40, 1)
    assert.equals(1, #published)
    now = 10700
    w:OnEncounterEnd(672, "", 9, 40, 1)
    assert.equals(2, #published)
  end)

  it("no group snapshot publishes nothing", function()
    snap = nil
    w:OnEncounterEnd(672, "", 9, 40, 1)
    assert.equals(0, #published)
  end)

  describe("validation", function()
    local function kill(over)
      local d = { kind = "kill", instance = "mc", encounter = 663, members = { "A-R", "B-R" }, at = 100 }
      for k, v in pairs(over or {}) do d[k] = v end
      return d
    end
    local function many(n, len)
      local t = {}
      for i = 1, n do t[i] = string.rep("x", len or 5) end
      return t
    end

    it("accepts a good kill", function() assert.is_true(ns.Observations.Validate(kill())) end)
    it("members over 40 or a name over 64 chars is invalid", function()
      assert.is_true(ns.Observations.Validate(kill({ members = many(40) })))
      assert.is_false(ns.Observations.Validate(kill({ members = many(41) })))
      assert.is_false(ns.Observations.Validate(kill({ members = many(2, 65) })))
      assert.is_false(ns.Observations.Validate(kill({ assists = many(41) })))
      assert.is_false(ns.Observations.Validate(kill({ members = { "A", "" } })))
      assert.is_false(ns.Observations.Validate(kill({ members = { "A", 5 } })))
    end)
    it("rejects bad shapes", function()
      local V = ns.Observations.Validate
      assert.is_false(V(kill({ members = { "A" } })))
      assert.is_false(V(kill({ members = { [1] = "A", [3] = "B" } })))
      assert.is_false(V(kill({ instance = "nope" })))
      assert.is_false(V(kill({ instance = "bwl" })))
      assert.is_false(V(kill({ encounter = 663.5 })))
      assert.is_false(V(kill({ extra = 1 })))
      assert.is_false(V(kill({ leader = string.rep("x", 65) })))
    end)
    it("dur only on a final, in range", function()
      local V = ns.Observations.Validate
      assert.is_false(V(kill({ dur = 5 })))
      assert.is_true(V(kill({ encounter = 672, dur = 5 })))
      assert.is_false(V(kill({ encounter = 672, dur = 0 })))
      assert.is_false(V(kill({ encounter = 672, dur = 86401 })))
      assert.is_true(V(kill({ instance = "bfd", encounter = 2910, dur = 7 })))
    end)
    it("registers the later kinds without validators", function()
      for _, k in ipairs({ "prepcheck", "prepared", "flexask", "flexdone", "flexok", "signup" }) do
        assert.is_true(ns.Observations.KINDS[k])
        assert.is_true(ns.Observations.Validate({ kind = k, at = 1 }))
      end
    end)
  end)
end)
