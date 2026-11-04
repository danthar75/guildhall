describe("Groups KillWatch", function()
  local pubStatus, ns, published, opts, timers, now, snap, secret, instKey, w, store, jitter, owners

  local function build(db)
    return ns.Groups.KillWatch.new({
      db = db,
      compat = {
        Safe = function(_, v) if v == secret then return nil end return v end,
        GroupSnapshot = function() return snap end,
        InstanceKey = function() return instKey end,
      },
      observations = {
        Publish = function(_, d, o) published[#published + 1] = d; opts[#opts + 1] = o or false; return pubStatus end,
        List = function(_, kind) return kind == "kill" and store or {} end,
      },
      now = function() return now end,
      after = function(s, fn) timers[#timers + 1] = { s = s, fn = fn } end,
      random = function(lo, hi) return jitter(lo, hi) end,
      playerChar = "A-R",
      profile = {
        Id = function() return "pA" end,
        OwnerOf = function(_, ch) return owners[ch] end,
      },
    })
  end

  -- Runs the due timers in order (a timer may add more).
  local function flush()
    local i = 1
    while timers[i] do
      local t = timers[i]
      if not t.ran then t.ran = true; t.fn() end
      i = i + 1
    end
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Observations.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/KillWatch.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Credit.lua")
    pubStatus = "accepted"
    published, opts, timers, now, secret, instKey, store = {}, {}, {}, 10000, {}, 409, {}
    jitter = function(lo) return lo end
    owners = { ["A-R"] = "pA", ["B-R"] = "pB", ["C-R"] = "pC", ["D-R"] = "pD", ["E-R"] = "pE" }
    snap = { members = { "A-R", "B-R" }, leader = "A-R", assists = {}, size = 2 }
    w = build()
  end)

  it("a successful final-boss ENCOUNTER_END publishes one kill with members and dur", function()
    w:OnZone()
    now = 10600
    w:OnEncounterEnd(672, "Ragnaros", 9, 40, 1)
    flush()
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
    flush()
    assert.equals(90, published[1].dur)
    w:OnEncounterEnd(663, "", 9, 40, 1)
    flush()
    assert.is_nil(published[2].dur)
    local w2 = build()
    w2:OnEncounterEnd(1084, "", 9, 40, 1)
    flush()
    assert.is_nil(published[3].dur)
  end)

  it("a wipe (success 0) publishes nothing", function()
    w:OnEncounterEnd(672, "", 9, 40, 0)
    assert.equals(0, #published)
  end)

  it("an unknown encounter publishes nothing", function()
    w:OnEncounterEnd(99999, "", 9, 40, 1)
    flush()
    w:OnBossKill(99999)
    assert.equals(0, #published); assert.equals(0, #timers)
  end)

  it("secret inputs publish nothing", function()
    w:OnEncounterEnd(secret, "", 9, 40, 1)
    flush()
    w:OnEncounterEnd(672, "", 9, 40, secret)
    w:OnBossKill(secret)
    w:OnEncounterStart(secret)
    assert.equals(0, #published); assert.equals(0, #timers)
  end)

  it("BOSS_KILL alone publishes after 5 s", function()
    w:OnBossKill(672)
    assert.equals(5, timers[1].s)
    assert.equals(0, #published)
    flush()
    assert.equals(1, #published)
  end)

  it("BOSS_KILL with an ENCOUNTER_END does not double", function()
    w:OnBossKill(672)
    now = 10002
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(1, #published)
  end)

  it("a late ENCOUNTER_END after the fallback does not double, but a kill 600 s later does", function()
    w:OnBossKill(672)
    now = 10005
    flush()
    now = 10007
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(1, #published)
    now = 10700
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(2, #published)
  end)

  it("no group snapshot publishes nothing", function()
    snap = nil
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(0, #published)
  end)

  it("a refused publish does not block a later report", function()
    pubStatus = "excluded"
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    pubStatus = "accepted"
    now = 10010
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(2, #published)
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(2, #published)
  end)

  it("leaving and re-entering measures dur from re-entry", function()
    w:OnZone()
    now = 20000
    instKey = nil; w:OnZone()
    now = 30000
    instKey = 409; w:OnZone()
    now = 30100
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(100, published[1].dur)
  end)

  it("a second clear after a final kill measures from its own start", function()
    w:OnZone()
    now = 10100
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(100, published[1].dur)
    now = 11000
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.is_nil(published[2].dur)
    now = 11700
    w:OnEncounterStart(663)
    now = 12200
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.equals(500, published[3].dur)
  end)

  it("over six hours means no dur", function()
    w:OnZone()
    now = 10000 + 21601
    w:OnEncounterEnd(672, "", 9, 40, 1)
    flush()
    assert.is_nil(published[1].dur)
    assert.equals(1, #published)
  end)

  it("a wipe then BOSS_KILL still publishes", function()
    w:OnEncounterEnd(672, "", 9, 40, 0)
    w:OnBossKill(672)
    flush()
    assert.equals(1, #published)
  end)

  describe("volume", function()
    local DAY = 86400
    -- RFC: 2732 is a non-final boss, 2733 the final one
    local seq = 0
    local function report(by, char, encounter, members, at, extra)
      seq = seq + 1
      local d = { kind = "kill", instance = "mc", encounter = encounter, members = members, at = at }
      for k, v in pairs(extra or {}) do d[k] = v end
      store[#store + 1] = { id = "r" .. seq, by = by, char = char, d = d }
    end
    local FIVE = { "A-R", "B-R", "C-R", "D-R", "E-R" }

    before_each(function()
      snap = { members = FIVE, leader = "B-R", assists = { "C-R" }, size = 5 }
    end)

    it("a non-final dungeon boss kill expires after 2 days; finals and raid bosses keep the default", function()
      instKey = 389
      w:OnZone()
      w:OnEncounterEnd(2732, "", 1, 5, 1)
      flush()
      assert.same({ exp = 10000 + 2 * DAY }, opts[1])
      assert.is_true(ns.Observations.Validate(published[1]))
      now = 10600
      w:OnEncounterEnd(2733, "", 1, 5, 1)
      flush()
      assert.is_false(opts[2])
      assert.equals(600, published[2].dur)
      instKey = 409
      w:OnEncounterEnd(663, "", 9, 40, 1)
      flush()
      assert.is_false(opts[3])
    end)

    it("a long dungeon run with non-final kills on the way still gets its duration", function()
      instKey = 389
      w:OnZone()
      for i, at in ipairs({ 13600, 17200 }) do
        now = at
        w:OnEncounterEnd(2731 + i * 2 - 1, "", 1, 5, 1) -- 2732, 2734: non-final
        flush()
      end
      now = 10000 + 21540 -- 5 h 59 min after entering
      w:OnEncounterEnd(2733, "", 1, 5, 1)
      flush()
      assert.equals(3, #published)
      assert.equals(21540, published[3].dur)
    end)

    it("waits a random 0-30 s before publishing", function()
      local asked
      jitter = function(lo, hi) asked = { lo, hi }; return 17 end
      w:OnEncounterEnd(663, "", 9, 40, 1)
      assert.same({ 0, 30 }, asked)
      assert.equals(17, timers[1].s)
      assert.equals(0, #published)
      -- the kill time is when it died, not when it is published
      now = 10017
      flush()
      assert.equals(10000, published[1].at)
      -- a second ENCOUNTER_END while waiting doesn't schedule another
      local w2 = build()
      w2:OnEncounterEnd(663, "", 9, 40, 1)
      w2:OnEncounterEnd(663, "", 9, 40, 1)
      w2:OnBossKill(663)
      flush()
      assert.equals(2, #published)
    end)

    it("an out-of-range random wait is clamped", function()
      jitter = function() return 900 end
      w:OnEncounterEnd(663, "", 9, 40, 1)
      assert.equals(30, timers[1].s)
      local w2 = build()
      jitter = function() return 0 / 0 end
      w2:OnEncounterEnd(664, "", 9, 40, 1)
      assert.equals(0, timers[2].s)
    end)

    it("skips publishing when 3 other reports already confirm every name it would add", function()
      report("pB", "B-R", 663, FIVE, 9990, { leader = "B-R", assists = { "C-R" } })
      report("pC", "C-R", 663, FIVE, 9995, { leader = "B-R", assists = { "C-R" } })
      report("pD", "D-R", 663, FIVE, 10003, { leader = "B-R", assists = { "C-R" } })
      w:OnEncounterEnd(663, "", 9, 40, 1)
      flush()
      assert.equals(0, #published)
      -- the skip counts as done: the BOSS_KILL fallback doesn't publish it either
      w:OnBossKill(663)
      flush()
      assert.equals(0, #published)
    end)

    it("publishes when a skip could cost anyone credit", function()
      local function try(setup)
        store, published, opts, timers = {}, {}, {}, {}
        setup()
        local fresh = build()
        fresh:OnEncounterEnd(663, "", 9, 40, 1)
        flush()
        return #published
      end
      local L = { leader = "B-R", assists = { "C-R" } }
      -- only 2 other reports
      assert.equals(1, try(function()
        report("pB", "B-R", 663, FIVE, 9990, L); report("pC", "C-R", 663, FIVE, 9995, L)
      end))
      -- 3 reports, but E-R appears in only one of them
      local FOUR = { "A-R", "B-R", "C-R", "D-R" }
      assert.equals(1, try(function()
        report("pB", "B-R", 663, FOUR, 9990, L); report("pC", "C-R", 663, FOUR, 9995, L)
        report("pD", "D-R", 663, FIVE, 10003, L)
      end))
      -- 3 reports, but none names the assistant this client sees
      assert.equals(1, try(function()
        report("pB", "B-R", 663, FIVE, 9990, { leader = "B-R" }); report("pC", "C-R", 663, FIVE, 9995, { leader = "B-R" })
        report("pD", "D-R", 663, FIVE, 10003, { leader = "B-R" })
      end))
      -- 3 reports, but one is this profile's own
      assert.equals(1, try(function()
        report("pB", "B-R", 663, FIVE, 9990, L); report("pC", "C-R", 663, FIVE, 9995, L)
        report("pA", "A-R", 663, FIVE, 10003, L)
      end))
      -- 3 reports, but one's char isn't linked to its sender
      assert.equals(1, try(function()
        report("pB", "B-R", 663, FIVE, 9990, L); report("pC", "C-R", 663, FIVE, 9995, L)
        report("pX", "D-R", 663, FIVE, 10003, L)
      end))
      -- 3 reports, but one doesn't list this player
      assert.equals(1, try(function()
        local others = { "B-R", "C-R", "D-R", "E-R" }
        report("pB", "B-R", 663, FIVE, 9990, L); report("pC", "C-R", 663, FIVE, 9995, L)
        report("pD", "D-R", 663, others, 10003, L)
      end))
      -- 3 reports of another encounter, or more than 600 s away
      assert.equals(1, try(function()
        report("pB", "B-R", 664, FIVE, 9990, L); report("pC", "C-R", 664, FIVE, 9995, L)
        report("pD", "D-R", 664, FIVE, 10003, L)
      end))
      assert.equals(1, try(function()
        report("pB", "B-R", 663, FIVE, 9300, L); report("pC", "C-R", 663, FIVE, 9310, L)
        report("pD", "D-R", 663, FIVE, 9320, L)
      end))
    end)

    it("without a profile service it always publishes", function()
      report("pB", "B-R", 663, FIVE, 9990); report("pC", "C-R", 663, FIVE, 9995)
      report("pD", "D-R", 663, FIVE, 10003)
      snap = { members = FIVE, size = 5, assists = {} }
      local bare = ns.Groups.KillWatch.new({
        compat = { Safe = function(_, v) return v end, GroupSnapshot = function() return snap end,
          InstanceKey = function() return 409 end },
        observations = { Publish = function(_, d) published[#published + 1] = d; return "accepted" end,
          List = function() return store end },
        now = function() return now end,
        after = function(s, fn) timers[#timers + 1] = { s = s, fn = fn } end,
      })
      bare:OnEncounterEnd(663, "", 9, 40, 1)
      flush()
      assert.equals(1, #published)
    end)
  end)

  describe("pending reports survive a logout or reload", function()
    it("a logout during the wait publishes the report at once", function()
      local db = {}
      w = build(db)
      w:OnEncounterEnd(663, "", 9, 40, 1)
      assert.equals(0, #published)
      assert.is_table(db.killPending[663])
      now = 10005
      w:Flush()
      assert.equals(1, #published)
      assert.equals(10000, published[1].at)
      assert.is_nil(db.killPending[663])
      -- the jitter timer firing later doesn't publish it again
      flush()
      assert.equals(1, #published)
    end)

    it("a reload restores the pending report and publishes it on the next start", function()
      local db = {}
      w = build(db)
      instKey = 389
      w:OnZone()
      w:OnEncounterEnd(2732, "", 1, 5, 1) -- a non-final dungeon boss: keeps its short expiry
      -- /reload: the timer is gone, the db stays
      timers = {}
      now = 10040
      local again = build(db)
      assert.equals(1, again:Restore())
      assert.equals(1, #published)
      assert.equals(2732, published[1].encounter)
      assert.equals(10000, published[1].at)
      assert.same({ exp = 10040 + 2 * 86400 }, opts[1])
      assert.is_nil(db.killPending[2732])
      -- and it is deduped afterwards
      again:OnEncounterEnd(2732, "", 1, 5, 1)
      flush()
      assert.equals(1, #published)
    end)

    it("a pending report older than 600 s is dropped on start; a covered one isn't published", function()
      local db = {}
      w = build(db)
      w:OnEncounterEnd(663, "", 9, 40, 1)
      now = 10600
      local again = build(db)
      assert.equals(0, again:Restore())
      assert.equals(0, #published)
      assert.same({}, db.killPending)
      -- covered by 3 other reports by the time of the restart
      now = 20000
      snap = { members = { "A-R", "B-R" }, leader = "A-R", assists = {}, size = 2 }
      w = build(db)
      w:OnEncounterEnd(664, "", 9, 40, 1)
      for i, by in ipairs({ "pB", "pC", "pD" }) do
        store[#store + 1] = { id = "c" .. i, by = by, char = ({ "B-R", "C-R", "D-R" })[i],
          d = { kind = "kill", instance = "mc", encounter = 664, members = { "A-R", "B-R" }, leader = "A-R",
            at = 20000 + i } }
      end
      now = 20010
      assert.equals(0, build(db):Restore())
      assert.equals(0, #published)
      assert.same({}, db.killPending)
    end)

    it("malformed saved entries are dropped", function()
      local db = { killPending = { [663] = "junk", bad = { t = 10000 }, [664] = { t = 10000, d = { kind = "kill" } } } }
      assert.equals(0, build(db):Restore())
      assert.equals(0, #published)
      assert.same({}, db.killPending)
    end)
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
    it("members and assists are rejected on kinds that do not declare them", function()
      local V = ns.Observations.Validate
      assert.is_false(V({ kind = "trade", at = 1, members = { "A", "B" } }))
      assert.is_false(V({ kind = "bank", at = 1, assists = { "A" } }))
      assert.is_false(V({ kind = "signup", at = 1, members = { "A" } }))
    end)
    it("registers the later kinds without validators", function()
      for _, k in ipairs({ "prepcheck", "prepared", "flexask", "flexdone", "flexok", "signup" }) do
        assert.is_true(ns.Observations.KINDS[k])
        assert.is_true(ns.Observations.Validate({ kind = k, at = 1 }))
      end
    end)
  end)
end)
