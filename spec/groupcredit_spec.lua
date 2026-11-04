describe("Groups Credit", function()
  local ns, Credit, ctx, guild, chars, tz, seq, unknownRoster
  local DAY, HOUR = 86400, 3600
  -- 20000 days after the epoch: a Friday, 00:00 UTC. The fallback weekly reset is Tuesday 15:00 UTC.
  local T0 = 20000 * DAY
  local RFC_FINAL, MC = 2733, { 663, 664, 665, 666, 667, 668, 669, 670, 671, 672 }
  local FIVE = { "A-R", "B-R", "C-R", "D-R", "E-R" }

  local function kill(by, instance, encounter, members, at, extra)
    seq = seq + 1
    local d = { kind = "kill", instance = instance, encounter = encounter, members = members, at = at }
    for k, v in pairs(extra or {}) do d[k] = v end
    return { id = string.format("o%04d", seq), by = by, char = (chars[by] or {})[1], d = d }
  end

  -- Two profiles report the same kill 30 s apart.
  local function pair(list, instance, encounter, members, at, extra1, extra2)
    list[#list + 1] = kill("p1", instance, encounter, members, at, extra1)
    list[#list + 1] = kill("p2", instance, encounter, members, at + 30, extra2)
    return list
  end

  local function derive(list) return ns.Activity.Deriver("kill")(list, ctx) end

  -- Sorted chars of the contributions of one type and counted state.
  local function charsOf(out, typ, counted)
    local r = {}
    for _, c in ipairs(out) do
      if c.type == typ and c.counted == (counted ~= false) then r[#r + 1] = c.char end
    end
    table.sort(r)
    return r
  end

  local function count(out, typ, char)
    local n = 0
    for _, c in ipairs(out) do
      if c.type == typ and c.counted and c.char == char then n = n + c.value end
    end
    return n
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Credit.lua")
    Credit = ns.Groups.Credit
    seq, tz, unknownRoster = 0, 0, false
    guild = {}
    for _, n in ipairs({ "A-R", "B-R", "C-R", "D-R", "E-R", "F-R", "Helper-R" }) do guild[n] = true end
    chars = { p1 = { "A-R" }, p2 = { "B-R" }, p3 = { "C-R" } }
    ctx = {
      roster = { IsMember = function(_, n)
        if unknownRoster then return nil end
        return guild[n] == true
      end },
      profile = {
        CharsOf = function(_, p) return chars[p] or {} end,
        OwnerOf = function(_, ch)
          for p, list in pairs(chars) do for _, c in ipairs(list) do if c == ch then return p end end end
        end,
      },
      config = { Tz = function() return tz end },
      now = function() return T0 + 30 * DAY end,
    }
  end)

  it("registers the six group activity types", function()
    local want = {
      { "groups.dungeon", "Dungeons cleared", "paired", 5, 80 },
      { "groups.raidboss", "Raid bosses killed", "paired", 3, 90 },
      { "groups.raidclear", "Full raid clears", "paired", 5, 100 },
      { "groups.prepared", "Raids prepared", "confirmed", 2, 110 },
      { "groups.flex", "Spec switches when asked", "confirmed", 1, 120 },
      { "groups.signedup", "Signed up and showed up", "paired", 1, 130 },
    }
    for _, w in ipairs(want) do
      local def = ns.Activity.Get(w[1])
      assert.is_not_nil(def, w[1])
      assert.same({ w[2], "count", w[3], w[4], w[5] }, { def.label, def.unit, def.verify, def.weight, def.order })
    end
  end)

  it("two profiles' reports pair; one report is not verified", function()
    local list = pair({}, "rfc", RFC_FINAL, FIVE, T0 + 10 * HOUR)
    assert.equal(1, #Credit.Verified(list))
    local v = Credit.Verified(list)[1]
    assert.same({ "p1", "p2" }, v.reporters)
    assert.equal(T0 + 10 * HOUR, v.at)
    assert.same(FIVE, charsOf(derive(list), "groups.dungeon"))

    -- one report alone: an uncounted row for the reporter's own char only
    local single = { kill("p1", "rfc", RFC_FINAL, FIVE, T0 + 20 * HOUR) }
    assert.equal(0, #Credit.Verified(single))
    local out = derive(single)
    assert.equal(1, #out)
    assert.equal("A-R", out[1].char)
    assert.is_false(out[1].counted)
    assert.equal("not verified", out[1].why)

    -- the same profile twice never verifies itself
    local twice = { kill("p1", "rfc", RFC_FINAL, FIVE, T0), kill("p1", "rfc", RFC_FINAL, FIVE, T0 + 20) }
    assert.equal(0, #Credit.Verified(twice))
    assert.same({}, charsOf(derive(twice), "groups.dungeon"))

    -- too far apart, a different encounter, or fewer than 2 shared names: no pair
    local far = { kill("p1", "rfc", RFC_FINAL, FIVE, T0), kill("p2", "rfc", RFC_FINAL, FIVE, T0 + 601) }
    assert.equal(0, #Credit.Verified(far))
    local thin = { kill("p1", "rfc", RFC_FINAL, { "A-R", "B-R" }, T0),
      kill("p2", "rfc", RFC_FINAL, { "B-R", "C-R" }, T0 + 10) }
    assert.equal(0, #Credit.Verified(thin))
  end)

  it("2 guild + 3 pugs at the last boss gives no credit even if 4 guild started", function()
    local list = {}
    pair(list, "deadmines", 2741, { "A-R", "B-R", "C-R", "D-R", "X-R" }, T0 + HOUR)
    pair(list, "deadmines", 2747, { "A-R", "B-R", "X-R", "Y-R", "Z-R" }, T0 + 2 * HOUR)
    local out = derive(list)
    assert.same({}, charsOf(out, "groups.dungeon"))
    -- 3 of 5 is a majority
    local ok = pair({}, "deadmines", 2747, { "A-R", "B-R", "C-R", "Y-R", "Z-R" }, T0 + 3 * HOUR)
    assert.same({ "A-R", "B-R", "C-R" }, charsOf(derive(ok), "groups.dungeon"))
    -- an unknown roster counts everyone as non-guild
    unknownRoster = true
    assert.same({}, charsOf(derive(ok), "groups.dungeon"))
  end)

  it("two clears either side of server midnight count 2; two in one day count 1", function()
    tz = -5 * HOUR -- server midnight is 05:00 UTC
    local midnight = T0 + 5 * HOUR
    local list = {}
    pair(list, "rfc", RFC_FINAL, FIVE, midnight - 1800)
    pair(list, "rfc", RFC_FINAL, FIVE, midnight + 1800)
    assert.equal(2, count(derive(list), "groups.dungeon", "A-R"))

    local same = {}
    pair(same, "rfc", RFC_FINAL, FIVE, midnight + 1800)
    pair(same, "rfc", RFC_FINAL, FIVE, midnight + 7200)
    local out = derive(same)
    assert.equal(1, count(out, "groups.dungeon", "A-R"))
    assert.equal(midnight + 1800, out[1].at) -- the first one is kept

    -- the same two either side of 05:00 UTC are one UTC day: tz decides
    tz = 0
    assert.equal(1, count(derive(list), "groups.dungeon", "A-R"))
  end)

  it("a level-60 helper in a low dungeon is credited", function()
    local members = { "A-R", "B-R", "C-R", "D-R", "Helper-R" }
    local out = derive(pair({}, "rfc", RFC_FINAL, members, T0))
    assert.equal(1, count(out, "groups.dungeon", "Helper-R"))
  end)

  it("a non-final dungeon boss gives no dungeon credit", function()
    local out = derive(pair({}, "deadmines", 2741, FIVE, T0))
    assert.same({}, out)
    -- not even an uncounted row when unverified
    assert.same({}, derive({ kill("p1", "deadmines", 2741, FIVE, T0) }))
  end)

  it("raid boss credit per kill; the same boss twice in one week counts once", function()
    local list = {}
    pair(list, "mc", 663, FIVE, T0)
    pair(list, "mc", 664, FIVE, T0 + HOUR)
    pair(list, "mc", 663, FIVE, T0 + DAY)          -- Saturday, same lockout
    pair(list, "mc", 663, FIVE, T0 + 7 * DAY)      -- next week
    local out = derive(list)
    assert.equal(3, count(out, "groups.raidboss", "A-R"))
    assert.same({}, charsOf(out, "groups.dungeon"))
    assert.same({}, charsOf(out, "groups.raidclear"))
  end)

  it("full clear spread over two nights in one lockout counts once for those at the last kill", function()
    local night1 = { "A-R", "B-R", "C-R", "D-R", "E-R" }
    local night2 = { "A-R", "B-R", "C-R", "D-R", "F-R" }
    local list = {}
    for i = 1, 5 do pair(list, "mc", MC[i], night1, T0 + 20 * HOUR + i * 600) end
    for i = 6, 10 do pair(list, "mc", MC[i], night2, T0 + DAY + 20 * HOUR + i * 600) end
    pair(list, "mc", 672, night2, T0 + 2 * DAY)   -- a repeat of the last boss in the same lockout
    local out = derive(list)
    assert.same({ "A-R", "B-R", "C-R", "D-R", "F-R" }, charsOf(out, "groups.raidclear"))
    assert.equal(1, count(out, "groups.raidclear", "A-R"))

    -- the same kills split across two lockouts: no clear
    local split = {}
    for i = 1, 5 do pair(split, "mc", MC[i], night1, T0 + 20 * HOUR + i * 600) end
    for i = 6, 10 do pair(split, "mc", MC[i], night2, T0 + 7 * DAY + i * 600) end
    assert.same({}, charsOf(derive(split), "groups.raidclear"))

    -- a missing boss: no clear
    local missing = {}
    for i = 1, 9 do pair(missing, "mc", MC[i], night1, T0 + i * 600) end
    assert.same({}, charsOf(derive(missing), "groups.raidclear"))
  end)

  it("RaidLeaders returns leader and assists from verified kills only", function()
    local day = ns.Scoring.DayKey(T0 + 20 * HOUR, 0)
    local list = {}
    pair(list, "mc", 663, FIVE, T0 + 20 * HOUR, { leader = "A-R", assists = { "B-R" } },
      { leader = "A-R", assists = { "C-R" } })
    list[#list + 1] = kill("p3", "mc", 664, FIVE, T0 + 21 * HOUR, { leader = "Z-R", assists = { "Y-R" } })
    pair(list, "mc", 665, FIVE, T0 + DAY + 20 * HOUR, { leader = "W-R" }, { leader = "W-R" })
    pair(list, "bwl", 610, FIVE, T0 + 20 * HOUR, { leader = "V-R" }, { leader = "V-R" })
    ctx.observations = { List = function(_, kind) return kind == "kill" and list or {} end }
    local credit = Credit.new(ctx)
    assert.same({ ["A-R"] = true, ["B-R"] = true, ["C-R"] = true }, credit:RaidLeaders("mc", day))
    assert.same({}, credit:RaidLeaders("ony", day))
    -- module-level helper, once attached
    assert.same({}, Credit.RaidLeaders("mc", day))
    Credit.Attach(ctx)
    assert.same({ ["A-R"] = true, ["B-R"] = true, ["C-R"] = true }, Credit.RaidLeaders("mc", day))
  end)

  it("a guild member without Guildhall earns nothing, not even toward the guild total", function()
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Ledger.lua")
    ns.Observations = { KINDS = { kill = true } }
    local members = { "A-R", "B-R", "C-R", "X-R", "Y-R" } -- C-R is guild but has no profile
    chars.p3 = nil
    local list = pair({}, "rfc", RFC_FINAL, members, T0)
    ctx.observations = { changes = 0, List = function(_, kind)
      if kind == nil or kind == "kill" then return list end
      return {}
    end }
    ctx.activity = ns.Activity
    ctx.roster.RankIndex = function() return 5 end
    ctx.roster.ConfigList = function() return {} end
    local r = ns.Ledger.new(ctx):Query({ includeUncounted = true })
    assert.equal(1, r.byProfile.p1["groups.dungeon"])
    assert.equal(1, r.byProfile.p2["groups.dungeon"])
    assert.equal(2, r.guild["groups.dungeon"])
    local why = {}
    for _, row in ipairs(r.rows) do why[row.char] = row.why or "ok" end
    assert.same({ ["A-R"] = "ok", ["B-R"] = "ok", ["C-R"] = "not using Guildhall" }, why)
  end)

  it("derives the same contributions from shuffled input", function()
    local list = {}
    pair(list, "rfc", RFC_FINAL, FIVE, T0 + HOUR)
    pair(list, "rfc", RFC_FINAL, FIVE, T0 + 2 * HOUR)
    list[#list + 1] = kill("p3", "rfc", RFC_FINAL, FIVE, T0 + HOUR + 60) -- joins the first cluster
    list[#list + 1] = kill("p1", "mc", 663, FIVE, T0 + 3 * HOUR)        -- unverified
    for i = 1, 10 do pair(list, "mc", MC[i], FIVE, T0 + 4 * HOUR + i * 600) end
    local expected = derive(list)
    local refs = {}
    for _, c in ipairs(expected) do
      assert.is_nil(refs[c.ref], "duplicate ref " .. c.ref)
      refs[c.ref] = true
    end
    math.randomseed(7)
    for _ = 1, 5 do
      local shuffled = {}
      for i, r in ipairs(list) do shuffled[i] = r end
      for i = #shuffled, 2, -1 do
        local j = math.random(i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
      end
      assert.same(expected, derive(shuffled))
    end
  end)
end)
