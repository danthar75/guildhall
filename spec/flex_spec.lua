describe("Groups Flex", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, bus, ranks, loaded, cfgStore, obsStore, kills, clients, spec
  local DAY = 86400
  local MC = { 663, 664 }

  local function utc(y, m, d, h)
    local a = math.floor((14 - m) / 12)
    y, m = y + 4800 - a, m + 12 * a - 3
    local jdn = d + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100)
      + math.floor(y / 400) - 32045
    return (jdn - 2440588) * 86400 + (h or 0) * 3600
  end

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

  local function client(char, db)
    local c = { char = char }
    local log = ns.Log.new({}, clock.now, function() return "" end)
    c.compat = {
      ServerOffset = function() return 0 end,
      ActiveSpecGroup = function() return spec end,
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
    c.fx = ns.Groups.Flex.new({ config = c.cfg, observations = c.obs, compat = c.compat, now = clock.now,
      playerChar = char, profile = c.profile, db = c.db })
    clients[char] = c
    return c
  end

  local function grant(map)
    local gm = clients["Gm-R"] or client("Gm-R")
    assert.is_true((gm.cfg.perms:Publish(map)))
  end

  local function derive(c)
    local all = { List = function(_, kind)
      if kind == "kill" then return kills end
      return c.obs:List(kind)
    end }
    local ctx = { roster = roster, config = c.cfg, compat = c.compat, now = clock.now, observations = all,
      profile = c.profile }
    return ns.Activity.Deriver("flexask")(c.obs:List("flexask"), ctx)
  end

  local function counted(out, char)
    local n = 0
    for _, x in ipairs(out) do
      if x.type == "groups.flex" and x.counted and x.char == char then n = n + x.value end
    end
    return n
  end

  local seq = 0
  local function verifiedKill(at, leader, assists, members)
    for i, by in ipairs({ "pA", "pB" }) do
      seq = seq + 1
      kills[#kills + 1] = { id = "k" .. seq, by = by, char = by:sub(2) .. "-R",
        d = { kind = "kill", instance = "mc", encounter = MC[1], at = at + i,
          members = members or { "A-R", "B-R", "Raider-R", leader }, leader = leader, assists = assists } }
    end
  end

  local function setup()
    grant({ flex = { ranks = { 1 }, raidlead = false } })
    verifiedKill(clock.now() - 600, "Gm-R", {})
    spec = 1
    local raider = client("Raider-R")
    local off = client("Off-R")
    return raider, off
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
    loadAddonFile(ns, "Guildhall/Modules/Groups/Flex.lua")
    clock = fakes.clock(utc(2026, 11, 4, 20))
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    ranks = { ["Gm-R"] = 0, ["Off-R"] = 1, ["Mem-R"] = 5, ["Raider-R"] = 5, ["A-R"] = 5, ["B-R"] = 5 }
    loaded = true
    cfgStore, obsStore, kills, clients, spec = {}, {}, {}, {}, nil
    ns.Groups.Credit.Attach({ observations = killObs, config = nil, now = clock.now,
      compat = { ServerOffset = function() return 0 end }, profile = linked })
  end)

  -- The brief's five tests -------------------------------------------------------------------

  it("ask then a spec change within 15 min counts once", function()
    local raider, off = setup()
    local ok, id = off.fx:Ask("Raider-R", "mc", "need fire res")
    assert.is_true(ok)
    assert.equal(id, off.obs:List("flexask")[1].id)
    assert.equal(0, counted(derive(raider), "Raider-R"))
    clock.advance(300)
    spec = 2
    raider.fx:OnSpecChanged()
    local done = raider.obs:List("flexdone")
    assert.equal(1, #done)
    assert.equal(id, done[1].d.ask)
    local out = derive(raider)
    assert.equal(1, counted(out, "Raider-R"))
    assert.equal("flex:" .. id, out[1].ref)
    -- switching back and forth again publishes nothing more and credits nothing more
    clock.advance(60)
    spec = 1
    raider.fx:OnSpecChanged()
    spec = 2
    raider.fx:OnSpecChanged()
    assert.equal(1, #raider.obs:List("flexdone"))
    assert.equal(1, counted(derive(raider), "Raider-R"))
  end)

  it("a change after 16 min doesn't count", function()
    local raider, off = setup()
    local _, id = off.fx:Ask("Raider-R", "mc")
    clock.advance(960)
    spec = 2
    raider.fx:OnSpecChanged()
    assert.equal(0, #raider.obs:List("flexdone"))
    -- a forged late flexdone earns nothing either
    raider.obs:Publish({ kind = "flexdone", ask = id, at = math.floor(clock.now()) })
    assert.equal(0, counted(derive(raider), "Raider-R"))
  end)

  it("an ask by a member without 'flex' never counts", function()
    local raider = setup()
    local mem = client("Mem-R")
    local ok, err = mem.fx:Ask("Raider-R", "mc")
    assert.is_false(ok)
    assert.equal("no permission", err)
    local st, rec = mem.obs:Publish({ kind = "flexask", raider = "Raider-R", instance = "mc",
      at = math.floor(clock.now()) })
    assert.equal("accepted", st)
    clock.advance(60)
    spec = 2
    raider.fx:OnSpecChanged()
    assert.equal(0, counted(derive(raider), "Raider-R"))
    local row = derive(raider)[1]
    assert.equal("flex:" .. rec.id, row.ref)
    assert.is_false(row.counted)
    assert.equal("not permitted", row.why)
    -- another profile's client doesn't get the raider's uncounted rows
    assert.same({}, derive(client("A-R")))
  end)

  it("without dual spec, the asker's tick counts", function()
    local raider, off = setup()
    local _, id = off.fx:Ask("Raider-R", "mc")
    spec = nil
    raider.fx:OnSpecChanged()
    assert.equal(0, #raider.obs:List("flexdone"))
    local waiting = derive(raider)[1]
    assert.is_false(waiting.counted)
    assert.equal("waiting for the switch", waiting.why)
    assert.is_true(off.fx:Tick(id))
    assert.equal(1, #off.obs:List("flexok"))
    assert.equal(1, counted(derive(raider), "Raider-R"))
  end)

  it("the raider can't tick their own flexok", function()
    local raider, off = setup()
    local _, id = off.fx:Ask("Raider-R", "mc")
    local ok = raider.fx:Tick(id)
    assert.is_false(ok)
    raider.obs:Publish({ kind = "flexok", ask = id, at = math.floor(clock.now()) })
    assert.equal(0, counted(derive(raider), "Raider-R"))
  end)

  -- Validators, tampering, attendance -----------------------------------------------------------

  it("validators are strict", function()
    local V = ns.Observations.Validate
    local at = 1000
    assert.is_true((V({ kind = "flexask", raider = "Raider-R", instance = "mc", note = "x", at = at })))
    assert.is_true((V({ kind = "flexask", raider = "Raider-R", instance = "mc", at = at })))
    assert.is_false((V({ kind = "flexask", raider = "Raider", instance = "mc", at = at })))
    assert.is_false((V({ kind = "flexask", raider = "Raider-R", instance = "nope", at = at })))
    assert.is_false((V({ kind = "flexask", raider = "Raider-R", instance = "mc", note = 5, at = at })))
    assert.is_false((V({ kind = "flexask", raider = "Raider-R", instance = "mc", at = at, extra = 1 })))
    assert.is_false((V({ kind = "flexask", raider = ("x"):rep(70) .. "-R", instance = "mc", at = at })))
    assert.is_true((V({ kind = "flexdone", ask = "pA:o1_1", at = at })))
    assert.is_true((V({ kind = "flexok", ask = "pA:o1_1", at = at })))
    assert.is_false((V({ kind = "flexdone", at = at })))
    assert.is_false((V({ kind = "flexok", ask = 5, at = at })))
    assert.is_false((V({ kind = "flexok", ask = "", at = at })))
    assert.is_false((V({ kind = "flexdone", ask = "a", at = at, raider = "x-R" })))
  end)

  it("asking yourself or your own char is refused", function()
    local _, off = setup()
    local ok, err = off.fx:Ask("Off-R", "mc")
    assert.is_false(ok)
    assert.equal("not yourself", err)
    assert.is_false((off.fx:Ask("Raider-R", "nope")))
    assert.is_false((off.fx:Ask("", "mc")))
    assert.is_false((off.fx:Ask("Raider-R", "mc", ("n"):rep(65))))
  end)

  it("a flexdone or flexok from the wrong profile doesn't count", function()
    local raider, off = setup()
    local a = client("A-R")
    local _, id = off.fx:Ask("Raider-R", "mc")
    local now = math.floor(clock.now())
    a.obs:Publish({ kind = "flexdone", ask = id, at = now })
    a.obs:Publish({ kind = "flexok", ask = id, at = now })
    raider.obs:Publish({ kind = "flexdone", ask = "pOff:o1_1", at = now })
    assert.equal(0, counted(derive(raider), "Raider-R"))
    -- a flexdone before the ask doesn't count
    raider.obs:Publish({ kind = "flexdone", ask = id, at = now - 5000 })
    assert.equal(0, counted(derive(raider), "Raider-R"))
  end)

  it("a raider who wasn't at a verified kill earns nothing and shows no row", function()
    local raider, off = setup()
    kills = {}
    verifiedKill(clock.now() - 600, "Gm-R", {}, { "A-R", "B-R", "Gm-R" })
    local _, id = off.fx:Ask("Raider-R", "mc")
    clock.advance(60)
    spec = 2
    raider.fx:OnSpecChanged()
    assert.equal(1, #raider.obs:List("flexdone"))
    assert.same({}, derive(raider))
    assert.is_not_nil(id)
  end)

  it("a raidlead grant needs a led kill that day", function()
    grant({ flex = { ranks = { 0 }, raidlead = true } })
    verifiedKill(clock.now() - 600, "Gm-R", { "Mem-R" })
    spec = 1
    local raider = client("Raider-R")
    local mem, off = client("Mem-R"), client("Off-R")
    assert.is_true((mem.fx:Ask("Raider-R", "mc")))
    assert.is_false((off.fx:Ask("Raider-R", "mc")))
  end)

  it("a secret spec group publishes nothing", function()
    local _, off = setup()
    off.fx:Ask("Raider-R", "mc")
    spec = nil
    local raider = client("Raider-R")
    raider.fx:OnSpecChanged()
    spec = 2
    raider.fx:OnSpecChanged()   -- nothing known before: the first reading is only remembered
    assert.equal(0, #raider.obs:List("flexdone"))
  end)

  it("two asks in one night count once; asks on two nights count twice", function()
    local raider, off = setup()
    local _, a1 = off.fx:Ask("Raider-R", "mc")
    clock.advance(10)
    local _, a2 = off.fx:Ask("Raider-R", "mc")
    clock.advance(10)
    spec = 2
    raider.fx:OnSpecChanged()
    assert.equal(2, #raider.obs:List("flexdone"))
    local out = derive(raider)
    assert.equal(1, counted(out, "Raider-R"))
    local first, second = out[1], out[2]
    assert.equal("flex:" .. a1, first.ref)
    assert.is_true(first.counted)
    assert.equal("flex:" .. a2, second.ref)
    assert.equal("already credited tonight", second.why)
    -- next night
    clock.advance(DAY)
    verifiedKill(clock.now() - 600, "Gm-R", {})
    off.fx:Ask("Raider-R", "mc")
    clock.advance(10)
    spec = 1
    raider.fx:OnSpecChanged()
    assert.equal(2, counted(derive(raider), "Raider-R"))
  end)

  it("Tick without a profile id is not ready", function()
    local _, off = setup()
    local _, id = off.fx:Ask("Raider-R", "mc")
    off.fx.profile = nil
    local ok, err = off.fx:Tick(id)
    assert.is_false(ok)
    assert.equal("not ready", err)
  end)

  it("Status shows tonight's newest ask per raider, whose it is and whether it is done", function()
    local raider, off = setup()
    local _, id = off.fx:Ask("Raider-R", "mc")
    local st = off.fx:Status("mc")
    assert.same({ ["Raider-R"] = { ask = id, mine = true, done = false } }, st)
    assert.is_false(raider.fx:Status("mc")["Raider-R"].mine)
    clock.advance(60)
    spec = 2
    raider.fx:OnSpecChanged()
    assert.is_true(off.fx:Status("mc")["Raider-R"].done)
    assert.same({}, off.fx:Status("bwl"))
    -- the asker's manual tick also marks it done
    local _, id2 = off.fx:Ask("Mem-R", "mc")
    assert.is_false(off.fx:Status("mc")["Mem-R"].done)
    assert.is_true((off.fx:Tick(id2)))
    assert.is_true(off.fx:Status("mc")["Mem-R"].done)
  end)
end)
