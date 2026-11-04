-- Leaderboard tab under fake frames: who sees which breakdown, the pinned row, past months.
describe("Leaderboard.View", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, view, texts, buttons, picked, errors, result, officer, hidden, month, timers, handlers, popups
  local retaken, retakeResult, retakeErr
  local NOW = 1699999999 -- 2023-11-14 21:33 UTC
  local GLOBALS = { "CreateFrame", "StaticPopup_Show", "StaticPopupDialogs" }
  local saved = {}

  local function names() return { p1 = "Thalwyn", p2 = "Brakka", p3 = "Mireth", p14 = "Dor" } end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    _G.StaticPopupDialogs = {}
    popups = {}
    _G.StaticPopup_Show = function(which, text, _, data) popups[#popups + 1] = { which, text, data } end
    texts, buttons, errors, timers, handlers, picked, retaken = {}, {}, {}, {}, {}, nil, nil
    retakeResult, retakeErr = true, nil
    officer, hidden, month = false, {}, nil
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Config.lua")
    loadAddonFile(ns, "Guildhall/Core/Permissions.lua")
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.Events = { On = function(_, event, fn) handlers[#handlers + 1] = { event, fn } end }
    ns.UI = {
      BACKDROP_TEMPLATE = nil,
      ApplyBackdrop = function() end,
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Text = function(_, _, text)
        local t = W.new("FontString"); t.text = text; t.shown = true; texts[#texts + 1] = t; return t
      end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; buttons[text] = b; b.text = text; return b
      end,
      PickList = function(anchor, items, onPick, current)
        picked = { anchor = anchor, items = items, onPick = onPick, current = current }
      end,
    }
    ns.Activity.Register({ id = "exchange.sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 20 })
    ns.Activity.Register({ id = "exchange.purchases", label = "Purchases", unit = "count", verify = "paired", weight = 5, order = 30 })
    ns.Activity.Register({ id = "bank.items", label = "Bank items", unit = "items", verify = "paired", weight = 0.05, order = 70 })
    ns.Activity.Register({ id = "exchange.gold.earned", label = "Gold earned", unit = "gold", verify = "paired", weight = 0.1, order = 40 })
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/UI/View.lua")

    -- 14 profiles; p14 is "me" and ranks last.
    local byProfile = {}
    for i = 1, 14 do byProfile["p" .. i] = { ["exchange.sales"] = 15 - i } end
    result = { byProfile = byProfile, guild = {}, goldKept = 43120000,
      rows = {
        { type = "exchange.sales", profile = "p14", value = 1, at = NOW - 86400, item = "Runecloth", counted = true },
        { type = "exchange.sales", profile = "p14", value = 1, at = NOW - 3600, item = "Silk", counted = false, why = "unpaired" },
      } }
    local nm = names()
    local profile = {
      Id = function() return "p14" end,
      IsHidden = function(_, id) return hidden[id] == true end,
      OnlineChar = function(_, id) return id == "p1" and "Thalwyn-Realm" or nil end,
      CharsOf = function(_, id) return { (nm[id] or id) .. "-Realm" } end,
      set = { Get = function() return nil end },
    }
    ns.services = {
      now = function() return NOW end, playerChar = "Dor-Realm", profile = profile,
      roster = { IsOfficer = function() return officer end },
      compat = { ServerOffset = function() return nil end, SecondsUntilWeeklyReset = function() return nil end },
      after = function(delay, cb) timers[#timers + 1] = { delay, cb } end,
    }
    ns.leaderboard = {
      -- an officer stands for "granted retake" here; spec/permissions_spec.lua covers the ranks
      permissions = { Can = function(_, _, key) return key == "retake" and officer end },
      ledger = { Query = function() return result end },
      config = {
        Weights = function() return { ["exchange.sales"] = 5, ["exchange.gold.earned"] = 0.1 } end,
        Tz = function() return 0 end,
        Months = function() return month and { "2023-10" } or {} end,
        Month = function(_, ym) return ym == "2023-10" and month or nil end,
        RetakeMonth = function(_, ym) retaken = ym; return retakeResult, retakeErr end,
      },
    }
    local parent = W.new("Frame")
    parent:Show()
    view = ns.Leaderboard.View.Build(parent)
    view:Refresh()
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function has(s)
    for _, t in ipairs(texts) do if t.text == s and t.shown then return true end end
    return false
  end
  local function hasLike(s)
    for _, t in ipairs(texts) do if t.shown and type(t.text) == "string" and t.text:find(s, 1, true) then return true end end
    return false
  end
  local function click(w)
    local h
    for _, c in ipairs(w.calls.SetScript or {}) do if c[1] == "OnClick" then h = c[2] end end
    h(w)
  end

  it("a member clicking another row sees totals only", function()
    click(view.rows[1])
    assert.is_true(has("The breakdown of a player's score is visible to that player and to officers."))
    assert.is_true(has("#1  Thalwyn"))
    assert.is_false(has("Total"))
    assert.is_false(has("Activity"))
    assert.same({}, errors)
  end)

  it("clicking your own row shows the breakdown", function()
    click(view.pinned)
    assert.is_true(has("Your score: 5 points"))
    assert.is_true(has("Total"))
    assert.is_true(has("Sales"))
    assert.is_true(has("× 5"))
    assert.is_false(has("The breakdown of a player's score is visible to that player and to officers."))
    assert.is_true(hasLike("Not counted (1)"))
    assert.same({}, errors)
  end)

  it("an officer sees anyone's breakdown", function()
    officer = true
    click(view.rows[2])
    assert.is_true(has("#2  Brakka"))
    assert.is_true(has("Total"))
    assert.is_false(has("The breakdown of a player's score is visible to that player and to officers."))
    assert.same({}, errors)
  end)

  it("your row is pinned when ranked 14th", function()
    assert.is_true(view.pinned.shown)
    assert.equal("14", view.pinned.rank.text)
    assert.is_truthy(view.pinned.name.text:find("Dor", 1, true))
    assert.equal("Thalwyn", view.rows[1].name.text)
    assert.equal("11", view.rows[11].rank.text)
    -- scrolled until your row is in view, nothing is pinned
    local list = view.list
    local wheel
    for _, c in ipairs(list.calls.SetScript) do if c[1] == "OnMouseWheel" then wheel = c[2] end end
    wheel(list, -1); wheel(list, -1); wheel(list, -1)
    assert.is_false(view.pinned.shown)
    assert.equal("14", view.rows[11].rank.text)
  end)

  describe("a past month", function()
    before_each(function()
      month = {
        month = "2023-10", from = 1, to = 2, goldKept = 15000000, savedBy = "Dor-Realm", savedAt = 1696464000, -- 2023-10-05
        t = 1577923200, -- 2020-01-02: the inverted tie-break time, never shown
        overall = {
          { profile = "p1", name = "Thalwyn-Realm", value = 412, rank = 1 },
          { profile = "p2", name = "Brakka-Realm", value = 388, rank = 2 },
        },
        boards = {},
      }
      hidden.p2 = true
      view:Refresh()
      buttons["Past months"].onClick()
      picked.onPick("2023-10")
    end)

    it("shows saved values and (hidden)", function()
      assert.equal("Thalwyn", view.rows[1].name.text)
      assert.equal("412", view.rows[1].value.text)
      assert.equal("(hidden)", view.rows[2].name.text)
      assert.is_true(has("Gold kept in the guild in October 2023: 1,500 g"))
      assert.is_true(has("Saved 2023-10-05 by Dor"))
      assert.is_nil(view.rows[3].entry or nil)
    end)

    it("shows savedAt and never the record's rec.t", function()
      assert.is_true(hasLike("2023-10-05"))
      for _, t in ipairs(texts) do
        assert.is_falsy(type(t.text) == "string" and t.text:find("2020", 1, true))
        assert.is_falsy(type(t.text) == "string" and t.text:find("1577923200", 1, true))
      end
    end)

    it("offers Retake to officers only, behind a confirmation", function()
      assert.is_false(buttons["Retake"].shown)
      officer = true
      view:Refresh()
      assert.is_true(buttons["Retake"].shown)
      buttons["Retake"].onClick()
      assert.equal("GUILDHALL_LB_RETAKE", popups[1][1])
      assert.equal("2023-10", popups[1][3])
      assert.is_nil(retaken)
      ns.Leaderboard.View.DoRetake("2023-10")
      assert.equal("2023-10", retaken)
    end)
  end)

  it("an empty ledger shows the empty text", function()
    result = { byProfile = {}, guild = {}, goldKept = 0, rows = {} }
    view:Refresh()
    assert.is_true(has("No verified activity yet. Deals made through Exchange listings and guild bank donations will show here."))
    assert.is_false(view.pinned.shown)
    assert.is_true(has("Gold kept in the guild this month: 0 g"))
  end)

  it("live boards leave hidden profiles out but keep them in the guild total", function()
    hidden.p3 = true
    view:Refresh()
    for _, row in ipairs(view.rows) do
      assert.is_falsy(row.name.text and row.name.text:find("Mireth", 1, true))
    end
    assert.equal("Brakka", view.rows[2].name.text)
    assert.equal("3", view.rows[3].rank.text) -- ranks are over the listed profiles
    assert.is_true(has("Gold kept in the guild this month: 4,312 g"))
    assert.is_false(has("(hidden)"))
  end)

  it("uses ASCII for pickers and section headers", function()
    assert.is_true(has("Board: Overall") or buttons["Board: Overall"] ~= nil or view.boardBtn.text == "Board: Overall")
    assert.equal("Board: Overall", view.boardBtn.calls.SetText[#view.boardBtn.calls.SetText][1])
    click(view.pinned)
    assert.is_true(hasLike("- Sales (1)"))
    assert.is_true(hasLike("+ Not counted (1)"))
    for _, t in ipairs(texts) do
      if type(t.text) == "string" then assert.is_falsy(t.text:find("[\226-\244]")) end
    end
  end)

  it("clears stale list text when the selection changes", function()
    click(view.pinned)
    assert.is_true(hasLike("Runecloth"))
    click(view.rows[1])
    assert.is_false(hasLike("Runecloth"))
  end)

  it("shows your own unranked score of 0 when you have no entry", function()
    result.byProfile.p14 = nil
    view:Refresh()
    assert.is_true(has("Your score: 0 points"))
    assert.is_true(hasLike("Not counted (1)"))
    assert.is_false(hasLike("#1  Thalwyn"))
    click(view.rows[1])
    assert.is_true(has("#1  Thalwyn"))
  end)

  it("a past month shows no online dot or status", function()
    month = { month = "2023-10", from = 1, to = 2, goldKept = 0, savedBy = "Dor-Realm", savedAt = 1696464000,
      overall = { { profile = "p1", name = "Thalwyn-Realm", value = 412, rank = 1 } }, boards = {} }
    view:Refresh()
    buttons["Past months"].onClick()
    picked.onPick("2023-10")
    click(view.rows[1])
    assert.is_false(view.d.dot.shown)
    assert.is_false(has("online"))
    assert.is_false(has("offline"))
  end)

  it("shows the reason when a retake fails", function()
    month = { month = "2023-10", from = 1, to = 2, goldKept = 0, savedBy = "Dor-Realm", savedAt = 1696464000,
      overall = {}, boards = {} }
    officer = true
    view:Refresh()
    buttons["Past months"].onClick()
    picked.onPick("2023-10")
    retakeResult, retakeErr = false, "officers only"
    ns.Leaderboard.View.DoRetake("2023-10")
    assert.is_true(has("Retake failed: officers only"))
  end)

  it("words the unpaired reason by row type", function()
    result.rows[#result.rows + 1] = { type = "bank.items", profile = "p14", value = 20, at = NOW - 10, item = "Linen",
      counted = false, why = "unpaired" }
    click(view.pinned)
    view.d.lines[1].toggle = false
    -- open the Not counted list
    for _, l in ipairs(view.d.lines) do
      if l.toggle == "uncounted" then click(l) end
    end
    assert.is_true(hasLike("the other player's client hasn't confirmed it yet"))
    assert.is_true(hasLike("no second guildmate with Guildhall has seen this in the bank log yet"))
  end)

  it("describes items like the mockup and groups collapsed headers on one line", function()
    local r = result.rows
    r[1].counterparty = "Brakka-Realm"
    r[#r + 1] = { type = "exchange.purchases", profile = "p14", value = 1, at = NOW - 500, item = "Silk", counted = true }
    r[#r + 1] = { type = "bank.items", profile = "p14", value = 20, at = NOW - 400, item = "Linen", counted = true }
    click(view.pinned)
    assert.is_true(hasLike("Sold [Runecloth] to Brakka"))
    local a, b
    for _, l in ipairs(view.d.lines) do
      if l.toggle == "exchange.purchases" then a = l end
      if l.toggle == "bank.items" then b = l end
    end
    assert.is_truthy(a and b)
    local function y(l) local c = l.calls.SetPoint; return c[#c][3] end
    assert.equal(y(a), y(b))
    click(b)
    assert.is_true(hasLike("Deposited [Linen] x20"))
  end)

  it("shows the dashed divider only with a pinned row", function()
    assert.is_true(view.dashes[1].shown)
    result = { byProfile = { p1 = { ["exchange.sales"] = 3 }, p14 = { ["exchange.sales"] = 1 } }, guild = {}, goldKept = 0, rows = {} }
    view:Refresh()
    assert.is_false(view.dashes[1].shown)
  end)

  it("refreshes on data events only while visible, at most once a second", function()
    assert.is_true(#handlers >= 4)
    local fn = handlers[1][2]
    view.parent:Hide()
    fn()
    assert.equal(0, #timers)
    view.parent:Show()
    fn(); fn()
    assert.equal(1, #timers) -- one pending refresh, however many events
    result = { byProfile = {}, guild = {}, goldKept = 0, rows = {} }
    timers[1][2]()
    assert.is_true(has("Gold kept in the guild this month: 0 g"))
  end)
end)
