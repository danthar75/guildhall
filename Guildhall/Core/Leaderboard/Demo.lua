local ADDON, ns = ...

-- Demo data for the Leaderboard: `/gh lbdemo` swaps in fake activity so the tab can be tried
-- (and screenshotted) without a guild's real numbers; `/gh lbdemo off` puts the real ledger back.
-- In memory only: nothing is stored, synced or sent, and the profiles are made-up names, never
-- real guildmates. The fake data covers this week, this month, last month and one saved month.
--
-- Demo.Build(now, clock?) -> store: an observations-like object { List(kind), changes, names
--   (profile id -> name), month = { ym, rec } }. clock = { tz, weekStart? } as Scoring.Clock builds it.
-- Demo.Set(ns, on): turns demo mode on or off. While on, ns.leaderboard.demo is true,
--   ns.leaderboard.ledger / .config are demo versions and ns.leaderboard.demoProfile answers the
--   View's profile questions (names, hidden, online, who you are). Returns false without a Leaderboard.
ns.Leaderboard = ns.Leaderboard or {}
local Demo = {}
ns.Leaderboard.Demo = Demo

local DAY = 86400
local NAMES = { "Thalwyn", "Brakka", "Mireth", "Kael", "Sorrel", "Vanth", "Ysolde", "Garrick",
  "Nimue", "Oswin", "Pell", "Corvane" }
local YOU = "d12" -- the profile the demo treats as the player ("Corvane")
local DEALS, BANK = 60, 40

local function ids()
  local list = {}
  for i = 1, #NAMES do list[i] = "d" .. i end
  return list
end

-- A spread of times inside [from, to): deterministic, so the demo looks the same every time.
local function spread(from, to, i)
  local span = math.max(to - from - 1, 1)
  return from + (i * 7919 + 13) % span
end

local function windows(now, clock)
  local Scoring = ns.Scoring
  clock = clock or { tz = 0 }
  local wf, wt = Scoring.Period("week", now, clock)
  local mf, mt = Scoring.Period("month", now, clock)
  local pym = Scoring.MonthKey(mf - 1, clock.tz)
  local pf, pt = Scoring.MonthRange(pym, clock.tz)
  return {
    { wf, math.min(wt, now) }, { mf, math.min(mt, now) }, { pf, pt },
  }, pym, pf, pt
end

local function savedMonth(ym, from, to, tz, now)
  local order = { 4, 1, 3, 2, 7 }
  local function top(scale)
    local out = {}
    for rank, n in ipairs(order) do
      out[rank] = { profile = "d" .. n, name = NAMES[n], value = scale * (6 - rank), rank = rank }
    end
    return out
  end
  local boards = {}
  for _, def in ipairs(ns.Activity.Types()) do
    if def.verify ~= "self" then
      boards[def.id] = top(def.unit == "gold" and 250000 or 4)
    end
  end
  return { month = ym, from = from, to = to, tz = tz, goldKept = 8400000,
    overall = top(60), boards = boards, weights = {}, savedBy = NAMES[1], savedAt = to + 4 * DAY }
end

