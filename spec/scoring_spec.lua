describe("Scoring", function()
  local ns, S
  local function utc(y, m, d, h, mi, s) -- epoch for a UTC date
    local a = math.floor((14 - m) / 12)
    y, m = y + 4800 - a, m + 12 * a - 3
    local jdn = d + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 32045
    return (jdn - 2440588) * 86400 + (h or 0) * 3600 + (mi or 0) * 60 + (s or 0)
  end
  local function stubCompat(offset, untilReset)
    return { ServerOffset = function() return offset end, SecondsUntilWeeklyReset = function() return untilReset end }
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Scoring.lua")
    S = ns.Scoring
    local A = ns.Activity
    A.Register({ id = "sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 1 })
    A.Register({ id = "gold.earned", label = "Gold earned", unit = "gold", verify = "paired", weight = 0.1, order = 2 })
    A.Register({ id = "selfthing", label = "Self", unit = "count", verify = "self", weight = 9, order = 3 })
  end)

  it("with no reset API the week starts Tuesday 15:00 UTC", function()
    local clock = { tz = 0 }
    local from, to = S.Period("week", utc(2026, 11, 3, 14, 59, 59), clock)
    assert.equal(utc(2026, 10, 27, 15), from)
    assert.equal(utc(2026, 11, 3, 15), to)
    from, to = S.Period("week", utc(2026, 11, 3, 15, 0, 0), clock)
    assert.equal(utc(2026, 11, 3, 15), from)
    assert.equal(utc(2026, 11, 10, 15), to)
  end)

  it("the week starts at the reset API's time when present", function()
    local now = utc(2026, 11, 5, 10, 7, 13)
    local reset = utc(2026, 11, 10, 9) -- next reset, Tuesday 09:00
    local clock = S.Clock(nil, stubCompat(0, reset - now), now)
    assert.equal(utc(2026, 11, 3, 9), clock.weekStart)
    local from, to = S.Period("week", now, clock)
    assert.equal(utc(2026, 11, 3, 9), from)
    assert.equal(utc(2026, 11, 10, 9), to)
  end)

  it("DayKey follows tz and WeekStart follows the weekly reset", function()
    local t = utc(2026, 11, 4, 3, 0, 0)
    assert.equal("2026-11-04", S.DayKey(t, 0))
    assert.equal("2026-11-03", S.DayKey(t, -5 * 3600))
    assert.equal("2026-11-04", S.DayKey(utc(2026, 11, 4, 5, 0, 0), -5 * 3600))
    -- no reset API: Tuesday 15:00 UTC (2026-11-03 is a Tuesday)
    assert.equal(utc(2026, 11, 3, 15), S.WeekStart(utc(2026, 11, 6, 12), {}))
    assert.equal(utc(2026, 10, 27, 15), S.WeekStart(utc(2026, 11, 3, 14, 59), {}))
    -- with the reset API the same clock as Period("week")
    local now = utc(2026, 11, 4, 12)
    local clock = S.Clock(nil, stubCompat(0, 2 * 86400 + 3 * 3600), now)
    assert.equal((S.Period("week", now - 9 * 86400, clock)), S.WeekStart(now - 9 * 86400, clock))
  end)

  it("month edges follow tz", function()
    local tz = -28800
    assert.equal("2026-10", S.MonthKey(utc(2026, 11, 1, 7, 59, 59), tz))
    assert.equal("2026-11", S.MonthKey(utc(2026, 11, 1, 8, 0, 0), tz))
    local from, to = S.MonthRange("2026-11", tz)
    assert.equal(utc(2026, 11, 1, 8), from)
    assert.equal(utc(2026, 12, 1, 8), to)
    from, to = S.MonthRange("2026-12", 0)
    assert.equal(utc(2026, 12, 1), from)
    assert.equal(utc(2027, 1, 1), to)
    local f, t = S.Period("month", utc(2026, 11, 1, 7, 59, 59), { tz = tz })
    assert.equal(utc(2026, 10, 1, 8), f)
    assert.equal(utc(2026, 11, 1, 8), t)
  end)

  it("all covers the retention window", function()
    local from, to = S.Period("all", 1000000000, { tz = 0 })
    assert.equal(1000000000 - 34560000, from)
    assert.equal(1000000001, to)
  end)

  it("Clock prefers the record's tz over the local offset, then falls back to 0", function()
    assert.equal(-3600, S.Clock({ Tz = function() return -3600 end }, stubCompat(7200), 100).tz)
    assert.equal(7200, S.Clock({ Tz = function() return nil end }, stubCompat(7200), 100).tz)
    assert.equal(7200, S.Clock(nil, stubCompat(7200), 100).tz)
    local c = S.Clock(nil, stubCompat(nil, nil), 100)
    assert.equal(0, c.tz)
    assert.is_nil(c.weekStart)
  end)

  it("Points converts copper and applies weights", function()
    local w = { ["gold.earned"] = 0.1, sales = 5 }
    assert.near(34, S.Points({ ["gold.earned"] = 340 * 10000 }, w), 1e-9)
    assert.near(39, S.Points({ ["gold.earned"] = 340 * 10000, sales = 1 }, w), 1e-9)
    -- missing weight falls back to the registered default; self types are skipped
    assert.near(10, S.Points({ sales = 2, selfthing = 5 }, {}), 1e-9)
    assert.equal("34", S.FormatPoints(34))
    assert.equal("34.5", S.FormatPoints(34.46))
    assert.equal("0.1", S.FormatPoints(0.1))
  end)

  it("weight 0 drops a type from overall but not from its own board", function()
    local result = { byProfile = { a = { sales = 3 }, b = { sales = 1, ["gold.earned"] = 100 * 10000 } } }
    local w = { sales = 0, ["gold.earned"] = 0.1 }
    local overall = S.Board(result, "overall", w, {})
    assert.equal(1, #overall)
    assert.equal("b", overall[1].profile)
    assert.near(10, overall[1].value, 1e-9)
    local sales = S.Board(result, "sales", w, {})
    assert.equal(2, #sales)
    assert.equal("a", sales[1].profile)
    assert.equal(3, sales[1].value)
  end)

  it("ties share a rank", function()
    local result = { byProfile = { c = { sales = 2 }, a = { sales = 2 }, b = { sales = 1 }, d = { sales = 3 } } }
    local b = S.Board(result, "sales", {}, {})
    assert.same({ "d", "a", "c", "b" }, { b[1].profile, b[2].profile, b[3].profile, b[4].profile })
    assert.same({ 1, 2, 2, 4 }, { b[1].rank, b[2].rank, b[3].rank, b[4].rank })
  end)

  it("hidden and zero profiles are not ranked", function()
    local result = { byProfile = { a = { sales = 2 }, h = { sales = 9 }, z = { sales = 0 }, n = { sales = -1 } } }
    local b = S.Board(result, "sales", {}, { isHidden = function(p) return p == "h" end })
    assert.equal(1, #b)
    assert.equal("a", b[1].profile)
  end)

  it("self-verified types are never ranked or listed in the breakdown", function()
    local result = { byProfile = { a = { selfthing = 4, sales = 1 } } }
    assert.same({}, S.Board(result, "selfthing", {}, {}))
    local ledger = { Query = function()
      return { byProfile = result.byProfile, rows = { { type = "selfthing", profile = "a", value = 4, counted = true, ref = "x" } } }
    end }
    local r = S.Breakdown(ledger, "a", 0, 1, {})
    assert.equal(1, #r.lines)
    assert.equal("sales", r.lines[1].type)
    assert.equal(1, #r.items.selfthing)
  end)

  it("a stale weekStart walks to the current week", function()
    local ws = utc(2026, 10, 6, 9) -- Tuesday, three weeks back
    local now = utc(2026, 10, 28, 12)
    local from, to = S.Period("week", now, { tz = 0, weekStart = ws })
    assert.equal(utc(2026, 10, 27, 9), from)
    assert.equal(utc(2026, 11, 3, 9), to)
    from = S.Period("week", utc(2026, 10, 1), { tz = 0, weekStart = ws })
    assert.equal(utc(2026, 9, 29, 9), from)
  end)

  it("positive tz moves the month edge earlier", function()
    assert.equal("2026-10", S.MonthKey(utc(2026, 10, 31, 22, 59, 59), 3600))
    assert.equal("2026-11", S.MonthKey(utc(2026, 10, 31, 23, 0, 0), 3600))
  end)

  it("MonthKey rolls over December to January", function()
    assert.equal("2026-12", S.MonthKey(utc(2026, 12, 31, 23, 59, 59), 0))
    assert.equal("2027-01", S.MonthKey(utc(2027, 1, 1, 0, 0, 0), 0))
    assert.equal("2027-01", S.MonthKey(utc(2026, 12, 31, 23, 0, 0), 3600))
  end)

  it("CanSeeBreakdown: self yes, officer yes, other no", function()
    assert.is_true(S.CanSeeBreakdown("a", "a", false))
    assert.is_true(S.CanSeeBreakdown("a", "b", true))
    assert.is_false(S.CanSeeBreakdown("a", "b", false))
    assert.is_false(S.CanSeeBreakdown(nil, "b", false))
  end)

  it("Breakdown lists netted lines, counted items and uncounted rows", function()
    local rows = {
      { type = "sales", profile = "a", value = 1, at = 5, counted = true, ref = "1" },
      { type = "sales", profile = "a", value = 1, at = 6, counted = false, why = "unpaired", ref = "2" },
      { type = "sales", profile = "b", value = 1, at = 7, counted = true, ref = "3" },
    }
    local seen
    local ledger = { Query = function(_, q)
      seen = q
      return { byProfile = { a = { sales = 1, ["gold.earned"] = 20000 }, b = { sales = 1 } }, rows = rows }
    end }
    local r = S.Breakdown(ledger, "a", 0, 100, { sales = 5, ["gold.earned"] = 0.1 })
    assert.is_true(seen.includeUncounted)
    assert.equal(0, seen.from); assert.equal(100, seen.to)
    assert.equal(2, #r.lines)
    assert.equal("sales", r.lines[1].type)
    assert.equal(5, r.lines[1].points)
    assert.near(0.2, r.lines[2].points, 1e-9)
    assert.near(5.2, r.total, 1e-9)
    assert.equal(1, #r.items.sales)
    assert.equal("1", r.items.sales[1].ref)
    assert.equal(1, #r.notCounted)
    assert.equal("unpaired", r.notCounted[1].why)
  end)
end)
