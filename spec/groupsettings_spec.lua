-- Ruling U1b: the group finder guild settings (core.config "groupsettings").
describe("Groups guild settings", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, bus, ranks, loaded, cfgStore, clients
  local TEN_YEARS = 345600000

  local roster = {
    HasRanks = function() return loaded end,
    RankIndex = function(_, n) return ranks[n] end,
    IsOfficer = function(_, n) return ranks[n] ~= nil and ranks[n] <= 1 end,
    IsMember = function(_, n) return ranks[n] ~= nil end,
    ConfigList = function() return {} end,
  }

  local function client(char)
    local c = { char = char }
    local log = ns.Log.new({}, clock.now, function() return "" end)
    c.compat = { ServerOffset = function() return 0 end }
    c.profile = {
      Id = function() return "p" .. char:match("^[^-]+") end,
      IsExcluded = function() return false end,
      OwnerOf = function(_, n) return "p" .. n:match("^[^-]+") end,
      OnlineChar = function() return nil end,
      CharsOf = function() return { char } end,
      set = { Get = function() return nil end },
    }
    c.cfg = ns.LbConfig.new({ comm = bus:join(char), now = clock.now, after = timers.after,
      random = function(lo) return lo end, log = log, roster = roster, profile = c.profile, compat = c.compat,
      playerChar = char, db = cfgStore[char] or {} })
    cfgStore[char] = c.cfg.set.store
    clients[char] = c
    return c
  end

  local function hist(c)
    local out = {}
    for _, e in ipairs(c.cfg:History()) do if e.what == "groups" then out[#out + 1] = e end end
    return out
  end

  before_each(function()
    ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Config.lua")
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Perms.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Credit.lua")
    clock = fakes.clock(1800000000)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    ranks = { ["Gm-R"] = 0, ["Off-R"] = 1, ["Mem-R"] = 5 }
    loaded = true
    cfgStore, clients = {}, {}
  end)

  local function rec(char, v, d, exp)
    local now = clock.now()
    d.by, d.at = d.by or char, d.at or now
    return { id = "groupsettings", v = v, t = now, exp = exp or (now + TEN_YEARS), by = "p" .. char:match("^[^-]+"),
      char = char, d = d }
  end

  it("defaults: calendar raids count with non-guild players, other runs don't", function()
    local mem = client("Mem-R")
    local C = ns.Groups.Credit
    assert.same({ calendar = true, other = false }, C.Settings(mem.cfg))
    assert.same({ calendar = true, other = false }, C.Settings(nil))
    assert.same({ calendar = true, other = false }, C.Settings({}))
  end)

  it("only the guild master can change them; both flip, sync and write history", function()
    local gm, off = client("Gm-R"), client("Off-R")
    local C = ns.Groups.Credit
    assert.is_true(C.CanSetSettings(gm.cfg))
    assert.is_false(C.CanSetSettings(off.cfg))
    local ok, err = C.SetSetting(off.cfg, "other", true)
    assert.is_false(ok)
    assert.equal("no permission", err)
    assert.same({ calendar = true, other = false }, C.Settings(off.cfg))

    assert.is_true((C.SetSetting(gm.cfg, "other", true)))
    assert.same({ calendar = true, other = true }, C.Settings(off.cfg)) -- synced
    assert.is_true((C.SetSetting(gm.cfg, "calendar", false)))
    assert.same({ calendar = false, other = true }, C.Settings(off.cfg))
    local r = off.cfg.set:Get("groupsettings")
    assert.equal(r.t + TEN_YEARS, r.exp)
    local h = hist(off)
    assert.equal(2, #h)
    assert.equal("settings", h[1].key)
    assert.same({ calendar = true, other = true }, h[1].before)
    assert.same({ calendar = false, other = true }, h[1].after)
    assert.same({ calendar = true, other = false }, h[2].before)
    assert.is_true(off.cfg:HistoryAuthorPermitted(h[1]))

    -- the same value again publishes nothing; bad keys and values are refused
    assert.is_true((C.SetSetting(gm.cfg, "other", true)))
    assert.equal(2, #hist(off))
    assert.is_false((C.SetSetting(gm.cfg, "mixed", true)))
    assert.is_false((C.SetSetting(gm.cfg, "other", "yes")))
    -- and back
    assert.is_true((C.SetSetting(gm.cfg, "calendar", true)))
    assert.is_true((C.SetSetting(gm.cfg, "other", false)))
    assert.same({ calendar = true, other = false }, C.Settings(off.cfg))
  end)

  it("a forged record from a non-guild-master is rejected, and so are malformed ones", function()
    local off, mem, gmc = client("Off-R"), client("Mem-R"), client("Gm-R")
    off.cfg.sync:Publish(rec("Off-R", 5, { calendar = false, other = true }))
    assert.is_nil(mem.cfg.set:Get("groupsettings"))
    assert.same({ calendar = true, other = false }, ns.Groups.Credit.Settings(mem.cfg))
    local now = clock.now()
    for _, d in ipairs({
      { calendar = true },                                  -- both are required
      { calendar = true, other = "yes" },
      { calendar = true, other = true, extra = 1 },
      { calendar = true, other = true, by = "Off-R" },
      { calendar = true, other = true, at = now + 1 },
    }) do
      gmc.cfg.sync:Publish(rec("Gm-R", 9, d))
      assert.is_nil(mem.cfg.set:Get("groupsettings"))
    end
    gmc.cfg.sync:Publish(rec("Gm-R", 9, { calendar = true, other = true }, now + 1))
    assert.is_nil(mem.cfg.set:Get("groupsettings"))
    -- a malformed groups history entry is rejected
    local hid = "history:pOff:" .. now .. ":2"
    off.cfg.sync:Publish({ id = hid, v = 1, t = now, exp = now + 63072000, by = "pOff", char = "Off-R",
      d = { what = "groups", key = "settings", before = { calendar = 1, other = true },
        after = { calendar = true, other = true }, by = "Off-R", at = now } })
    assert.is_nil(mem.cfg.set:Get(hid))
  end)

  it("a record whose author has left the guild is accepted; an unknown roster rejects", function()
    local old, mem = client("Old-R"), client("Mem-R")
    old.cfg.sync:Publish(rec("Old-R", 3, { calendar = false, other = true }))
    assert.same({ calendar = false, other = true }, ns.Groups.Credit.Settings(mem.cfg))
    loaded = false
    old.cfg.sync:Publish(rec("Old-R", 4, { calendar = true, other = false }))
    assert.same({ calendar = false, other = true }, ns.Groups.Credit.Settings(mem.cfg))
  end)
end)
