describe("Groups Calendar", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, bus, loaded, cfgStore, obsStore, kills, clients
  local DAY = 86400

  local function utc(y, m, d, h)
    local a = math.floor((14 - m) / 12)
    y, m = y + 4800 - a, m + 12 * a - 3
    local jdn = d + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100)
      + math.floor(y / 400) - 32045
    return (jdn - 2440588) * 86400 + (h or 0) * 3600
  end

  local ranks
  local roster = {
    HasRanks = function() return loaded end,
    RankIndex = function(_, n) return ranks[n] end,
    IsOfficer = function(_, n) return ranks[n] ~= nil and ranks[n] <= 1 end,
    IsMember = function(_, n) return ranks[n] ~= nil end,
    ConfigList = function() return {} end,
  }
  -- every char "X-R" is linked to profile "pX" (the kill reporters "pA", "pB" own "A-R", "B-R")
  local linked = { OwnerOf = function(_, n) return type(n) == "string" and ("p" .. n:match("^[^-]+")) or nil end }
  local killObs = { List = function(_, kind) if kind == "kill" then return kills end return {} end }
  local function pid(char) return "p" .. char:match("^[^-]+") end

  local events   -- list of fake GetDayEvent infos, each with .day = { y, m, d }
  local env
  local function calEnv(extra)
    local e = {
      date = os.date,
      C_Calendar = {
        opened = 0,
        OpenCalendar = function() env.C_Calendar.opened = env.C_Calendar.opened + 1 end,
        GetNumDayEvents = function(off, day)
          local n = 0
          for _, ev in ipairs(events) do if ev.mo == off and ev.day == day then n = n + 1 end end
          return n
        end,
        GetDayEvent = function(off, day, i)
          local n = 0
          for _, ev in ipairs(events) do
            if ev.mo == off and ev.day == day then
              n = n + 1
              if n == i then return ev.info end
            end
          end
        end,
      },
    }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
  end

  -- an event on 2026-11-<day> 20:00 server time (offset 0)
  local function ev(day, title, status, ctype, mo)
    return { mo = mo or 0, day = day, info = { title = title, calendarType = ctype or "GUILD_EVENT",
      inviteStatus = status, startTime = { year = 2026, month = 11, monthDay = day, hour = 20, minute = 0 } } }
  end

  local function client(char, db)
    local c = { char = char }
    local log = ns.Log.new({}, clock.now, function() return "" end)
    c.compat = {
      ServerOffset = function() return 0 end,
      GuildEvents = function() return c.events end,
    }
    c.profile = {
      Id = function() return pid(char) end,
      IsExcluded = function() return false end,
      OwnerOf = function(_, n) return pid(n) end,
      CharsOf = function(_, id) return { id:sub(2) .. "-R" } end,
      set = { Get = function() return nil end },
    }
    local comm = bus:join(char)
    c.cfg = ns.LbConfig.new({ comm = comm, now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = log, roster = roster, profile = c.profile, compat = c.compat, playerChar = char, db = cfgStore })
    c.obs = ns.Observations.New({ comm = comm, now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = log, roster = roster, profile = c.profile, playerChar = char,
      db = obsStore })
    c.db = db or {}
    c.cal = ns.Groups.Calendar.new({ config = c.cfg, observations = c.obs, compat = c.compat, now = clock.now,
      playerChar = char, profile = c.profile, db = c.db })
    clients[char] = c
    return c
  end

  local function derive(c)
    local all = { List = function(_, kind)
      if kind == "kill" then return kills end
      return c.obs:List(kind)
    end }
    local ctx = { roster = roster, config = c.cfg, compat = c.compat, now = clock.now, observations = all,
      profile = c.profile }
    return ns.Activity.Deriver("signup")(c.obs:List("signup"), ctx)
  end

  local function counted(out, char)
    local n = 0
    for _, x in ipairs(out) do
      if x.type == "groups.signedup" and x.counted and x.char == char then n = n + x.value end
    end
    return n
  end

  local seq = 0
  local function verifiedKill(at, members, instance, encounter)
    for i, by in ipairs({ "pA", "pB" }) do
      seq = seq + 1
      kills[#kills + 1] = { id = "k" .. seq, by = by, char = by:sub(2) .. "-R",
        d = { kind = "kill", instance = instance or "mc", encounter = encounter or 663, at = at + i,
          members = members or { "A-R", "B-R", "Raider-R" }, leader = "A-R", assists = {} } }
    end
  end

  local function postObs(c, post, status, from, to, at)
    local s, err = c.obs:Publish({ kind = "signup", post = post, instance = "mc", from = from, to = to,
      status = status or "signedup", at = at or clock.now() })
    assert.equal("accepted", s, tostring(err))
  end

  before_each(function()
    ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Observations.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Config.lua")
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Perms.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Credit.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Calendar.lua")
    clock = fakes.clock(utc(2026, 11, 4, 20))
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    ranks = { ["Gm-R"] = 0, ["Raider-R"] = 5, ["A-R"] = 5, ["B-R"] = 5 }
    loaded = true
    cfgStore, obsStore, kills, clients, events = {}, {}, {}, {}, {}
    ns.Groups.Credit.Attach({ observations = killObs, config = nil, now = clock.now,
      compat = { ServerOffset = function() return 0 end }, profile = linked })
  end)

  -- Compat:GuildEvents ---------------------------------------------------------------------

  describe("Compat:GuildEvents", function()
    local function compatFor(extra)
      local cns = {}
      loadAddonFile(cns, "Guildhall/Core/Util.lua")
      loadAddonFile(cns, "Guildhall/Core/Compat.lua")
      loadAddonFile(cns, "Guildhall/Modules/Groups/Instances.lua")
      env = calEnv(extra)
      if extra == nil or extra.C_DateAndTime == nil then
        env.C_DateAndTime = { GetServerTimeLocal = function() return 1000000 end }
        env.GetServerTime = env.GetServerTime or function() return 1000000 end
      end
      local c = cns.Compat.new(env)
      return c, cns
    end
    local from = function() return utc(2026, 11, 4, 12) end

    it("events read nothing inside an instance or with a secret value", function()
      events = { ev(5, "MC tonight", 3) }
      local c = compatFor({ GetInstanceInfo = function() return "x", "raid", 1, "", 40, 0, false, 409 end })
      assert.is_nil(c:GuildEvents(from(), from() + 14 * DAY))
      local c2 = compatFor({ issecretvalue = function(v) return v == "MC tonight" end })
      assert.is_nil(c2:GuildEvents(from(), from() + 14 * DAY))
      local c3 = compatFor({ issecretvalue = function(v) return v == 3 end })
      assert.is_nil(c3:GuildEvents(from(), from() + 14 * DAY))
      local c4 = compatFor({ C_RestrictedActions = { GetAddOnRestrictionState = function() return 2 end },
        Enum = { AddOnRestrictionType = { Chat = 5 } } })
      assert.is_nil(c4:GuildEvents(from(), from() + 14 * DAY))
      local c5 = compatFor()
      assert.is_table(c5:GuildEvents(from(), from() + 14 * DAY))
    end)

    it("reads guild events only, maps instance and status, opens the calendar once", function()
      events = { ev(5, "Naxx run", 3), ev(5, "Guild party", 6), ev(6, "Player thing", 3, "PLAYER"),
        ev(9, "ony and mc night", 6), ev(20, "MC too far", 3), ev(1, "next month", 0, "GUILD_EVENT", 1) }
      events[#events].info.startTime = { year = 2026, month = 12, monthDay = 1, hour = 20, minute = 0 }
      events[#events].day = 1
      local c = compatFor()
      local list = c:GuildEvents(from(), from() + 14 * DAY)
      assert.equal(3, #list)
      assert.equal("Guild party", list[1].title)
      assert.is_nil(list[1].instance)
      assert.equal("signedup", list[1].myStatus)
      assert.equal(utc(2026, 11, 5, 20), list[1].start)
      assert.equal("Naxx run", list[2].title)
      assert.equal("naxx", list[2].instance)
      assert.equal("accepted", list[2].myStatus)
      assert.equal("ony and mc night", list[3].title)
      c:GuildEvents(from(), from() + 14 * DAY)
      assert.equal(1, env.C_Calendar.opened)
    end)

    it("converts event times with the real server offset and reads nothing when it is unknown", function()
      events = { ev(5, "MC night", 3) }
      local function withOffset(off)
        return compatFor({ C_DateAndTime = { GetServerTimeLocal = function() return 1000000 + off end },
          GetServerTime = function() return 1000000 end })
      end
      local list = withOffset(-18000):GuildEvents(from(), from() + 14 * DAY)
      assert.equal(utc(2026, 11, 6, 1), list[1].start)   -- 20:00 at UTC-5 is 01:00 UTC the next day
      list = withOffset(3600):GuildEvents(from(), from() + 14 * DAY)
      assert.equal(utc(2026, 11, 5, 19), list[1].start)
      local bare = compatFor()
      bare.env.C_DateAndTime = nil
      assert.is_nil(bare:GuildEvents(from(), from() + 14 * DAY))
    end)

    it("reads events in the open world, where return 8 is the continent's map id (0 or 1)", function()
      events = { ev(5, "MC night", 3) }
      local elwynn = compatFor({ GetInstanceInfo = function() return "Elwynn Forest", "none", 0, "", 0, 0, false, 0 end })
      local list = elwynn:GuildEvents(from(), from() + 14 * DAY)
      assert.equal(1, #list)
      assert.equal("MC night", list[1].title)
      local kalimdor = compatFor({ GetInstanceInfo = function() return "Kalimdor", "none", 0, "", 0, 0, false, 1 end })
      assert.equal(1, #kalimdor:GuildEvents(from(), from() + 14 * DAY))
      -- a dungeon blocks it like a raid; a secret instance type reads nothing
      local rfc = compatFor({ GetInstanceInfo = function() return "Ragefire Chasm", "party", 1, "", 5, 0, false, 389 end })
      assert.is_nil(rfc:GuildEvents(from(), from() + 14 * DAY))
      local secret = compatFor({ GetInstanceInfo = function() return "x", "none", 0, "", 0, 0, false, 0 end,
        issecretvalue = function(v) return v == "none" end })
      assert.is_nil(secret:GuildEvents(from(), from() + 14 * DAY))
    end)

    it("month offsets are relative to the month the calendar is showing", function()
      -- the calendar UI is on December 2026: November's days are at offset -1
      events = { ev(25, "MC night", 3, nil, -1), ev(1, "Dec raid", 3, nil, 0) }
      events[2].info.startTime = { year = 2026, month = 12, monthDay = 1, hour = 20, minute = 0 }
      local c = compatFor()
      env.C_Calendar.GetMonthInfo = function(off)
        assert.equal(0, off)
        return { month = 12, year = 2026, numDays = 31, firstWeekday = 3 }
      end
      local list = c:GuildEvents(utc(2026, 11, 20, 12), utc(2026, 11, 20, 12) + 14 * DAY)
      assert.equal(2, #list)
      assert.equal("MC night", list[1].title)
      assert.equal("Dec raid", list[2].title)
      -- a secret or malformed month info falls back to the month of fromT
      events = { ev(5, "MC night", 3) }
      env.C_Calendar.GetMonthInfo = function() return { month = 12, year = 2026 } end
      env.issecretvalue = function(v) return v == 12 end
      assert.equal(1, #c:GuildEvents(from(), from() + 14 * DAY))
      env.issecretvalue = nil
      env.C_Calendar.GetMonthInfo = function() return nil end
      assert.equal(1, #c:GuildEvents(from(), from() + 14 * DAY))
    end)

    it("matches titles on whole words only", function()
      local c = compatFor()
      assert.equal("mc", c:_instanceFromTitle("MC Tuesday"))
      assert.equal("zg", c:_instanceFromTitle("zul'gurub"))
      assert.equal("aq40", c:_instanceFromTitle("Temple of Ahn'Qiraj"))
      assert.is_nil(c:_instanceFromTitle("McDonalds"))
      assert.is_nil(c:_instanceFromTitle("Fun night"))
    end)
  end)

  -- Validator ---------------------------------------------------------------------------------

  describe("signup validator", function()
    local V
    before_each(function() V = ns.Groups.Calendar.ValidateSignup end)
    local g = function(x)
      local d = { kind = "signup", post = "p1", instance = "mc", from = 1000, to = 5000, status = "signedup", at = 10 }
      for k, v in pairs(x or {}) do d[k] = v end
      return d
    end
    local c = function(x)
      local d = { kind = "signup", title = "MC", start = 100000, status = "accepted", at = 10 }
      for k, v in pairs(x or {}) do d[k] = v end
      return d
    end

    it("accepts exactly the two shapes", function()
      assert.is_true((V(g())))
      assert.is_true((V(g({ status = "withdrawn" }))))
      assert.is_true((V(c())))
      assert.is_true((V(c({ instance = "mc", status = "signedup" }))))
    end)

    it("rejects bad fields, bounds, statuses and windows", function()
      assert.is_false((V(g({ extra = 1 }))))
      local noInst = g()
      noInst.instance = nil
      assert.is_false((V(noInst)))
      assert.is_false((V(g({ instance = "nope" }))))
      assert.is_false((V(g({ status = "accepted" }))))
      assert.is_false((V(g({ to = 1000 }))))
      assert.is_false((V(g({ to = 1000 + 30001 }))))
      assert.is_true((V(g({ to = 1000 + 30000 }))))
      assert.is_false((V(g({ from = 1.5 }))))
      assert.is_false((V(g({ from = -1 }))))
      assert.is_false((V(g({ post = ("x"):rep(65) }))))
      assert.is_false((V(g({ title = "MC" }))))
      assert.is_false((V(c({ title = ("x"):rep(65) }))))
      assert.is_false((V(c({ title = "" }))))
      assert.is_false((V(c({ status = "withdrawn" }))))
      assert.is_false((V(c({ start = 1.5 }))))
      assert.is_false((V(c({ from = 1 }))))
      assert.is_false((V(c({ instance = "nope" }))))
      assert.is_false((V(c({ at = 0 / 0 }))))
    end)

    it("is enforced by Observations:Publish", function()
      local cl = client("Raider-R")
      assert.equal("invalid", (cl.obs:Publish({ kind = "signup", title = "x", start = 5, status = "bogus", at = 1 })))
    end)
  end)

  -- Refresh -------------------------------------------------------------------------------------

  it("the signup observation is published once per event", function()
    local c = client("Raider-R")
    local start = clock.now() + DAY
    c.events = { { title = "MC night", start = start, instance = "mc", myStatus = "accepted" },
      { title = "Naxx", start = start, instance = "naxx", myStatus = "declined" },
      { title = "AQ", start = start, instance = "aq40", myStatus = "tentative" } }
    assert.is_true(c.cal:Refresh())
    assert.is_true(c.cal:Refresh())
    local list = c.obs:List("signup")
    assert.equal(1, #list)
    assert.same({ kind = "signup", title = "MC night", start = start, instance = "mc", status = "accepted",
      at = clock.now() }, list[1].d)
    -- a new client object with the same db does not republish
    local again = ns.Groups.Calendar.new({ config = c.cfg, observations = c.obs, compat = c.compat, now = clock.now,
      playerChar = "Raider-R", profile = c.profile, db = c.db })
    again:Refresh()
    assert.equal(1, #c.obs:List("signup"))
    assert.is_not_nil(c.db.calSent["MC night|" .. start])
    -- entries older than 30 days expire
    clock.advance(40 * DAY)
    c.events = {}
    c.cal:Refresh()
    assert.is_nil(c.db.calSent["MC night|" .. start])
  end)

  it("a nil reading publishes nothing and keeps the cached events", function()
    local c = client("Raider-R")
    local start = clock.now() + DAY
    c.events = { { title = "MC night", start = start, instance = "mc", myStatus = "accepted" } }
    c.cal:Refresh()
    c.events = nil
    assert.is_false(c.cal:Refresh())
    assert.equal(1, #c.cal:Events())
  end)

  it("Events marks entries Calendar and counts members who signed up", function()
    local a, b = client("A-R"), client("B-R")
    local start = clock.now() + DAY
    local e = { title = "MC night", start = start, instance = "mc", myStatus = "accepted" }
    a.events, b.events = { e }, { e }
    a.cal:Refresh()
    b.cal:Refresh()
    local out = a.cal:Events()
    assert.equal(1, #out)
    assert.equal("Calendar", out[1].source)
    assert.equal(2, out[1].accepted)
    assert.equal("mc", out[1].instance)
    assert.same({ "A-R", "B-R" }, a.cal:Attendees("MC night", start))
    assert.same({}, a.cal:Attendees("MC night", start + 1))
  end)

  -- Deriver ---------------------------------------------------------------------------------------

  it("a Guildhall signup plus a verified kill in the window counts once", function()
    local raider = client("Raider-R")
    local now = clock.now()
    postObs(raider, "post1", "signedup", now - 600, now + 3600)
    verifiedKill(now + 100)
    local out = derive(raider)
    assert.equal(1, counted(out, "Raider-R"))
    assert.equal("signup:Raider-R:mc:2026-11-04", out[1].ref)
    -- re-signing and a second kill that day change nothing
    postObs(raider, "post1", "signedup", now - 600, now + 3600, now + 5)
    verifiedKill(now + 900, nil, "mc", 664)
    assert.equal(1, counted(derive(raider), "Raider-R"))
  end)

  it("a signup without a kill counts nothing", function()
    local raider = client("Raider-R")
    local now = clock.now()
    postObs(raider, "post1", "signedup", now - 600, now + 3600)
    local out = derive(raider)
    assert.equal(0, counted(out, "Raider-R"))
    assert.equal("no verified kill yet", out[1].why)
    -- a kill outside the window, of another instance, or without the player does not count
    verifiedKill(now + 7200)
    verifiedKill(now + 100, nil, "bwl", 610)
    verifiedKill(now + 100, { "A-R", "B-R", "Gm-R" })
    assert.equal(0, counted(derive(raider), "Raider-R"))
  end)

  it("a withdrawn signup counts nothing; the latest observation wins", function()
    local raider = client("Raider-R")
    local now = clock.now()
    verifiedKill(now + 100)
    postObs(raider, "post1", "signedup", now - 600, now + 3600, now - 10)
    postObs(raider, "post1", "withdrawn", now - 600, now + 3600, now)
    assert.equal(0, counted(derive(raider), "Raider-R"))
    postObs(raider, "post1", "signedup", now - 600, now + 3600, now + 1)
    assert.equal(1, counted(derive(raider), "Raider-R"))
  end)

  it("a signup published after the kill earns nothing; one before it still does", function()
    local raider = client("Raider-R")
    local now = clock.now()
    verifiedKill(now - 1000)
    postObs(raider, "late", "signedup", now - 5000, now + 5000, now)
    assert.equal(0, counted(derive(raider), "Raider-R"))
    local early = client("A-R")
    postObs(early, "early", "signedup", now - 5000, now + 5000, now - 2000)
    assert.equal(1, counted(derive(early), "A-R"))
    -- a post signup after its own window end never counts
    local odd = client("B-R")
    kills = {}
    verifiedKill(now + 100)
    postObs(odd, "odd", "signedup", now - 5000, now - 4000, now)
    assert.equal(0, counted(derive(odd), "B-R"))
  end)

  it("a calendar signup is credited only when paired with a verified kill", function()
    local raider = client("Raider-R")
    local now = clock.now()
    local start = now + 600
    raider.events = { { title = "Raid night", start = start, instance = nil, myStatus = "signedup" } }
    raider.cal:Refresh()
    assert.equal(0, counted(derive(raider), "Raider-R"))
    verifiedKill(start + 3600)   -- any raid counts for an unknown instance
    assert.equal(1, counted(derive(raider), "Raider-R"))
    -- a dungeon does not
    kills = {}
    verifiedKill(start + 3600, nil, "lbrs", 275)
    assert.equal(0, counted(derive(raider), "Raider-R"))
    -- outside start-1800..start+21600
    kills = {}
    verifiedKill(start + 21600 + 100)
    assert.equal(0, counted(derive(raider), "Raider-R"))
    kills = {}
    verifiedKill(start - 1800 - 100)
    assert.equal(0, counted(derive(raider), "Raider-R"))
  end)

  it("an event at 23:30 with kills after midnight counts once, on the kill's server day", function()
    local raider = client("Raider-R")
    clock.advance(3 * 3600 + 30 * 60) -- 23:30
    local start = clock.now()
    raider.events = { { title = "MC late", start = start, instance = "mc", myStatus = "accepted" } }
    raider.cal:Refresh()
    verifiedKill(start + 40 * 60)     -- 00:10
    local out = derive(raider)
    assert.equal(1, counted(out, "Raider-R"))
    assert.equal("signup:Raider-R:mc:2026-11-05", out[1].ref)
  end)

  it("a dungeon post signup needs the final boss: non-final kills expire and never credit", function()
    local raider = client("Raider-R")
    local now = clock.now()
    assert.equal("accepted", (raider.obs:Publish({ kind = "signup", post = "vc", instance = "deadmines",
      from = now - 600, to = now + 3600, status = "signedup", at = now })))
    verifiedKill(now + 100, nil, "deadmines", 2741)
    assert.equal(0, counted(derive(raider), "Raider-R"))
    verifiedKill(now + 1800, nil, "deadmines", 2747)
    assert.equal(1, counted(derive(raider), "Raider-R"))
  end)

  it("a raid posted and on the calendar counts once per instance and day", function()
    local raider = client("Raider-R")
    local now = clock.now()
    local start = now
    postObs(raider, "post1", "signedup", start - 1800, start + 21600)
    raider.events = { { title = "MC night", start = start, instance = "mc", myStatus = "accepted" } }
    raider.cal:Refresh()
    verifiedKill(now + 100)
    local out = derive(raider)
    assert.equal(1, counted(out, "Raider-R"))
    local dup
    for _, r in ipairs(out) do if r.why == "already credited tonight" then dup = r end end
    assert.is_not_nil(dup)
    assert.is_false(dup.counted)
    -- another instance the same day counts separately
    verifiedKill(now + 200, nil, "bwl", 610)
    postObs(raider, "post2", "signedup", start - 1800, start + 21600)
    local c = client("B-R")  -- unrelated client: observations are shared, credit is per char
    assert.equal(1, counted(derive(c), "Raider-R"))
  end)

  it("uncounted rows go only to the deriving client's own chars", function()
    local raider, other = client("Raider-R"), client("A-R")
    local now = clock.now()
    postObs(raider, "post1", "signedup", now - 600, now + 3600)
    local mine = derive(raider)
    assert.equal(1, #mine)
    assert.is_false(mine[1].counted)
    assert.equal(0, #derive(other))
  end)
end)