function Demo.Build(now, clock)
  local list = ids()
  local wins, pym, pf, pt = windows(now, clock)
  local recs = { trade = {}, cod = {}, bank = {} }
  local n = 0
  local function add(kind, by, d)
    n = n + 1
    local t = recs[kind]
    t[#t + 1] = { id = "demo:o" .. n, v = 1, t = d.at, by = by, d = d }
  end

  for i = 1, DEALS do
    local w = wins[(i - 1) % 3 + 1]
    local at = spread(w[1], w[2], i)
    local si = (i * 7 + math.floor(i / 3)) % 12 + 1
    local bi = (i * 5 + 3) % 12 + 1
    if bi == si then bi = bi % 12 + 1 end
    local seller, buyer = list[si], list[bi]
    local kind = (i % 5 == 0) and "cod" or "trade"
    local d = { kind = kind, listing = seller .. ":" .. (100 + i), seller = seller, buyer = buyer,
      item = 2589 + i % 5, count = 1 + i % 20, copper = 10000 * (5 + i % 40), at = at,
      owner = seller, listed = at - 3 * DAY }
    add(kind, seller, d)
    local mine = {}
    for k, v in pairs(d) do mine[k] = v end
    mine.at = at + 30
    add(kind, buyer, mine)
  end

  for i = 1, BANK do
    local w = wins[(i - 1) % 3 + 1]
    local at = spread(w[1], w[2], i + 500)
    at = at - at % 3600
    local owner = (i * 3) % 12 + 1
    local d = { kind = "bank", type = (i % 9 == 0) and "wd" or "dep", player = NAMES[owner], at = at }
    if i % 4 == 0 then
      d.copper = 10000 * (10 + i * 3)
    else
      d.tab, d.item, d.count = 1 + i % 3, 2589 + i % 7, 5 + i % 20
    end
    -- reported by someone other than the depositor, so it counts
    add("bank", list[owner % 12 + 1], d)
  end

  local names, owners = {}, {}
  for i, id in ipairs(list) do names[id] = NAMES[i]; owners[NAMES[i]] = id end
  local store = { names = names, owners = owners, changes = 0 }
  function store:List(kind)
    local out = {}
    for _, k in ipairs(kind and { kind } or { "trade", "cod", "bank" }) do
      for _, rec in ipairs(recs[k] or {}) do out[#out + 1] = rec end
    end
    return out
  end
  store.month = { ym = pym, rec = savedMonth(pym, pf, pt, (clock or {}).tz or 0, now) }
  return store
end

-- Answers the View's questions about people from the fake names.
local function profileFor(store)
  local p = {}
  function p:Id() return YOU end
  function p:IsHidden() return false end
  function p:OnlineChar(id)
    local n = tonumber(tostring(id):match("^d(%d+)$"))
    if n and n % 2 == 1 then return store.names[id] end
    return nil
  end
  function p:OwnerOf(char) return store.owners[char] end
  function p:CharsOf(id) return store.names[id] and { store.names[id] } or {} end
  return p
end

local roster = {
  RankIndex = function() return nil end,
  ConfigList = function() return {} end,
}

local REFUSED = "Demo data is only on your screen; turn it off with /gh lbdemo off to change settings."

-- A whitelist, not a pass-through: only the read methods reach the real config, and every
-- method that could publish or save refuses. The demo can never write to the real guild.
local function configFor(real, store)
  local c = {}
  for _, name in ipairs({ "Weights", "WeightsInfo", "Tz" }) do
    c[name] = function(_, ...) return real[name](real, ...) end
  end
  function c:History() return {} end -- a read, never a write
  function c:Months() return { store.month.ym } end
  function c:Month(ym)
    if ym == store.month.ym then return ns.Util.DeepCopy(store.month.rec) end
    return nil
  end
  for _, name in ipairs({ "PublishWeights", "RetakeMonth", "MaybeSaveMonth", "MaybeRefreshTz", "SetExcluded" }) do
    c[name] = function() return false, REFUSED end
  end
  return c
end

local function refresh()
  local view = ns.Leaderboard.View
  if view and view.Refresh then view.Refresh() end
end

function Demo.Set(n, on)
  local lb = n.leaderboard
  if not lb then return false end
  if on and not lb.demo then
    local s = n.services
    local now = s.now()
    local clock = ns.Scoring.Clock(lb.config, s.compat, now)
    local store = Demo.Build(now, clock)
    local profile = profileFor(store)
    lb.realLedger, lb.realConfig = lb.ledger, lb.config
    lb.ledger = ns.Ledger.new({ observations = store, profile = profile, roster = roster, now = s.now })
    lb.config = configFor(lb.realConfig, store)
    lb.demoProfile, lb.demo = profile, true
  elseif not on and lb.demo then
    lb.ledger, lb.config = lb.realLedger, lb.realConfig
    lb.ledger:Invalidate()
    lb.realLedger, lb.realConfig, lb.demoProfile, lb.demo = nil, nil, nil, nil
  end
  refresh()
  return true
end
