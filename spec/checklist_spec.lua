describe("Groups Checklist", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, bus, ranks, loaded, cfgStore, obsStore, kills, clients, items, unenchanted, zone
  local DAY = 86400
  local TEN_YEARS = 345600000
  local TWO_YEARS = 63072000
  local POTION, MC = 6049, { 663, 664 }

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
  local killObs = {
    List = function(_, kind) if kind == "kill" then return kills end return {} end,
  }

  -- One character's client over the shared core.config and observation stores.
  local function client(char, db)
    local c = { char = char }
    local profileId = "p" .. char:match("^[^-]+")
    local log = ns.Log.new({}, clock.now, function() return "" end)
    c.compat = {
      ServerOffset = function() return 0 end,
      ItemCount = function(_, id) return items[id] end,
      UnenchantedSlots = function() return unenchanted end,
      InstanceKey = function() return zone end,
    }
    c.profile = {
      Id = function() return profileId end,
      IsExcluded = function() return false end,
      OwnerOf = linked.OwnerOf,
      OnlineChar = function() return nil end,
      CharsOf = function() return { char } end,
      set = { Get = function() return nil end },
    }
    local comm = bus:join(char)
    c.cfg = ns.LbConfig.new({ comm = comm, now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = log, roster = roster, profile = c.profile, compat = c.compat, playerChar = char, db = cfgStore })
    c.obs = ns.Observations.New({ comm = comm, now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = log, roster = roster, profile = c.profile, playerChar = char,
      db = obsStore })
    c.db = db or {}
    c.cl = ns.Groups.Checklist.new({ config = c.cfg, observations = c.obs, compat = c.compat, now = clock.now,
      playerChar = char, db = c.db })
    clients[char] = c
    return c
  end

  local function grant(map)
    local gm = clients["Gm-R"] or client("Gm-R")
    assert.is_true((gm.cfg.perms:Publish(map)))
  end

  local function derive(c)
    local ctx = { roster = roster, config = c.cfg, compat = c.compat, now = clock.now, observations = killObs }
    return ns.Activity.Deriver("prepared")(c.obs:List("prepared"), ctx)
  end

  local function prepared(out, char)
    local n = 0
    for _, x in ipairs(out) do
      if x.type == "groups.prepared" and x.counted and x.char == char then n = n + x.value end
    end
    return n
  end

  -- A verified kill today in Molten Core: two reports naming leader and assistants.
  local seq = 0
  local function verifiedKill(at, leader, assists)
    for i, by in ipairs({ "pA", "pB" }) do
      seq = seq + 1
      kills[#kills + 1] = { id = "k" .. seq, by = by, char = by:sub(2) .. "-R",
        d = { kind = "kill", instance = "mc", encounter = MC[1], at = at + i,
          members = { "A-R", "B-R", "Raider-R", leader }, leader = leader, assists = assists } }
    end
  end

  local function hist(c, what)
    local out = {}
    for _, e in ipairs(c.cfg:History()) do if e.what == (what or "checklist") then out[#out + 1] = e end end
    return out
  end

  local LIST = { instance = "mc", name = "Fire potions", lines = { { kind = "item", item = POTION, count = 5 } } }

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
    loadAddonFile(ns, "Guildhall/Modules/Groups/Checklist.lua")
    clock = fakes.clock(utc(2026, 11, 4, 20))
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    ranks = { ["Gm-R"] = 0, ["Off-R"] = 1, ["Asst-R"] = 4, ["Mem-R"] = 5, ["Raider-R"] = 5, ["A-R"] = 5, ["B-R"] = 5 }
    loaded = true
    cfgStore, obsStore, kills, clients = {}, {}, {}, {}
    items, unenchanted, zone = {}, {}, nil
    ns.Groups.Credit.Attach({ observations = killObs, config = nil, now = clock.now,
      compat = { ServerOffset = function() return 0 end }, profile = linked })
  end)

  -- The brief's six tests ------------------------------------------------------------------

  it("a member without 'checklists' can't save; an officer can, and history records it", function()
    grant({ checklists = { ranks = { 1 }, raidlead = false } })
    local mem = client("Mem-R")
    local ok, err = mem.cl:Save(LIST)
    assert.is_false(ok)
    assert.equal("no permission", err)
    assert.same({}, mem.cl:List("mc"))
    assert.same({}, hist(mem))

    local off = client("Off-R")
    local good, id = off.cl:Save(LIST)
    assert.is_true(good)
    assert.equal("checklist:mc:fire_potions", id)
    local got = off.cl:Get(id)
    assert.equal("Fire potions", got.name)
    assert.same(LIST.lines, got.lines)
    local h = hist(off)
    local saved
    for _, e in ipairs(h) do if e.key == id and e.after and e.after.name then saved = e end end
    assert.is_not_nil(saved)
    assert.equal("Off-R", saved.by)
    assert.same({ name = "Fire potions" }, saved.before)
    assert.same({ name = "Fire potions", lines = LIST.lines }, saved.after)
    -- the first saved checklist of an instance is its default
    assert.equal(id, off.cl:Default("mc").id)
  end)

  it("SelfCheck reports 2 of 5 potions and missing Legs enchant", function()
    local c = client("Raider-R")
    items[POTION] = 2
    unenchanted = { "Legs" }
    local r = c.cl:SelfCheck({ id = "checklist:mc:x", instance = "mc", name = "x", lines = {
      { kind = "item", item = POTION, count = 5 }, { kind = "enchants" }, { kind = "manual", text = "World buffs" },
    } })
    assert.is_false(r.ok)
    assert.same({ ok = false, have = 2, need = 5 }, r.lines[1])
    assert.is_false(r.lines[2].ok)
    assert.same({ "Legs" }, r.lines[2].missing)
    assert.is_nil(r.lines[3].ok)
    assert.equal(2, r.miss)

    items[POTION], unenchanted = 7, {}
    r = c.cl:SelfCheck({ lines = { { kind = "item", item = POTION, count = 5 }, { kind = "enchants" },
      { kind = "manual", text = "World buffs" } } })
    assert.is_true(r.ok)
    assert.equal(0, r.miss)
  end)

  it("self-check runs once per instance per day", function()
    grant({ checklists = { ranks = { 1 }, raidlead = false } })
    local off = client("Off-R")
    assert.is_true((off.cl:Save(LIST)))
    local db = {}
    local raider = client("Raider-R", db)
    items[POTION] = 1
    assert.is_true(raider.cl:OnReadyCheck({ instance = "mc" }))
    assert.is_false(raider.cl:OnReadyCheck({ instance = "mc" }))
    zone = 409 -- Molten Core
    assert.is_false(raider.cl:OnZone())
    local checks = raider.obs:List("prepcheck")
    assert.equal(1, #checks)
    local d = checks[1].d
    assert.equal("mc", d.instance)
    assert.equal("checklist:mc:fire_potions", d.list)
    assert.is_false(d.ok)
    assert.equal(1, d.miss)
    -- persisted in the module db: a rebuilt client still knows
    local again = client("Raider-R", db)
    assert.is_false(again.cl:OnZone())
    clock.advance(DAY)
    assert.is_true(again.cl:OnZone())
    assert.equal(2, #raider.obs:List("prepcheck"))
    -- no active checklist: nothing to check
    zone = 469
    assert.is_false(again.cl:OnZone())
  end)

  it("only a permitted confirmation earns prepared; a self-report alone earns nothing", function()
    grant({ prepared = { ranks = { 1 }, raidlead = false }, checklists = { ranks = { 1 }, raidlead = false } })
    local off = client("Off-R")
    assert.is_true((off.cl:Save(LIST)))
    local raider = client("Raider-R")
    items[POTION] = 9
    assert.is_true(raider.cl:OnReadyCheck({ instance = "mc" }))
    assert.is_true(raider.obs:List("prepcheck")[1].d.ok)
    assert.equal(0, prepared(derive(raider), "Raider-R"))

    -- the raider confirming themself is refused locally, and a forged confirmation earns nothing
    local ok, err = raider.cl:Confirm("Raider-R", "mc", true)
    assert.is_false(ok)
    assert.equal("no permission", err)
    assert.equal("accepted", (raider.obs:Publish({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = true,
      at = clock.now() })))
    assert.equal(0, prepared(derive(raider), "Raider-R"))

    clock.advance(5)
    assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
    -- no verified kill tonight: nothing yet
    assert.equal(0, prepared(derive(raider), "Raider-R"))
    verifiedKill(clock.now() - 600, "Gm-R", {})
    local out = derive(raider)
    assert.equal(1, prepared(out, "Raider-R"))
    assert.equal(1, #out)
  end)

  it("a raid assistant with raidlead grant can confirm only on a night they led a verified kill", function()
    grant({ prepared = { ranks = { 1 }, raidlead = true } })
    local asst = client("Asst-R")
    local ok, err = asst.cl:Confirm("Raider-R", "mc", true)
    assert.is_false(ok)
    assert.equal("no permission", err)
    -- forged: published anyway, it earns nothing without a verified kill they led that night
    asst.obs:Publish({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = true, at = clock.now() })
    assert.equal(0, prepared(derive(asst), "Raider-R"))

    verifiedKill(clock.now() - 600, "Gm-R", { "Asst-R" })
    assert.equal(1, prepared(derive(asst), "Raider-R"))
    clock.advance(10)
    assert.is_true((asst.cl:Confirm("Raider-R", "mc", true)))
    assert.equal(1, prepared(derive(asst), "Raider-R"))

    -- the next night they led nothing
    clock.advance(DAY)
    assert.is_false((asst.cl:Confirm("Raider-R", "mc", true)))
    -- and an assistant named by only one report doesn't count
    verifiedKill(clock.now() - 600, "Gm-R", {})
    kills[#kills].d.assists = { "Asst-R" }
    assert.is_false((asst.cl:Confirm("Raider-R", "mc", true)))
  end)

  it("the newest confirmation wins (untick after tick removes credit)", function()
    grant({ prepared = { ranks = { 1 }, raidlead = false } })
    local off = client("Off-R")
    verifiedKill(clock.now() - 600, "Gm-R", {})
    assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
    assert.equal(1, prepared(derive(off), "Raider-R"))
    clock.advance(10)
    assert.is_true((off.cl:Confirm("Raider-R", "mc", false)))
    assert.equal(0, prepared(derive(off), "Raider-R"))
    clock.advance(10)
    assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
    assert.equal(1, prepared(derive(off), "Raider-R"))
    -- a newer untick from someone not permitted changes nothing
    clock.advance(10)
    local mem = client("Mem-R")
    mem.obs:Publish({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = false, at = clock.now() })
    assert.equal(1, prepared(derive(off), "Raider-R"))
    -- an author who left the guild is not permitted when deriving
    ranks["Off-R"] = nil
    assert.equal(0, prepared(derive(off), "Raider-R"))
  end)

  -- Records, defaults, history ---------------------------------------------------------------

  describe("records", function()
    local function crec(id, v, char, d, t)
      t = t or clock.now()
      local data = { instance = "mc", name = "Fire", lines = { { kind = "enchants" } }, by = char, at = t }
      for k, val in pairs(d or {}) do data[k] = val end
      return { id = id, v = v, t = t, exp = t + TEN_YEARS, by = "pX", char = char, d = data }
    end
    local function drec(instance, target, v, char, t)
      t = t or clock.now()
      return { id = "checklistdefault:" .. instance, v = v, t = t, exp = t + TEN_YEARS, by = "pX", char = char,
        d = { instance = instance, id = target, by = char, at = t } }
    end
    local c
    local function apply(r) return c.cfg.sync:_applyOne(r, "Sender") end
    local function reason() local q = c.cfg.log:Query(); return q[1] and q[1].reason end

    before_each(function()
      grant({ checklists = { ranks = { 1 }, raidlead = true } })
      c = client("Mem-R")
    end)

    it("an incoming checklist is accepted from a permitted author and rejected otherwise", function()
      assert.equal("invalid", apply(crec("checklist:mc:fire", 1, "Mem-R")))
      assert.equal("author lacks permission", reason())
      assert.equal("accepted", apply(crec("checklist:mc:fire", 1, "Off-R")))
      assert.equal("Fire", c.cl:Get("checklist:mc:fire").name)
      assert.equal("accepted", apply(drec("mc", "checklist:mc:fire", 1, "Off-R")))
      assert.equal("checklist:mc:fire", c.cl:Default("mc").id)
      assert.equal("invalid", apply(drec("bwl", "checklist:bwl:x", 1, "Mem-R")))
    end)

    it("an unknown roster rejects now, accepts later; an author who left is accepted", function()
      loaded = false
      local r = crec("checklist:mc:fire", 1, "Off-R")
      assert.equal("invalid", apply(r))
      assert.equal("roster unknown", reason())
      loaded = true
      assert.equal("accepted", apply(r))
      assert.equal("accepted", apply(crec("checklist:mc:gone", 1, "Gone-R")))
      assert.equal("author left the guild", c.cfg.log:Query()[1].reason)
    end)

    it("a raidlead-only author is accepted only for a day they led a verified kill", function()
      assert.equal("invalid", apply(crec("checklist:mc:a", 1, "Asst-R")))
      verifiedKill(clock.now() - 600, "Gm-R", { "Asst-R" })
      assert.equal("accepted", apply(crec("checklist:mc:a", 1, "Asst-R")))
      -- a record stamped the next day is checked against that day
      assert.equal("invalid", apply(crec("checklist:mc:b", 1, "Asst-R", nil, clock.now() + DAY)))
    end)

    it("rejects malformed checklist and default records", function()
      local bad = {
        crec("checklist:mc:Fire", 1, "Off-R"),                         -- slug not lower case
        crec("checklist:mc:", 1, "Off-R"),                             -- empty slug
        crec("checklist:mc:abcdefghijklmnopq", 1, "Off-R"),            -- 17-char slug
        crec("checklist:nope:fire", 1, "Off-R", { instance = "nope" }), -- unknown instance
        crec("checklist:mc:fire", 1, "Off-R", { instance = "bwl" }),   -- instance mismatch
        crec("checklist:mc:fire", 1, "Off-R", { extra = 1 }),          -- unknown field
        crec("checklist:mc:fire", 1, "Off-R", { name = string.rep("x", 33) }),
        crec("checklist:mc:fire", 1, "Off-R", { name = "" }),
        crec("checklist:mc:fire", 1, "Off-R", { by = "Gm-R" }),        -- by must be the author
        crec("checklist:mc:fire", 1, "Off-R", { at = clock.now() - 1 }),
        crec("checklist:mc:fire", 1, "Off-R", { deleted = "yes" }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = "x" }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = { { kind = "item", item = POTION, count = 201 } } }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = { { kind = "item", item = POTION, count = 0 } } }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = { { kind = "manual", text = string.rep("x", 65) } } }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = { { kind = "enchants", x = 1 } } }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = { { kind = "bogus" } } }),
        crec("checklist:mc:fire", 1, "Off-R", { lines = { [2] = { kind = "enchants" } } }),
        drec("mc", "checklist:bwl:fire", 1, "Off-R"),                  -- default for another instance
        drec("mc", "nonsense", 1, "Off-R"),
      }
      local thirteen = {}
      for i = 1, 13 do thirteen[i] = { kind = "enchants" } end
      bad[#bad + 1] = crec("checklist:mc:fire", 1, "Off-R", { lines = thirteen })
      local noexp = crec("checklist:mc:fire", 1, "Off-R"); noexp.exp = noexp.exp - 1
      bad[#bad + 1] = noexp
      local del = crec("checklist:mc:fire", 1, "Off-R"); del.del = true
      bad[#bad + 1] = del
      local extraDefault = drec("mc", "checklist:mc:fire", 1, "Off-R"); extraDefault.d.name = "x"
      bad[#bad + 1] = extraDefault
      for i, r in ipairs(bad) do
        assert.equal("invalid", apply(r), "case " .. i)
      end
      local twelve = {}
      for i = 1, 12 do twelve[i] = { kind = "manual", text = string.rep("x", 64) } end
      assert.equal("accepted", apply(crec("checklist:mc:abcdefghijklmnop", 1, "Off-R",
        { name = string.rep("x", 32), lines = twelve })))
    end)

    it("checklist ids sync in bucket c and are tracked by the version floor", function()
      assert.equal("c", ns.LbConfig.Bucket({ id = "checklist:mc:fire" }))
      assert.equal("c", ns.LbConfig.Bucket({ id = "checklistdefault:mc" }))
      assert.equal("invalid", apply(crec("checklist:mc:fire", 4, "Mem-R")))
      assert.equal(4, c.cfg.seenV["checklist:mc:fire"])
      assert.equal("invalid", apply(drec("mc", "checklist:mc:fire", 3, "Mem-R")))
      assert.equal(3, c.cfg.seenV["checklistdefault:mc"])
      local off = client("Off-R")
      off.cfg.seenV["checklist:mc:fire"] = 4
      local ok = off.cl:Save({ id = "checklist:mc:fire", instance = "mc", name = "Fire", lines = {} })
      assert.is_true(ok)
      assert.equal(5, off.cfg.set:Get("checklist:mc:fire").v)
    end)
  end)

  describe("writing", function()
    local off
    before_each(function()
      grant({ checklists = { ranks = { 1 }, raidlead = true } })
      off = client("Off-R")
    end)

    it("a taken slug gets a numeric suffix", function()
      local _, a = off.cl:Save(LIST)
      local _, b = off.cl:Save(LIST)
      local _, c = off.cl:Save({ instance = "mc", name = "A very long checklist name!", lines = {} })
      local _, d = off.cl:Save({ instance = "mc", name = "!!!", lines = {} })
      assert.equal("checklist:mc:fire_potions", a)
      assert.equal("checklist:mc:fire_potions_2", b)
      assert.equal("checklist:mc:a_very_long_chec", c)
      assert.equal("checklist:mc:list", d)
      assert.equal(4, #off.cl:List("mc"))
    end)

    it("Save refuses a bad payload and saving an unchanged checklist publishes nothing", function()
      assert.is_false((off.cl:Save({ instance = "nope", name = "x", lines = {} })))
      assert.is_false((off.cl:Save({ instance = "mc", name = string.rep("x", 33), lines = {} })))
      assert.is_false((off.cl:Save({ instance = "mc", name = "x", lines = { { kind = "item", item = 1, count = 0 } } })))
      assert.is_false((off.cl:Save({ id = "checklist:bwl:x", instance = "mc", name = "x", lines = {} })))
      local _, id = off.cl:Save(LIST)
      local v = off.cfg.set:Get(id).v
      local n = #hist(off)
      assert.is_true((off.cl:Save({ id = id, instance = "mc", name = "Fire potions", lines = LIST.lines })))
      assert.equal(v, off.cfg.set:Get(id).v)
      assert.equal(n, #hist(off))
      -- an edit logs only the changed keys
      assert.is_true((off.cl:Save({ id = id, instance = "mc", name = "Fire pots", lines = LIST.lines })))
      local e = hist(off)[1]
      assert.equal(id, e.key)
      assert.same({ name = "Fire potions" }, e.before)
      assert.same({ name = "Fire pots" }, e.after)
      -- a lines-only edit still carries the name on both sides
      assert.is_true((off.cl:Save({ id = id, instance = "mc", name = "Fire pots", lines = { { kind = "enchants" } } })))
      e = hist(off)[1]
      assert.same({ name = "Fire pots", lines = LIST.lines }, e.before)
      assert.same({ name = "Fire pots", lines = { { kind = "enchants" } } }, e.after)
    end)

    it("Delete publishes deleted = true, logs it, and moves the default", function()
      local _, a = off.cl:Save(LIST)
      local _, b = off.cl:Save({ instance = "mc", name = "Backup", lines = {} })
      assert.equal(a, off.cl:Default("mc").id)
      assert.is_true((off.cl:Delete(a)))
      local rec = off.cfg.set:Get(a)
      assert.is_true(rec.d.deleted)
      assert.is_nil(rec.del)
      assert.is_nil(off.cl:Get(a))
      assert.equal(1, #off.cl:List("mc"))
      assert.equal(b, off.cl:Default("mc").id)
      local found
      for _, e in ipairs(hist(off)) do
        if e.key == a and e.after.deleted == true then found = e end
      end
      assert.is_not_nil(found)
      assert.same({ name = "Fire potions", deleted = false }, found.before)
      assert.same({ name = "Fire potions", deleted = true }, found.after)
      assert.is_false((off.cl:Delete(a)))
      assert.is_false((client("Mem-R").cl:Delete(b)))
    end)

    it("SetDefault needs the permission, a live checklist of the instance, and logs it", function()
      local _, a = off.cl:Save(LIST)
      local _, b = off.cl:Save({ instance = "mc", name = "Backup", lines = {} })
      assert.is_false((client("Mem-R").cl:SetDefault("mc", b)))
      assert.is_false((off.cl:SetDefault("bwl", b)))
      assert.is_false((off.cl:SetDefault("mc", "checklist:mc:nope")))
      assert.is_true((off.cl:SetDefault("mc", b)))
      assert.equal(b, off.cl:Default("mc").id)
      local e = hist(off)[1]
      assert.equal(b, e.key)
      assert.same({ name = "Backup", default = false }, e.before)
      assert.same({ name = "Backup", default = true }, e.after)
      assert.is_not_nil(a)
    end)

    it("Active returns the checklist a post or event picked, else the default", function()
      local _, a = off.cl:Save(LIST)
      local _, b = off.cl:Save({ instance = "mc", name = "Backup", lines = {} })
      assert.equal(a, off.cl:Active("mc").id)
      assert.equal(b, off.cl:Active("mc", { checklist = b }).id)
      assert.equal(b, off.cl:Active("mc", { d = { checklist = b } }).id)
      assert.equal(a, off.cl:Active("mc", { checklist = "checklist:bwl:x" }).id)
      assert.is_nil(off.cl:Active("bwl"))
    end)

    it("a raidlead-only grantee can save only on a night they led a verified kill", function()
      local asst = client("Asst-R")
      assert.is_false((asst.cl:Save(LIST)))
      verifiedKill(clock.now() - 600, "Gm-R", { "Asst-R" })
      assert.is_true((asst.cl:Save(LIST)))
      assert.is_true((asst.cl:Save({ instance = "bwl", name = "x", lines = {} })) == false)
    end)
  end)

  describe("fix round 1", function()
    it("every rendered history line names the checklist, never its id", function()
      ns.UI = ns.UI or {}
      loadAddonFile(ns, "Guildhall/Core/UI/HistoryView.lua")
      local D = ns.UI.HistoryView.Describe
      grant({ checklists = { ranks = { 1 }, raidlead = false } })
      local off = client("Off-R")
      local _, a = off.cl:Save(LIST)
      local _, b = off.cl:Save({ instance = "mc", name = "Backup", lines = {} })
      clock.advance(5)
      off.cl:Save({ id = a, instance = "mc", name = "Fire potions", lines = { { kind = "enchants" } } })
      off.cl:Save({ id = a, instance = "mc", name = "Fire pots", lines = { { kind = "enchants" } } })
      off.cl:SetDefault("mc", b)
      off.cl:Delete(b)
      off.cl:Delete(a)
      local entries, lines = hist(off), 0
      assert.is_true(#entries >= 7)
      for _, e in ipairs(entries) do
        assert.is_string(e.before.name, e.key)
        assert.is_string(e.after.name, e.key)
        for _, line in ipairs(D(e)) do
          lines = lines + 1
          assert.is_nil(line:find("checklist:", 1, true), line)
        end
      end
      assert.is_true(lines >= 5)
    end)

    it("a confirmation backdated to a night the raider wasn't at the kill earns nothing (P2)", function()
      grant({ prepared = { ranks = { 1 }, raidlead = true } })
      local asst = client("Asst-R")
      local dayX = clock.now()
      verifiedKill(dayX - 600, "Gm-R", { "Asst-R" })
      clock.advance(3 * DAY)
      asst.obs:Publish({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = true, at = clock.now() })
      assert.equal(0, prepared(derive(asst), "Raider-R"))
      asst.obs:Publish({ kind = "prepared", raider = "Nobody-R", instance = "mc", ok = true, at = dayX })
      assert.equal(0, prepared(derive(asst), "Nobody-R"))
      -- an honest confirmation of a raider at that night's kill still counts
      asst.obs:Publish({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = true, at = dayX })
      assert.equal(1, prepared(derive(asst), "Raider-R"))
    end)

    it("a confirmation at 23:40 counts for kills after midnight; one 7 h before any kill doesn't", function()
      grant({ prepared = { ranks = { 1 }, raidlead = false } })
      local off = client("Off-R")
      clock.advance(3 * 3600 + 40 * 60) -- 23:40 server time
      local confirmAt = clock.now()
      assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
      verifiedKill(confirmAt + 30 * 60, "Gm-R", {}) -- 00:10, the next server day
      local out = derive(off)
      assert.equal(1, prepared(out, "Raider-R"))
      local killDay = ns.Scoring.DayKey(confirmAt + 30 * 60, 0)
      assert.equal("prepared:mc:" .. killDay .. ":Raider-R", out[1].ref)
      -- a second confirmation the same night (after midnight) is still one per night
      clock.advance(40 * 60)
      assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
      assert.equal(1, prepared(derive(off), "Raider-R"))
      assert.equal(1, #derive(off))
    end)

    it("a confirmation 7 h before any kill earns nothing", function()
      grant({ prepared = { ranks = { 1 }, raidlead = false } })
      local off = client("Off-R")
      assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
      verifiedKill(clock.now() + 7 * 3600, "Gm-R", {})
      assert.equal(0, prepared(derive(off), "Raider-R"))
    end)

    it("a raidlead-only assistant's 23:40 confirmation counts when they led the kills after midnight", function()
      grant({ prepared = { ranks = { 1 }, raidlead = true } })
      local asst = client("Asst-R")
      clock.advance(3 * 3600 + 40 * 60)
      local at = clock.now()
      asst.obs:Publish({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = true, at = at })
      verifiedKill(at + 30 * 60, "Gm-R", { "Asst-R" })
      assert.equal(1, prepared(derive(asst), "Raider-R"))
    end)

    it("a raider named by only one report of the kill is not credited", function()
      grant({ prepared = { ranks = { 1 }, raidlead = false } })
      local off = client("Off-R")
      verifiedKill(clock.now() - 600, "Gm-R", {})
      kills[#kills].d.members = { "A-R", "B-R", "Gm-R", "Solo-R" }
      kills[#kills - 1].d.members = { "A-R", "B-R", "Gm-R" }
      assert.is_true((off.cl:Confirm("Solo-R", "mc", true)))
      assert.equal(0, prepared(derive(off), "Solo-R"))
      -- a kill in another instance that night doesn't count either
      assert.is_true((off.cl:Confirm("A-R", "bwl", true)))
      assert.equal(0, prepared(derive(off), "A-R"))
    end)

    it("no prepcheck is published when no automatic line could be read", function()
      grant({ checklists = { ranks = { 1 }, raidlead = false } })
      local off = client("Off-R")
      assert.is_true((off.cl:Save({ instance = "mc", name = "Buffs", lines = { { kind = "manual", text = "Ony buff" } } })))
      local raider = client("Raider-R")
      local ok, err = raider.cl:OnReadyCheck({ instance = "mc" })
      assert.is_false(ok)
      assert.equal("nothing to check", err)
      assert.equal(0, #raider.obs:List("prepcheck"))
      assert.is_nil(raider.cl:SelfCheck(off.cl:Default("mc")).ok)

      -- item and enchants unreadable (secret): nothing published, and the day is not used up
      local _, id = off.cl:Save({ instance = "mc", name = "Full", lines = { { kind = "item", item = POTION, count = 5 },
        { kind = "enchants" }, { kind = "manual", text = "x" } } })
      assert.is_true((off.cl:SetDefault("mc", id)))
      items[POTION], unenchanted = nil, nil
      assert.is_false((raider.cl:OnReadyCheck({ instance = "mc" })))
      assert.equal(0, #raider.obs:List("prepcheck"))
      -- one readable line that passes, one unknown: ok = true, miss = 0
      items[POTION] = 5
      assert.is_true((raider.cl:OnReadyCheck({ instance = "mc" })))
      local d = raider.obs:List("prepcheck")[1].d
      assert.is_true(d.ok)
      assert.equal(0, d.miss)
    end)

    it("a published prepcheck with ok = false has miss >= 1", function()
      grant({ checklists = { ranks = { 1 }, raidlead = false } })
      local off = client("Off-R")
      assert.is_true((off.cl:Save({ instance = "mc", name = "Full", lines = {
        { kind = "item", item = POTION, count = 5 }, { kind = "enchants" } } })))
      local raider = client("Raider-R")
      items[POTION], unenchanted = 1, nil
      assert.is_true((raider.cl:OnReadyCheck({ instance = "mc" })))
      local d = raider.obs:List("prepcheck")[1].d
      assert.is_false(d.ok)
      assert.equal(1, d.miss)
    end)
  end)

  -- Observation validators ----------------------------------------------------------------

  it("prepcheck and prepared observations are strictly validated", function()
    local V = ns.Observations.Validate
    local at = clock.now()
    assert.is_true(V({ kind = "prepcheck", instance = "mc", list = "checklist:mc:fire", ok = true, miss = 0, at = at }))
    assert.is_true(V({ kind = "prepared", raider = "Raider-R", instance = "mc", ok = false, at = at }))
    local bad = {
      { kind = "prepcheck", instance = "nope", list = "checklist:mc:fire", ok = true, miss = 0, at = at },
      { kind = "prepcheck", instance = "mc", list = "checklist:bwl:fire", ok = true, miss = 0, at = at },
      { kind = "prepcheck", instance = "mc", list = "checklist:mc:fire", ok = "yes", miss = 0, at = at },
      { kind = "prepcheck", instance = "mc", list = "checklist:mc:fire", ok = true, miss = 13, at = at },
      { kind = "prepcheck", instance = "mc", list = "checklist:mc:fire", ok = true, miss = -1, at = at },
      { kind = "prepcheck", instance = "mc", list = "checklist:mc:fire", ok = true, miss = 0, at = at, x = 1 },
      { kind = "prepcheck", instance = "mc", ok = true, miss = 0, at = at },
      { kind = "prepared", raider = "", instance = "mc", ok = true, at = at },
      { kind = "prepared", instance = "mc", ok = true, at = at },
      { kind = "prepared", raider = "Raider-R", instance = "nope", ok = true, at = at },
      { kind = "prepared", raider = "Raider-R", instance = "mc", ok = 1, at = at },
      { kind = "prepared", raider = "Raider-R", instance = "mc", ok = true, at = at, note = "x" },
    }
    for i, d in ipairs(bad) do assert.is_false((V(d)), "case " .. i) end
  end)

  it("Confirm refuses a bad raider, instance or ok", function()
    grant({ prepared = { ranks = { 1 }, raidlead = false } })
    local off = client("Off-R")
    assert.is_false((off.cl:Confirm("", "mc", true)))
    assert.is_false((off.cl:Confirm("Raider-R", "nope", true)))
    assert.is_false((off.cl:Confirm("Raider-R", "mc", "yes")))
    assert.equal(0, #off.obs:List("prepared"))
  end)

  it("Checklist.lua is in both TOCs right after Credit.lua", function()
    for _, path in ipairs({ "Guildhall/Guildhall.toc", "Guildhall/Guildhall_Vanilla.toc" }) do
      local f = assert(io.open(path))
      local text = f:read("*a")
      f:close()
      assert.truthy(text:find("Modules/Groups/Credit.lua\r?\nModules/Groups/Checklist.lua"), path)
    end
  end)

  it("Night shows tonight's own checks and the newest confirmation per raider", function()
    grant({ prepared = { ranks = { 1 }, raidlead = false }, checklists = { ranks = { 1 }, raidlead = false } })
    local off = client("Off-R")
    assert.is_true((off.cl:Save(LIST)))
    local raider = client("Raider-R")
    items[POTION] = 2
    assert.is_true(raider.cl:OnReadyCheck({ instance = "mc" }))
    assert.same({ ["Raider-R"] = { ok = false, miss = 1 } }, off.cl:Night("mc"))
    assert.is_true((off.cl:Confirm("Raider-R", "mc", true)))
    clock.advance(5)
    assert.is_true((off.cl:Confirm("Raider-R", "mc", false)))
    clock.advance(5)
    assert.is_true((off.cl:Confirm("Mem-R", "mc", true)))
    local night = off.cl:Night("mc")
    assert.is_false(night["Raider-R"].confirmed)
    assert.is_true(night["Mem-R"].confirmed)
    assert.same({}, off.cl:Night("bwl"))
    clock.advance(DAY)
    assert.same({}, off.cl:Night("mc"))
  end)

  it("ConfirmTicks publishes checked or changed boxes of guild members that differ from tonight's newest", function()
    grant({ prepared = { ranks = { 1 }, raidlead = false } })
    local off = client("Off-R")
    assert.is_true((off.cl:Confirm("A-R", "mc", true)))
    clock.advance(5)
    local n, err = off.cl:ConfirmTicks("mc", {
      ["A-R"] = { checked = true, changed = false },     -- already confirmed: nothing
      ["B-R"] = { checked = false, changed = false },    -- unticked and untouched: nothing
      ["Raider-R"] = { checked = true, changed = false }, -- pre-ticked: confirmed
      ["Mem-R"] = { checked = false, changed = true },    -- unticked by the leader: confirmed false
      ["Pug-R"] = { checked = true, changed = true },     -- not in the guild: skipped
    })
    assert.equal(2, n)
    assert.is_nil(err)
    local night = off.cl:Night("mc")
    assert.is_true(night["Raider-R"].confirmed)
    assert.is_false(night["Mem-R"].confirmed)
    assert.is_nil(night["B-R"])
    assert.is_nil(night["Pug-R"])
    -- without permission nothing is published and the reason is returned
    local mem = client("Mem-R")
    local n2, err2 = mem.cl:ConfirmTicks("mc", { ["B-R"] = { checked = true } })
    assert.equal(0, n2)
    assert.equal("no permission", err2)
  end)
end)
