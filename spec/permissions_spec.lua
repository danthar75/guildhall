-- Guild-rank permissions: the "perms" record in core.config, Can/Grants, and how weights,
-- retakes and history use them.
describe("Permissions", function()
  local fakes = require("spec.helpers.fakes")
  local clock, timers, bus, ranks, known, ns, offset

  local NOW = 1793793600 -- 2026-11-04 12:00 UTC
  local TWO_YEARS = 63072000

  local function build(char)
    ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    for _, f in ipairs({ "Activity", "Scoring", "Config" }) do
      loadAddonFile(ns, "Guildhall/Core/Leaderboard/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    ns.Activity.Register({ id = "sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 1 })
    local roster = {
      RankIndex = function(_, name) return ranks[name] end,
      HasRanks = function() return known end,
      IsOfficer = function(_, name) if ranks[name] == nil then return nil end return ranks[name] < 2 end,
    }
    local perms = ns.Permissions.new({ roster = roster, now = clock.now })
    local cfg = ns.LbConfig.new({
      comm = bus:join(char), now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = ns.Log.new({}, clock.now, function() return "" end), roster = roster,
      profile = { Id = function() return "p" .. char:sub(1, 3) end, OnlineChar = function() return nil end,
        CharsOf = function(_, id) return { id } end, set = { Get = function() return nil end } },
      compat = { ServerOffset = function() return offset end }, playerChar = char, db = {}, perms = perms,
    })
    return cfg, perms
  end

  before_each(function()
    clock = fakes.clock(NOW)
    timers = fakes.timers(clock)
    bus = fakes.bus(clock, timers)
    ranks = { ["Gm-Realm"] = 0, ["Off-Realm"] = 1, ["Vet-Realm"] = 2, ["Member-Realm"] = 5 }
    known, offset = true, 0
  end)

  local function prec(v, char, grants, t)
    t = t or clock.now()
    return { id = "perms", v = v, t = t, exp = t + 1000000, by = "pX", char = char, d = { grants = grants } }
  end
  local function grant(list, raidlead) return { ranks = list, raidlead = raidlead == true } end
  local function apply(cfg, r) return (cfg.sync:_applyOne(r, "Sender")) end
  local function lastReason(cfg)
    local store = cfg.ctx.log.store
    return store[#store].reason
  end

  it("defaults grant the guild master only; an officer can't publish weights until granted", function()
    local cfg, perms = build("Off-Realm")
    for _, k in ipairs(ns.Permissions.KEYS) do
      assert.same({ ranks = { [0] = true }, raidlead = false }, perms:Grants(k.key))
    end
    assert.is_true(perms:Can("Gm-Realm", "weights"))
    assert.is_false(perms:Can("Off-Realm", "weights"))
    local ok, err = cfg:PublishWeights({ sales = 9 })
    assert.is_false(ok)
    assert.equal("no permission", err)
    assert.is_nil(cfg.set:Get("weights"))
    -- an incoming weights record from an officer is refused too
    assert.equal("invalid", apply(cfg, { id = "weights", v = 1, t = clock.now(), exp = clock.now() + 1000, by = "pY",
      char = "Vet-Realm", d = { weights = { sales = 9 } } }))
    assert.equal("accepted", apply(cfg, prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) })))
    assert.is_true(perms:Can("Off-Realm", "weights"))
    assert.is_true((cfg:PublishWeights({ sales = 9 })))
    assert.equal(9, cfg:Weights().sales)
  end)

  it("the keys are the v1 three, in order", function()
    build("Gm-Realm")
    local got = {}
    for _, k in ipairs(ns.Permissions.KEYS) do got[#got + 1] = { k.key, k.label, k.raidlead } end
    assert.same({ { "weights", "Edit leaderboard weights", false }, { "retake", "Retake a month", false },
      { "bankreview", "Review bank contributions", false } }, got)
    assert.is_false(ns.Permissions.AddKey({ key = "weights", label = "Again" }))
    assert.is_true(ns.Permissions.AddKey({ key = "flex", label = "Flex", raidlead = true }))
    assert.equal("flex", ns.Permissions.KEYS[4].key)
  end)

  it("a perms record from rank 1 is rejected; from rank 0 accepted", function()
    local cfg, perms = build("Member-Realm")
    assert.equal("invalid", apply(cfg, prec(1, "Off-Realm", { weights = grant({ 0, 1 }) })))
    assert.equal("author not the guild master", lastReason(cfg))
    assert.is_false(perms:Can("Off-Realm", "weights"))
    assert.equal("accepted", apply(cfg, prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) })))
    assert.is_true(perms:Can("Off-Realm", "weights"))
  end)

  it("permissions from a former GM stay; a new GM's record replaces them; unknown roster defers", function()
    local cfg, perms = build("Member-Realm")
    assert.equal("accepted", apply(cfg, prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) })))
    -- the guild master hands over: Gm drops to officer, New becomes guild master
    ranks["Gm-Realm"], ranks["New-Realm"] = 1, 0
    assert.is_true(perms:Can("Off-Realm", "weights"))
    clock.advance(10)
    assert.equal("invalid", apply(cfg, prec(2, "Gm-Realm", { weights = grant({ 0, 1, 2 }) })))
    assert.is_false(perms:Can("Vet-Realm", "weights"))
    -- the new guild master's record waits while the roster is unknown, then wins
    known = false
    local r = prec(2, "New-Realm", { weights = grant({ 0 }) })
    assert.equal("invalid", apply(cfg, r))
    assert.equal("roster unknown", lastReason(cfg))
    assert.is_true(perms:Can("Off-Realm", "weights"))
    known = true
    assert.equal("accepted", apply(cfg, r))
    assert.is_false(perms:Can("Off-Realm", "weights"))
    assert.is_true(perms:Can("New-Realm", "weights"))
  end)

  it("a rejected perms record is accepted once the roster knows the author is rank 0", function()
    local cfg, perms = build("Member-Realm")
    ranks["Gm-Realm"] = nil -- the roster hasn't listed the guild master yet
    local r = prec(1, "Gm-Realm", { bankreview = grant({ 0, 1 }) })
    assert.equal("invalid", apply(cfg, r))
    assert.equal("roster unknown", lastReason(cfg))
    assert.is_nil(cfg.set:Get("perms"))
    ranks["Gm-Realm"] = 0
    assert.equal("accepted", apply(cfg, r))
    assert.is_true(perms:Can("Off-Realm", "bankreview"))
  end)

  it("Can honours raidlead only with a matching raidLeaders set", function()
    local cfg, perms = build("Gm-Realm")
    ns.Permissions.AddKey({ key = "flex", label = "Flex", raidlead = true })
    assert.is_true((perms:Publish({ flex = { ranks = {}, raidlead = true } })))
    assert.is_false(perms:Can("Member-Realm", "flex"))
    assert.is_false(perms:Can("Member-Realm", "flex", { raidLeaders = { ["Vet-Realm"] = true } }))
    assert.is_true(perms:Can("Member-Realm", "flex", { raidLeaders = { ["Member-Realm"] = true } }))
    assert.is_true(perms:Can("Member-Realm", "flex", { raidLeaders = { "Member-Realm" } }))
    -- a key without raidlead ignores the set
    assert.is_false(perms:Can("Member-Realm", "weights", { raidLeaders = { ["Member-Realm"] = true } }))
    -- an unknown rank is never granted
    assert.is_false(perms:Can("Stranger-Realm", "flex", { raidLeaders = { ["Stranger-Realm"] = true } }))
    assert.is_false(perms:Can(nil, "flex"))
    assert.is_true(cfg.set:Get("perms").d.grants.flex.raidlead)
  end)

  it("Publish writes one history entry what=perms with before and after", function()
    local cfg, perms = build("Gm-Realm")
    assert.is_true((perms:Publish({ bankreview = { ranks = { [1] = true } }, weights = { ranks = { [0] = true } } })))
    local h = cfg:History()
    assert.equal(1, #h)
    assert.equal("perms", h[1].what)
    assert.equal("Gm-Realm", h[1].by)
    -- only the changed key is stored
    assert.same({ bankreview = { ranks = { 0 }, raidlead = false } }, h[1].before)
    assert.same({ bankreview = { ranks = { 0, 1 }, raidlead = false } }, h[1].after)
    local r = cfg.set:Get(h[1].id)
    assert.equal(r.t + TWO_YEARS, r.exp)
    assert.same({ 0, 1 }, cfg.set:Get("perms").d.grants.bankreview.ranks)
    -- a peer accepts both the record and its history verbatim
    local peer = build("Member-Realm")
    assert.equal("accepted", apply(peer, cfg.set:Get("perms")))
    assert.equal("accepted", apply(peer, r))
    assert.is_true(peer:HistoryAuthorPermitted(peer:History()[1]))
  end)

  it("only the guild master can publish, and a refusal writes nothing", function()
    local cfg, perms = build("Off-Realm")
    local ok, err = perms:Publish({ weights = { ranks = { [1] = true } } })
    assert.is_false(ok)
    assert.equal("Only the guild master can change permissions.", err)
    assert.is_nil(cfg.set:Get("perms"))
    assert.equal(0, #cfg:History())
    local _, gperms = build("Gm-Realm")
    assert.is_false((gperms:Publish({ weights = { ranks = { 10 } } })))
    assert.is_false((gperms:Publish({ [string.rep("k", 33)] = { ranks = {} } })))
    assert.is_false((gperms:Publish("x")))
  end)

  it("a weights publish by a rank granted 'weights' is accepted; by an officer whose rank was removed is rejected", function()
    local peer, pperms = build("Member-Realm")
    local function wrec(v, char, sales)
      return { id = "weights", v = v, t = clock.now(), exp = clock.now() + 1000000, by = "pOff", char = char,
        d = { weights = { sales = sales } } }
    end
    assert.equal("accepted", apply(peer, prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) })))
    assert.equal("accepted", apply(peer, wrec(1, "Off-Realm", 9)))
    assert.equal(9, peer:Weights().sales)
    clock.advance(10)
    assert.equal("accepted", apply(peer, prec(2, "Gm-Realm", { weights = grant({ 0 }) })))
    assert.is_false(pperms:Can("Off-Realm", "weights"))
    assert.equal("invalid", apply(peer, wrec(2, "Off-Realm", 1)))
    assert.equal("author lacks permission", lastReason(peer))
    -- the earlier accepted weights stay in effect
    assert.equal(9, peer:Weights().sales)
    -- and the officer's own client refuses locally
    local off = build("Off-Realm")
    apply(off, prec(2, "Gm-Realm", { weights = grant({ 0 }) }))
    assert.is_false((off:PublishWeights({ sales = 3 })))
  end)

  it("retakes need 'retake'; the automatic month save stays an officer action", function()
    local cfg = build("Off-Realm")
    local function month(v, char, retake, t)
      return { id = "month:2026-10", v = v, t = t, exp = t + 1000000, by = "pX", char = char,
        d = { month = "2026-10", from = t - 10, to = t, tz = 0, goldKept = 0, overall = {}, boards = {}, weights = {},
          savedBy = char, savedAt = 1, retake = retake } }
    end
    assert.equal("accepted", apply(cfg, month(1, "Off-Realm", nil, clock.now())))
    assert.equal("invalid", apply(cfg, month(1, "Member-Realm", nil, clock.now() + 1)))
    assert.equal("invalid", apply(cfg, month(2, "Off-Realm", true, clock.now())))
    assert.equal("author lacks permission", lastReason(cfg))
    assert.equal("accepted", apply(cfg, month(2, "Gm-Realm", true, clock.now())))
    -- locally: the officer is refused until granted
    local ledger = { Query = function() return { byProfile = {}, guild = {}, goldKept = 0 } end }
    local ok, err = cfg:RetakeMonth("2026-10", ledger)
    assert.is_false(ok)
    assert.equal("no permission", err)
    assert.equal("accepted", apply(cfg, prec(1, "Gm-Realm", { retake = grant({ 0, 1 }) })))
    assert.is_true((cfg:RetakeMonth("2026-10", ledger)))
    assert.is_true(cfg:HistoryAuthorPermitted(cfg:History()[1]))
  end)

  describe("month records cannot replace a retake or skip the save-time rules", function()
    local GRACE = 259200
    local TO = NOW - GRACE - 100 -- the month ended more than 3 days ago
    local function month(v, char, retake, t, tag)
      return { id = "month:2026-10", v = v, t = t, exp = t + 1000000, by = "pX", char = char,
        d = { month = "2026-10", from = TO - 1000, to = TO, tz = 0, goldKept = 0, overall = {}, boards = {},
          weights = {}, savedBy = tag, savedAt = 1, retake = retake } }
    end

    it("an officer's same-version record without retake doesn't replace a GM retake", function()
      local cfg = build("Member-Realm")
      assert.equal("accepted", apply(cfg, month(1, "Off-Realm", nil, TO + GRACE - 50, "auto")))
      assert.equal("accepted", apply(cfg, month(2, "Gm-Realm", true, clock.now(), "retake")))
      assert.equal("invalid", apply(cfg, month(2, "Off-Realm", nil, clock.now() + 60, "forged")))
      assert.equal("month already saved", lastReason(cfg))
      assert.equal("invalid", apply(cfg, month(3, "Off-Realm", nil, clock.now() + 60, "forged3")))
      assert.equal("invalid", apply(cfg, month(1, "Off-Realm", nil, TO + GRACE, "forged1")))
      assert.equal("retake", cfg.set:Get("month:2026-10").d.savedBy)
    end)

    it("a v1 auto save must carry an honest save time; the earliest honest save still wins", function()
      local cfg = build("Member-Realm")
      -- saves at anchor + 100 and anchor + 50: t = 2 * anchor - now
      local anchor = TO + GRACE
      assert.equal("accepted", apply(cfg, month(1, "Off-Realm", nil, anchor - 100, "later")))
      assert.equal("accepted", apply(cfg, month(1, "Gm-Realm", nil, anchor - 50, "earlier")))
      assert.equal("earlier", cfg.set:Get("month:2026-10").d.savedBy)
      -- a t past the anchor can't come from MaybeSaveMonth
      assert.equal("invalid", apply(cfg, month(1, "Off-Realm", nil, anchor + 1, "forged")))
      assert.equal("bad save time", lastReason(cfg))
      assert.equal("earlier", cfg.set:Get("month:2026-10").d.savedBy)
      -- and a retake is never version 1
      assert.equal("invalid", apply(cfg, month(1, "Gm-Realm", true, anchor + 5000, "retake1")))
      assert.equal("bad retake version", lastReason(cfg))
    end)

    it("MaybeSaveMonth's own records pass, including a backfill of two months", function()
      local gm = build("Gm-Realm")
      local ledger = { Query = function() return { byProfile = { p1 = { sales = 3 } }, guild = {}, goldKept = 0 } end }
      clock.advance(40 * 86400)
      assert.is_true(gm:MaybeSaveMonth(ledger, clock.now()))
      local peer = build("Member-Realm")
      local n = 0
      for _, ym in ipairs(gm:Months()) do
        n = n + 1
        assert.equal("accepted", apply(peer, gm.set:Get("month:" .. ym)))
      end
      assert.is_true(n >= 2) -- every month back to the retention window
    end)
  end)

  it("a perms record with fields other than grants is rejected", function()
    local cfg = build("Member-Realm")
    local r = prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) })
    r.d.junk = string.rep("x", 100)
    assert.equal("invalid", apply(cfg, r))
    assert.equal("unknown perms field", lastReason(cfg))
    r.d.junk = nil
    assert.equal("accepted", apply(cfg, r))
  end)

  it("MaybeRefreshTz runs only with 'weights'", function()
    local gm = build("Gm-Realm")
    assert.is_true((gm:PublishWeights({ sales = 9 })))
    local stored = gm.set:Get("weights")
    local off = build("Off-Realm")
    assert.equal("accepted", apply(off, stored))
    offset = 3600
    clock.advance(10)
    assert.is_false(off:MaybeRefreshTz())
    assert.equal(1, off.set:Get("weights").v)
    apply(off, prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) }))
    assert.is_true(off:MaybeRefreshTz())
    assert.equal(2, off.set:Get("weights").v)
  end)

  it("the no-permission-now mark follows the permission behind each kind", function()
    local cfg = build("Member-Realm")
    apply(cfg, prec(1, "Gm-Realm", { weights = grant({ 0, 1 }) }))
    assert.is_true(cfg:HistoryAuthorPermitted({ what = "weights", by = "Off-Realm" }))
    assert.is_false(cfg:HistoryAuthorPermitted({ what = "weights", by = "Vet-Realm" }))
    assert.is_false(cfg:HistoryAuthorPermitted({ what = "month", by = "Off-Realm" }))
    assert.is_true(cfg:HistoryAuthorPermitted({ what = "month", by = "Gm-Realm" }))
    assert.is_true(cfg:HistoryAuthorPermitted({ what = "perms", by = "Gm-Realm" }))
    assert.is_false(cfg:HistoryAuthorPermitted({ what = "perms", by = "Off-Realm" }))
    -- a bank review follows "bankreview" (guild master only by default)
    assert.is_true(cfg:HistoryAuthorPermitted({ what = "bank", by = "Gm-Realm" }))
    assert.is_false(cfg:HistoryAuthorPermitted({ what = "bank", by = "Off-Realm" }))
    apply(cfg, prec(2, "Gm-Realm", { weights = grant({ 0, 1 }), bankreview = grant({ 0, 1 }) }))
    assert.is_true(cfg:HistoryAuthorPermitted({ what = "bank", by = "Off-Realm" }))
    -- any other kind is an officer check
    assert.is_true(cfg:HistoryAuthorPermitted({ what = "other", by = "Off-Realm" }))
    assert.is_false(cfg:HistoryAuthorPermitted({ what = "other", by = "Vet-Realm" }))
  end)

  it("validates the payload strictly, keeps unknown keys and always grants rank 0", function()
    local cfg, perms = build("Gm-Realm")
    local bad = {
      { weights = grant({ 10 }) }, { weights = grant({ -1 }) }, { weights = grant({ 1.5 }) },
      { weights = grant({ "1" }) }, { weights = grant({ 1, 1 }) }, { weights = { ranks = { 1 }, raidlead = "yes" } },
      { weights = { ranks = { 1 } } }, { weights = { ranks = { [1] = 0, [3] = 1 }, raidlead = false } },
      { [string.rep("k", 33)] = grant({ 0 }) }, { [5] = grant({ 0 }) }, "x",
    }
    local many = {}
    for i = 1, 33 do many["k" .. i] = grant({ 0 }) end
    bad[#bad + 1] = many
    for _, g in ipairs(bad) do
      assert.equal("invalid", apply(cfg, prec(1, "Gm-Realm", g)))
    end
    assert.equal("invalid", apply(cfg, { id = "perms", v = 1, t = clock.now(), exp = clock.now() + 10, by = "pX",
      char = "Gm-Realm", d = "x" }))
    assert.is_nil(cfg.set:Get("perms"))
    -- a newer client's key, and a record that leaves rank 0 out
    assert.equal("accepted", apply(cfg, prec(1, "Gm-Realm", { future = grant({ 3 }), weights = grant({ 1 }) })))
    assert.is_true(perms:Grants("weights").ranks[0])
    assert.is_true(perms:Can("Gm-Realm", "weights"))
    assert.is_true(perms:Can("Off-Realm", "weights"))
    -- the guild master's own save keeps the unknown key
    clock.advance(5)
    assert.is_true((perms:Publish({ retake = { ranks = { [2] = true } } })))
    assert.same({ 3 }, cfg.set:Get("perms").d.grants.future.ranks)
    assert.same({ 0, 2 }, cfg.set:Get("perms").d.grants.retake.ranks)
  end)

  it("a malformed perms history record is rejected", function()
    local cfg = build("Gm-Realm")
    local t = clock.now()
    local function h(before, after)
      return { id = "history:pX:" .. t .. ":1", v = 1, t = t, exp = t + TWO_YEARS, by = "pX", char = "Gm-Realm",
        d = { what = "perms", before = before, after = after, by = "Gm-Realm", at = t } }
    end
    assert.equal("invalid", apply(cfg, h({ weights = grant({ 0 }) }, { weights = grant({ 0, 12 }) })))
    assert.equal("invalid", apply(cfg, h(nil, {})))
    assert.equal("accepted", apply(cfg, h({ weights = grant({ 0 }) }, { weights = grant({ 0, 1 }) })))
  end)
end)

