describe("Groups", function()
  local fakes = require("spec.helpers.fakes")
  local clock, timers, bus, nodes

  local function mkns()
    local ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log", "Profile" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    for _, f in ipairs({ "Instances", "Post", "Groups" }) do
      loadAddonFile(ns, "Guildhall/Modules/Groups/" .. f .. ".lua")
    end
    return ns
  end

  local function node(name, o)
    o = o or {}
    local ns = mkns()
    local n = { name = name, ns = ns, changes = 0 }
    local roster = { IsOnline = function() end, IsOfficer = function() end }
    local compat = fakes.compat({ IsTrialAccount = function() return o.trial end })
    local profSet = ns.ReplicatedSet.new("profiles", {}, { now = clock.now })
    n.profile = ns.Profile.new({
      personal = ns.DB.Init().personal, set = profSet, now = clock.now, roster = roster,
      random = function() return o.id or 7 end, playerChar = name, defaultRealm = "Realm", guildKey = "G-R",
    })
    n.profile:SeeCharacter(name)
    if o.consent ~= false then n.profile:Consent(o.excluded or {}) end
    n.logStore = {}
    n.moduleDb = {}
    local ctx = {
      compat = compat, comm = bus:join(name), now = clock.now, after = timers.after,
      random = function(lo) return lo end, roster = roster, profile = n.profile,
      log = ns.Log.new(n.logStore, clock.now, function() return "" end),
      playerChar = name, moduleDb = n.moduleDb, onChange = function() n.changes = n.changes + 1 end,
    }
    n.ctx = ctx
    n.g = ns.Groups.Create(ctx)
    n.Post = ns.Groups.Post
    nodes[name] = n
    return n
  end

  local function now(d)
    local x = { instance = "lbrs", role = "t", need = { t = 0, h = 1, d = 3 } }
    for k, v in pairs(d or {}) do x[k] = v end
    return x
  end

  local function mustPost(n, d)
    local ok, rec = n.g:Post(now(d))
    assert.is_true(ok, tostring(rec))
    return rec
  end

  before_each(function()
    clock = fakes.clock(100000)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    nodes = {}
  end)

  it("a Now post expires after 2 h, a scheduled one 6 h after start", function()
    local a = node("Alice-Realm", { id = 1 })
    local r1 = mustPost(a)
    assert.equal(100000 + 7200, r1.exp)
    local r2 = mustPost(a, { start = 200000 })
    assert.equal(200000 + 21600, r2.exp)
    assert.not_equal(r1.id, r2.id)
  end)

  it("post ids use the profile id and a session counter", function()
    local a = node("Alice-Realm", { id = 1 })
    local r = mustPost(a)
    assert.equal(a.profile:Id() .. ":g100000_", r.id:match("^(.+_)"))
  end)

  it("need larger than the instance size is invalid", function()
    local a = node("Alice-Realm")
    local ok, err = a.g:Post(now({ need = { t = 1, h = 1, d = 3 } }))
    assert.is_false(ok)
    assert.matches("size", err)
    assert.is_true((a.g:Post(now({ need = { t = 1, h = 1, d = 2 } }))))
  end)

  it("a post whose id prefix isn't its author is rejected", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local rec = mustPost(a)
    assert.is_not_nil(b.g.posts:Get(rec.id))
    local forged = a.ns.Util.DeepCopy(rec)
    forged.id = b.profile:Id() .. ":g100000_9"
    assert.is_false(a.Post.CheckIncoming(forged, nil))
    local forged2 = a.ns.Util.DeepCopy(rec)
    forged2.by = b.profile:Id()
    assert.is_false(a.Post.CheckIncoming(forged2, nil))
  end)

  it("signup with healer or DPS lists both roles; withdraw hides it", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local post = mustPost(a)
    assert.is_true((b.g:SignUp(post.id, { h = true, d = true })))
    local list = a.g:Signups(post.id)
    assert.equal(1, #list)
    assert.equal(b.profile:Id(), list[1].profile)
    assert.is_true(list[1].roles.h and list[1].roles.d)
    assert.is_nil(list[1].roles.t)
    assert.is_true((b.g:Withdraw(post.id)))
    assert.equal(0, #a.g:Signups(post.id))
    assert.equal(0, #b.g:Signups(post.id))
    assert.is_true(b.g.signups:Get(post.id .. "|" .. b.profile:Id()).d.withdrawn)
  end)

  it("signups expire with their post", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local post = mustPost(a)
    assert.is_true((b.g:SignUp(post.id, { d = true })))
    assert.equal(post.exp, b.g.signups:Get(post.id .. "|" .. b.profile:Id()).exp)
    clock.advance(7300)
    assert.equal(0, #a.g:Signups(post.id))
  end)

  it("assign fills a slot and reduces open", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local post = mustPost(a)
    local f = a.g:Filled(a.g:Get(post.id))
    assert.same({ a.profile:Id() }, f.t)
    assert.same({ t = 0, h = 1, d = 3 }, f.open)
    assert.is_true((a.g:Assign(post.id, b.profile:Id(), "d")))
    f = b.g:Filled(b.g:Get(post.id))
    assert.same({ b.profile:Id() }, f.d)
    assert.same({ t = 0, h = 1, d = 2 }, f.open)
    assert.is_false((b.g:Assign(post.id, "x", "h")))
  end)

  it("Ready now expires after its window; clamped to 6 h", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    assert.is_true((a.g:SetReady({ d = true }, 60)))
    local r = b.g:Ready()
    assert.equal(1, #r)
    assert.equal(100000 + 7200, r[1].exp)
    assert.is_true((a.g:SetReady({ d = true }, 60, 999999)))
    assert.equal(100000 + 21600, b.g:Ready()[1].exp)
    assert.is_true((a.g:SetReady({ d = true }, 60, 0)))
    assert.equal(100001, b.g:Ready()[1].exp)
    assert.is_true((a.g:SetReady({ d = true }, 60, 100)))
    clock.advance(101)
    assert.equal(0, #b.g:Ready())
    assert.is_true((a.g:SetReady({ t = true }, 60, 100)))
    assert.is_true((a.g:ClearReady()))
    assert.equal(0, #b.g:Ready())
  end)

  it("Posts orders Now first then scheduled by start", function()
    local a = node("Alice-Realm", { id = 1 })
    local s2 = mustPost(a, { start = 200500 })
    local s1 = mustPost(a, { start = 200100 })
    local n1 = mustPost(a)
    clock.advance(10)
    local n2 = mustPost(a)
    local ids = {}
    for _, p in ipairs(a.g:Posts()) do ids[#ids + 1] = p.id end
    assert.same({ n2.id, n1.id, s1.id, s2.id }, ids)
  end)

  it("Close removes the post for everyone; only the poster may", function()
    local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
    local post = mustPost(a)
    assert.is_false((b.g:Close(post.id)))
    assert.is_true((a.g:Close(post.id)))
    assert.equal(0, #b.g:Posts())
  end)

  it("excluded characters and trial accounts do not publish", function()
    local a = node("Alice-Realm", { id = 1, excluded = { "Alice-Realm" } })
    assert.is_false((a.g:Post(now())))
    assert.is_false((a.g:SetReady({ d = true }, 60)))
    local t = node("Tom-Realm", { id = 3, trial = true })
    assert.is_false((t.g:Post(now())))
  end)

  it("change hook fires debounced; sets append syncs", function()
    local a = node("Alice-Realm", { id = 1 })
    assert.equal(3, #a.ctx.syncs)
    mustPost(a)
    mustPost(a)
    assert.equal(0, a.changes)
    clock.advance(2)
    timers.run(clock)
    assert.equal(1, a.changes)
  end)

  describe("validation", function()
    local P
    before_each(function() P = node("Alice-Realm").Post end)

    it("rejects bad payloads", function()
      local bad = {
        { instance = "nope" }, { role = "x" }, { need = { t = 0, h = 0, d = 0, x = 1 } },
        { need = { t = -1, h = 0, d = 0 } }, { need = { t = 0 / 0, h = 0, d = 0 } },
        { need = { t = math.huge, h = 0, d = 0 } }, { need = { t = 1.5, h = 0, d = 0 } },
        { need = { t = 40, h = 0, d = 0 } }, { start = 1.5 }, { start = math.huge }, { start = 0 / 0 },
        { note = string.rep("x", 121) }, { want = string.rep("x", 65) }, { want = 0 / 0 }, { want = true },
        { assign = { ["a"] = "x" } }, { assign = { [string.rep("a", 17)] = "t" } }, { assign = "t" },
        { extra = 1 }, { created = math.huge },
      }
      for i, patch in ipairs(bad) do
        assert.is_false((P.Validate(now(patch))), "case " .. i)
      end
      assert.is_false((P.Validate("x")))
      assert.is_true((P.Validate(now({ want = 1234, note = string.rep("x", 120) }))))
    end)

    it("rejects more than 40 assignments", function()
      local a = {}
      for i = 1, 41 do a["p" .. i] = "d" end
      assert.is_false((P.Validate(now({ assign = a }))))
    end)

    it("rejects bad ready and signup payloads", function()
      assert.is_false((P.ValidateReady({ roles = { d = true }, level = 0 })))
      assert.is_false((P.ValidateReady({ roles = { d = true }, level = 81 })))
      assert.is_false((P.ValidateReady({ roles = { d = true }, level = 1.5 })))
      assert.is_false((P.ValidateReady({ roles = { d = true }, level = 0 / 0 })))
      assert.is_false((P.ValidateReady({ roles = {}, level = 60 })))
      assert.is_false((P.ValidateReady({ roles = { x = true }, level = 60 })))
      assert.is_false((P.ValidateReady({ roles = { d = true }, level = 60, extra = 1 })))
      assert.is_true((P.ValidateReady({ roles = { d = true }, level = 80 })))
      assert.is_false((P.ValidateSignup({ roles = { d = true }, at = math.huge })))
      assert.is_false((P.ValidateSignup({ roles = { d = true }, at = 5, extra = 1 })))
    end)
  end)

  describe("tampering", function()
    it("rejects a signup whose profile part isn't its author", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local post = mustPost(a)
      local rec = { id = post.id .. "|" .. a.profile:Id(), v = 1, t = 100000, by = b.profile:Id(), char = "Bob-Realm",
        exp = post.exp, del = false, d = { roles = { d = true }, at = 100000 } }
      local ok, err = a.Post.CheckIncomingSignup(rec, nil, { now = clock.now })
      assert.is_false(ok)
      assert.matches("author", err)
      b.g.signupSync:Publish(rec)
      assert.is_nil(a.g.signups:Get(rec.id))
    end)

    it("rejects a malformed signup post part, and one that outlives its post", function()
      local a = node("Alice-Realm", { id = 1 })
      local me = a.profile:Id()
      local base = { v = 1, t = 100000, by = me, char = "A-R", exp = 100000 + 7200, del = false,
        d = { roles = { d = true }, at = 100000 } }
      local function with(id, exp)
        local r = a.ns.Util.DeepCopy(base)
        r.id, r.exp = id, exp or r.exp
        return r
      end
      assert.is_false((a.Post.CheckIncomingSignup(with("junk|" .. me), nil, { now = clock.now })))
      assert.is_true((a.Post.CheckIncomingSignup(with("zz:g1_1|" .. me), nil, { now = clock.now })))
      assert.is_false((a.Post.CheckIncomingSignup(with("zz:g1_1|" .. me, 100000 + 21600 + 86400 + 1), nil,
        { now = clock.now })))
      assert.is_false((a.Post.CheckIncomingSignup(with("zz:g1_1|" .. me, 100000 + 7200 + 86400 + 1), nil,
        { now = clock.now, postExp = function() return 100000 + 7200 end })))
      assert.is_true((a.Post.CheckIncomingSignup(with("zz:g1_1|" .. me, 100000 + 7200 + 86400), nil,
        { now = clock.now, postExp = function() return 100000 + 7200 end })))
    end)

    it("rejects a ready record for another profile or an overlong window", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local rec = { id = a.profile:Id(), v = 1, t = 100000, by = b.profile:Id(), char = "Bob-Realm",
        exp = 100100, del = false, d = { roles = { d = true }, level = 60 } }
      assert.is_false((a.Post.CheckIncomingReady(rec, nil)))
      rec.by = a.profile:Id()
      assert.is_true((a.Post.CheckIncomingReady(rec, nil)))
      rec.exp = 100000 + 21601
      assert.is_false((a.Post.CheckIncomingReady(rec, nil)))
      rec.exp, rec.by = 100100, b.profile:Id()
      b.g.readySync:Publish(rec)
      assert.is_nil(a.g.ready:Get(rec.id))
    end)

    it("a same-(v,t) replacement by a different profile is not accepted", function()
      local a, b = node("Alice-Realm", { id = 1 }), node("Bob-Realm", { id = 2 })
      local post = mustPost(a)
      local rep = b.ns.Util.DeepCopy(post)
      rep.by, rep.char = b.profile:Id(), "Bob-Realm"
      rep.d.note = "hijack"
      local ok, err = a.Post.CheckIncoming(rep, a.g.posts:Get(post.id))
      assert.is_false(ok)
      assert.equal("not owner", err)
      -- Delivered over the wire it is rejected too.
      b.g.postSync:Publish(rep)
      assert.is_nil(a.g.posts:Get(post.id).d.note)
    end)

    it("rejects a post with an overlong exp or unknown record field", function()
      local a = node("Alice-Realm", { id = 1 })
      local post = mustPost(a)
      local r = a.ns.Util.DeepCopy(post)
      r.exp = r.exp + 1
      assert.is_false((a.Post.CheckIncoming(r, nil)))
      r = a.ns.Util.DeepCopy(post)
      r.extra = 1
      assert.is_false((a.Post.CheckIncoming(r, nil)))
      assert.is_true((a.Post.CheckIncoming(post, nil)))
    end)
  end)

  it("both new files are in the TOCs right after Instances", function()
    for _, toc in ipairs({ "Guildhall/Guildhall.toc", "Guildhall/Guildhall_Vanilla.toc" }) do
      local lines = {}
      for l in io.lines(toc) do lines[#lines + 1] = l end
      for i, l in ipairs(lines) do
        if l == "Modules/Groups/Instances.lua" then
          assert.equal("Modules/Groups/Post.lua", lines[i + 1])
          assert.equal("Modules/Groups/Groups.lua", lines[i + 2])
        end
      end
    end
  end)
end)
