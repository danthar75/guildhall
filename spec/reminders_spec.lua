-- Reminders: one chat line 15 min before a scheduled run, for its poster and its signed-up players.
describe("Reminders", function()
  local fakes = require("spec.helpers.fakes")
  local ns, clock, timers, printed, sounds, personal, posts, signups, online, db

  local DAY = 1700006400            -- a server-time midnight (UTC epoch)
  local START = DAY + 20 * 3600     -- 20:00 server time

  local function post(o)
    o = o or {}
    return { id = o.id or "p1", by = o.by or "poster", del = false, exp = (o.start or START) + 21600,
      d = { instance = o.instance or "mc", role = "t", need = { t = 1, h = 8, d = 30 }, start = o.start or START } }
  end

  local function build()
    return ns.Groups.Reminders.new({
      groups = {
        Posts = function() return posts end,
        Signups = function(_, id) return signups[id] or {} end,
      },
      profile = {
        Id = function() return "me" end,
        OnlineChar = function(_, pid) return online[pid] and (pid .. "-Realm") or nil end,
      },
      now = clock.now, after = timers.after, personal = personal, db = db,
      print = function(msg) printed[#printed + 1] = msg end,
      playSound = function() sounds = sounds + 1 end,
    })
  end

  local function step(s) clock.advance(s); timers.run(clock) end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Reminders.lua")
    clock = fakes.clock(DAY + 16 * 3600)
    timers = fakes.timers(clock)
    printed, sounds, db = {}, 0, {}
    personal = {}
    ns.Groups.Reminders.Defaults(personal)
    posts = { post() }
    signups = { p1 = { { profile = "me", roles = { d = true }, at = 1 }, { profile = "other", roles = { h = true }, at = 2 } } }
    online = { me = true, poster = true }
  end)

  it("fills the account-wide defaults without overwriting choices", function()
    assert.same({ reminders = true, sound = true, roles = { d = true } }, personal.groups)
    local p = { groups = { reminders = false, roles = { t = true } } }
    ns.Groups.Reminders.Defaults(p)
    assert.same({ reminders = false, sound = true, roles = { t = true } }, p.groups)
  end)

  it("a post at 20:00 server time reminds at 19:45 server time with a local offset of +3 h", function()
    -- the local clock reads server + 3 h; the reminder follows server time (ctx.now) only
    local r = build()
    r:Start()
    step(2 * 3600 + 45 * 60) -- 18:45 server, 21:45 local: well past "19:45 local"
    assert.equal(0, #printed)
    while clock.now() < START - 900 - 30 do step(30) end
    assert.equal(0, #printed)
    while clock.now() < START - 900 do step(30) end
    assert.equal(1, #printed)
    assert.equal("Guildhall: Molten Core starts in 15 min (3 of 40 signed up, 2 online).", printed[1])
    assert.equal(1, sounds)
    for _ = 1, 40 do step(30) end
    assert.equal(1, #printed)
  end)

  it("a late login inside the 15-minute window reminds once", function()
    clock.advance((START - 300) - clock.now())
    local r = build()
    r:Start()
    assert.equal(1, #printed)
    assert.truthy(printed[1]:find("starts in 5 min", 1, true))
    for _ = 1, 20 do step(30) end
    assert.equal(1, #printed)
    -- a /reload in the window does not repeat it (the per-guild db remembers it)
    build():Start()
    assert.equal(1, #printed)
  end)

  it("a login after the start reminds nothing", function()
    clock.advance(START + 1 - clock.now())
    build():Start()
    assert.equal(0, #printed)
  end)

  it("reminders off fires nothing", function()
    personal.groups.reminders = false
    clock.advance((START - 600) - clock.now())
    local r = build()
    r:Start()
    for _ = 1, 30 do step(30) end
    assert.equal(0, #printed)
    assert.equal(0, sounds)
  end)

  it("sound off prints but plays nothing", function()
    personal.groups.sound = false
    clock.advance((START - 600) - clock.now())
    build():Start()
    assert.equal(1, #printed)
    assert.equal(0, sounds)
  end)

  it("reminds the poster, and nobody who is neither poster nor signed up", function()
    signups = {}
    clock.advance((START - 600) - clock.now())
    build():Start()
    assert.equal(0, #printed)
    posts = { post({ by = "me" }) }
    build():Start()
    assert.equal(1, #printed)
    assert.truthy(printed[1]:find("(1 of 40 signed up, 1 online)", 1, true))
  end)

  it("a Now post (no start) reminds nothing", function()
    local p = post()
    p.d.start = nil
    posts = { p }
    build():Start()
    for _ = 1, 600 do step(30) end
    assert.equal(0, #printed)
  end)

  it("stops ticking when Stop is called", function()
    local r = build()
    r:Start()
    r:Stop()
    clock.advance((START - 600) - clock.now())
    timers.run(clock)
    assert.equal(0, #printed)
  end)
end)
