local ADDON, ns = ...

-- Scoring for the Leaderboard: period boundaries, points, ranked boards, breakdown visibility.
-- Pure arithmetic over the Ledger's query results. All stored times are UTC epoch seconds; only
-- period boundaries are shifted by the guild's server offset (clock.tz). Never local time:
-- dates come from `date("!*t", ...)` only. Gold values are copper; weights are per gold.
-- Uses global `date` (WoW) or os.date (specs), the same as Log.lua.
ns.Scoring = ns.Scoring or {}
local Scoring = ns.Scoring

local WEEK, DAY, HOUR = 604800, 86400, 3600
local RETENTION = 34560000
-- Tuesday 1970-01-06 15:00 UTC, a known weekly reset instant (epoch anchor for the fallback).
local TUE_1500 = 5 * DAY + 15 * HOUR

local function round(n, step) return math.floor(n / step + 0.5) * step end

-- Days since 1970-01-01 of a proleptic Gregorian date (month 1-12).
local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- cfg: nil or an object with :Tz() (seconds or nil). compat: :ServerOffset(), :SecondsUntilWeeklyReset().
function Scoring.Clock(cfg, compat, now)
  local tz = cfg and cfg.Tz and cfg:Tz() or nil
  if tz == nil and compat and compat.ServerOffset then tz = compat:ServerOffset() end
  local clock = { tz = tz or 0 }
  local untilReset = compat and compat.SecondsUntilWeeklyReset and compat:SecondsUntilWeeklyReset() or nil
  if untilReset then clock.weekStart = round(now + untilReset - WEEK, HOUR) end
  return clock
end

function Scoring.MonthKey(t, tz)
  local f = date or os.date
  local d = f("!*t", t + (tz or 0))
  return string.format("%04d-%02d", d.year, d.month)
end

-- Epoch range [from, to) of a calendar month ("YYYY-MM") on the clock shifted by tz.
function Scoring.MonthRange(ym, tz)
  local y, m = ym:match("^(%d+)-(%d+)$")
  y, m = tonumber(y), tonumber(m)
  tz = tz or 0
  local ny, nm = y, m + 1
  if nm > 12 then ny, nm = y + 1, 1 end
  return daysFromCivil(y, m, 1) * DAY - tz, daysFromCivil(ny, nm, 1) * DAY - tz
end

-- Server day of an epoch time on the clock shifted by tz: "YYYY-MM-DD".
function Scoring.DayKey(at, tz)
  local f = date or os.date
  local d = f("!*t", at + (tz or 0))
  return string.format("%04d-%02d-%02d", d.year, d.month, d.day)
end

-- Start of the weekly reset period containing `at` (the same rule as Period("week")).
function Scoring.WeekStart(at, clock)
  return (Scoring.Period("week", at, clock))
end

function Scoring.Period(key, now, clock)
  clock = clock or {}
  if key == "week" then
    local start = clock.weekStart
    if start then
      -- the reset time is a point on the weekly cycle; walk it to the week containing `now`
      start = start + math.floor((now - start) / WEEK) * WEEK
    else
      start = now - ((now - TUE_1500) % WEEK)
    end
    return start, start + WEEK
  elseif key == "month" then
    return Scoring.MonthRange(Scoring.MonthKey(now, clock.tz), clock.tz)
  end
  return now - RETENTION, now + 1
end

local function weightOf(weights, id)
  local w = weights and weights[id]
  if w ~= nil then return w end
  local def = ns.Activity.Get(id)
  return def and def.weight or 0
end

-- Points for one profile's per-type totals. `self` types and unknown types are skipped.
function Scoring.Points(totals, weights)
  local sum = 0
  for id, value in pairs(totals or {}) do
    local def = ns.Activity.Get(id)
    if def and def.verify ~= "self" then
      if def.unit == "gold" then value = value / 10000 end
      sum = sum + value * weightOf(weights, id)
    end
  end
  return sum
end

-- One decimal, with ".0" dropped.
function Scoring.FormatPoints(n)
  local s = string.format("%.1f", n)
  return (s:gsub("%.0$", ""))
end

-- board: "overall" (points) or an activity id (that type's value). -> { {profile, value, rank} }
function Scoring.Board(result, board, weights, opts)
  local isHidden = opts and opts.isHidden
  local out = {}
  local def = board ~= "overall" and ns.Activity.Get(board) or nil
  if def and def.verify == "self" then return out end
  for profile, totals in pairs(result.byProfile or {}) do
    if not (isHidden and isHidden(profile)) then
      local value
      if board == "overall" then value = Scoring.Points(totals, weights) else value = totals[board] or 0 end
      if value > 0 then out[#out + 1] = { profile = profile, value = value } end
    end
  end
  table.sort(out, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return tostring(a.profile) < tostring(b.profile)
  end)
  for i, e in ipairs(out) do
    e.rank = (i > 1 and out[i - 1].value == e.value) and out[i - 1].rank or i
  end
  return out
end

function Scoring.CanSeeBreakdown(viewerProfile, targetProfile, viewerIsOfficer)
  if viewerIsOfficer then return true end
  return viewerProfile ~= nil and viewerProfile == targetProfile
end

function Scoring.Breakdown(ledger, profile, from, to, weights)
  local result = ledger:Query({ from = from, to = to, includeUncounted = true })
  local totals = (result.byProfile or {})[profile] or {}
  local lines, items, notCounted = {}, {}, {}
  for _, def in ipairs(ns.Activity.Types()) do
    local value = totals[def.id]
    if value and value ~= 0 and def.verify ~= "self" then
      local w = weightOf(weights, def.id)
      lines[#lines + 1] = {
        type = def.id, value = value, weight = w,
        points = Scoring.Points({ [def.id] = value }, weights),
      }
    end
  end
  for _, row in ipairs(result.rows or {}) do
    if row.profile == profile then
      if row.counted then
        items[row.type] = items[row.type] or {}
        items[row.type][#items[row.type] + 1] = row
      else
        notCounted[#notCounted + 1] = row
      end
    end
  end
  return { lines = lines, total = Scoring.Points(totals, weights), items = items, notCounted = notCounted }
end