describe("PermissionsView", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, view, buttons, texts, ranks, errors, cfg
  local NOW = 1793793600
  local GLOBALS = { "CreateFrame" }
  local saved = {}

  local function isAllowed(s)
    s = s:gsub("\194\183", ""):gsub("\195\151", "")
    return not s:find("[\128-\255]")
  end

  local function build(char)
    local clock = fakes.clock(NOW)
    local timers = fakes.timers(clock)
    local bus = fakes.bus(clock, timers)
    ns = {}
    for _, f in ipairs({ "Util", "DB", "ReplicatedSet", "Sync", "Log" }) do
      loadAddonFile(ns, "Guildhall/Core/" .. f .. ".lua")
    end
    for _, f in ipairs({ "Activity", "Scoring", "Config" }) do
      loadAddonFile(ns, "Guildhall/Core/Leaderboard/" .. f .. ".lua")
    end
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.UI = {
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Text = function(_, _, text)
        local t = W.new("FontString"); t.text = text; texts[#texts + 1] = t; t.shown = true; return t
      end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; buttons[text] = b; return b
      end,
    }
    local roster = {
      RankIndex = function(_, name) return ranks[name] end,
      HasRanks = function() return true end,
      IsOfficer = function(_, name) if ranks[name] == nil then return nil end return ranks[name] < 2 end,
      RankNames = function() return { "Guild Master", "Officer", "Veteran", "Member" } end,
    }
    local perms = ns.Permissions.new({ roster = roster })
    cfg = ns.LbConfig.new({
      comm = bus:join(char), now = clock.now, after = timers.after, random = function(lo) return lo end,
      log = ns.Log.new({}, clock.now, function() return "" end), roster = roster,
      profile = { Id = function() return "pMe" end }, compat = { ServerOffset = function() return 0 end },
      playerChar = char, db = {}, perms = perms,
    })
    ns.services = { playerChar = char, roster = roster }
    ns.leaderboard = { config = cfg, permissions = perms }
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/UI/SettingsView.lua")
    loadAddonFile(ns, "Guildhall/Core/UI/PermissionsView.lua")
    view = ns.UI.PermissionsView.Build(W.new("Frame"))
    return view
  end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = function(kind, ...)
      local w = W.CreateFrame(kind, ...)
      w.enabled = true
      rawset(w, "Enable", function(self) self.enabled = true end)
      rawset(w, "Disable", function(self) self.enabled = false end)
      return w
    end
    buttons, texts, errors = {}, {}, {}
    ranks = { ["Gm-Realm"] = 0, ["Off-Realm"] = 1, ["Member-Realm"] = 3 }
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function has(s)
    for _, t in ipairs(texts) do if t.text == s then return true end end
    return false
  end

  it("a non-GM sees the grid read-only; GM save publishes the ticked ranks", function()
    build("Off-Realm")
    assert.is_true(has("Only the Guild Master can change these. Ranks come from the game, in rank order."))
    for _, label in ipairs({ "Edit leaderboard weights", "Retake a month", "Review bank contributions",
      "Guild Master", "Officer", "Veteran", "Member" }) do
      assert.is_true(has(label), label)
    end
    assert.is_false(has("Raid leader & assistants"))
    for _, k in ipairs(ns.Permissions.KEYS) do
      local row = view.cells[k.key]
      assert.equal(4, #row)
      assert.is_true(row[1]:GetChecked())
      for c = 1, 4 do assert.is_false(row[c].enabled) end
      for c = 2, 4 do assert.is_false(row[c]:GetChecked()) end
    end
    assert.is_false(buttons["Save"].shown)
    assert.is_false(buttons["Reset to guild master only"].shown)
    view.doSave()
    assert.is_nil(cfg.set:Get("perms"))

    build("Gm-Realm")
    assert.is_true(buttons["Save"].shown)
    local row = view.cells.bankreview
    assert.is_false(row[1].enabled) -- the Guild Master column can't be edited
    for c = 2, 4 do assert.is_true(row[c].enabled) end
    row[2]:SetChecked(true); row[3]:SetChecked(true)
    view.cells.weights[2]:SetChecked(true)
    buttons["Save"].onClick()
    local g = cfg.set:Get("perms").d.grants
    assert.same({ 0, 1, 2 }, g.bankreview.ranks)
    assert.same({ 0, 1 }, g.weights.ranks)
    assert.same({ 0 }, g.retake.ranks)
    assert.is_true(has("Permissions saved."))
    assert.is_true(view.cells.bankreview[3]:GetChecked())
    -- the history preview shows the change in plain language
    assert.is_true(has("(full list under Change history)"))
    local found = false
    for _, l in ipairs(view.historyLines) do
      if l:find("Changed Review bank contributions: Guild Master -> Guild Master, Officer, Veteran", 1, true) then found = true end
    end
    assert.is_true(found)
    assert.same({}, errors)
  end)

  it("Reset ticks the guild master only and waits for Save", function()
    build("Gm-Realm")
    view.cells.weights[2]:SetChecked(true)
    buttons["Save"].onClick()
    buttons["Reset to guild master only"].onClick()
    assert.same({ 0, 1 }, cfg.set:Get("perms").d.grants.weights.ranks)
    assert.is_false(view.cells.weights[2]:GetChecked())
    assert.is_true(view.cells.weights[1]:GetChecked())
    buttons["Save"].onClick()
    assert.same({ 0 }, cfg.set:Get("perms").d.grants.weights.ranks)
  end)

  it("shows the raid leader column only when a key allows it", function()
    ranks["Gm-Realm"] = 0
    -- AddKey has to run before the grid is built, so add it on a fresh load and rebuild
    build("Gm-Realm")
    ns.Permissions.AddKey({ key = "flex", label = "Flex", raidlead = true })
    view = ns.UI.PermissionsView.Build(W.new("Frame"))
    assert.is_true(has("Raid leader & assistants"))
    assert.is_truthy(view.raid.flex)
    assert.is_nil(view.raid.weights)
    view.raid.flex:SetChecked(true)
    view.doSave()
    assert.is_true(cfg.set:Get("perms").d.grants.flex.raidlead)
    assert.is_false(cfg.set:Get("perms").d.grants.weights.raidlead)
  end)

  it("Save keeps stored ranks that have no column", function()
    build("Gm-Realm")
    local p = ns.leaderboard.permissions
    assert.is_true((p:Publish({ weights = { ranks = { 1, 7 } } })))
    view.refresh()
    view.cells.retake[3]:SetChecked(true)
    view.doSave()
    local g = cfg.set:Get("perms").d.grants
    assert.same({ 0, 1, 7 }, g.weights.ranks)
    assert.same({ 0, 2 }, g.retake.ranks)
  end)

  it("a key added after Build gets its row on the next refresh", function()
    build("Gm-Realm")
    ns.Permissions.AddKey({ key = "checklists", label = "Edit checklists" })
    view.refresh()
    assert.is_truthy(view.cells.checklists)
    assert.equal(4, #view.cells.checklists)
    assert.is_true(has("Edit checklists"))
    view.cells.checklists[2]:SetChecked(true)
    view.doSave()
    assert.same({ 0, 1 }, cfg.set:Get("perms").d.grants.checklists.ranks)
    assert.same({}, errors)
  end)

  it("demo permissions keep the grid read-only", function()
    build("Gm-Realm")
    local real = ns.leaderboard.permissions
    local demo = ns.Permissions.new({ roster = real.roster })
    function demo:Editable() return false end
    ns.leaderboard.permissions = demo
    view.refresh()
    assert.is_false(view.cells.weights[2].enabled)
    assert.is_false(buttons["Save"].shown)
  end)

  it("UI strings use allowed glyphs only", function()
    build("Gm-Realm")
    for _, t in ipairs(texts) do assert.is_true(isAllowed(tostring(t.text)), tostring(t.text)) end
    for _, path in ipairs({ "Guildhall/Core/Permissions.lua", "Guildhall/Core/UI/PermissionsView.lua",
      "Guildhall/Core/Leaderboard/UI/SettingsView.lua", "Guildhall/Core/UI/SettingsView.lua" }) do
      local f = assert(io.open(path)); local src = f:read("*a"); f:close()
      for str in src:gmatch('"([^"\n]*)"') do assert.is_true(isAllowed(str), path .. ": " .. str) end
    end
  end)
end)
