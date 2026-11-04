-- Bank review list under fake frames: who may open it, rows, filters, ticking and unticking.
describe("Leaderboard.BankReview", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, BR, texts, buttons, picked, popups, errors, rows, excl, calls, granted, officer, handlers, setResult
  local GLOBALS = { "CreateFrame", "StaticPopup_Show", "StaticPopupDialogs", "UISpecialFrames" }
  local saved = {}
  local OCT = 1791460800 -- 2026-10-08 12:00 UTC
  local NOV = 1793793600 -- 2026-11-04 12:00 UTC
  local LINK = "|cffffffff|Hitem:2589::::::::1:::::::|h[Linen Cloth]|h|r"

  local function isAllowed(s)
    s = s:gsub("\194\183", ""):gsub("\195\151", "")
    return not s:find("[\128-\255]")
  end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    _G.StaticPopupDialogs = {}
    _G.UISpecialFrames = {}
    popups = {}
    _G.StaticPopup_Show = function(which, a, b, data) popups[#popups + 1] = { which = which, data = data } end
    texts, buttons, errors, calls, handlers, picked = {}, {}, {}, {}, {}, nil
    granted, officer, setResult = true, false, true
    excl = {}
    rows = {
      { type = "bank.gold", char = "Bob-Realm", profile = "pBob", value = 505000, at = NOV, ref = "bank:o1", counted = true },
      { type = "bank.items", char = "Cat-Realm", profile = "pCat", value = -3, item = LINK, tab = 2, at = NOV - 3600,
        ref = "bank:o2", counted = false, why = "unpaired" },
      { type = "bank.items", char = "Bob-Realm", profile = "pBob", value = 20, item = LINK, tab = 1, at = OCT,
        ref = "bank:o3", counted = true },
      { type = "bank.gold", char = "Alt-Realm", value = 10000, at = OCT - 60, ref = "bank:o4", counted = false,
        why = "rank excluded" },
    }
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Config.lua")
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.Events = { On = function(_, event, fn) handlers[#handlers + 1] = { event, fn } end }
    ns.UI = {
      NO_GUILD_TEXT = "Join a guild to use Guildhall",
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
      CreatePanel = function() return W.CreateFrame("Frame") end,
    }
    local names = { pBob = "Bob-Realm", pCat = "Cat-Realm" }
    ns.services = {
      now = function() return NOV + 86400 end, playerChar = "Gm-Realm",
      roster = { IsOfficer = function() return officer end },
      compat = { ServerOffset = function() return 0 end, SecondsUntilWeeklyReset = function() return nil end },
      profile = {
        OnlineChar = function(_, id) return names[id] end,
        CharsOf = function(_, id) return { names[id] } end,
      },
      after = function(_, cb) cb() end,
    }
    ns.leaderboard = {
      permissions = { Can = function(_, _, key) return key == "bankreview" and granted end },
      ledger = { Query = function(_, q)
        calls[#calls + 1] = { "Query", q }
        local out = {}
        for i, r in ipairs(rows) do
          local c = {}
          for k, v in pairs(r) do c[k] = v end
          out[i] = c
        end
        return { byProfile = {}, guild = {}, rows = out }
      end },
      config = {
        Tz = function() return 0 end,
        Exclusions = function() return excl end,
        SetExcluded = function(_, ref, on, reason)
          calls[#calls + 1] = { "SetExcluded", ref, on, reason }
          if setResult then
            if on then excl[ref] = { excluded = true, reason = reason, by = "Gm-Realm", at = 1 } else excl[ref] = nil end
          end
          return setResult, (not setResult) and "not accepted" or nil
        end,
      },
    }
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/UI/BankReview.lua")
    BR = ns.Leaderboard.BankReview
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function handler(w, event)
    local h
    for _, c in ipairs(w.calls.SetScript or {}) do if c[1] == event then h = c[2] end end
    return h
  end
  local function click(w) handler(w, "OnClick")(w) end
  local function shownRefs()
    local out = {}
    for _, line in ipairs(BR._panel().lines) do
      if line.shown and line.row then out[#out + 1] = line.row.ref end
    end
    return out
  end
  local function lineOf(ref)
    for _, line in ipairs(BR._panel().lines) do
      if line.shown and line.row and line.row.ref == ref then return line end
    end
  end
  local function setCalls()
    local out = {}
    for _, c in ipairs(calls) do if c[1] == "SetExcluded" then out[#out + 1] = c end end
    return out
  end

  it("the review list is refused without bankreview", function()
    granted = false
    local ok, err = BR.Open()
    assert.is_false(ok)
    assert.equal("Your rank can't review bank contributions. The guild master sets this under Settings > Permissions.", err)
    assert.is_nil(BR._panel())
    assert.equal(0, #W.created)
  end)

  it("lists every bank row newest first, with date, name, action, amount, tab and status", function()
    assert.is_true(BR.Open())
    local q = calls[1][2]
    assert.is_true(q.includeUncounted)
    assert.same({ ["bank.gold"] = true, ["bank.items"] = true }, q.types)
    assert.same({ "bank:o1", "bank:o2", "bank:o3", "bank:o4" }, shownRefs())
    local l1, l2, l4 = lineOf("bank:o1"), lineOf("bank:o2"), lineOf("bank:o4")
    assert.equal("2026-11-04 12:00", l1.cells.date:GetText())
    assert.equal("Bob", l1.cells.char:GetText())
    assert.equal("deposited", l1.cells.action:GetText())
    assert.equal("50 g 50 s", l1.cells.amount:GetText())
    assert.equal("Money", l1.cells.tab:GetText())
    assert.equal("counted", l1.cells.status:GetText())
    assert.is_true(l1.check.checked)
    assert.equal("withdrew", l2.cells.action:GetText())
    assert.equal(LINK .. " x3", l2.cells.amount:GetText())
    assert.equal("Tab 2", l2.cells.tab:GetText())
    assert.equal("not verified yet", l2.cells.status:GetText())
    assert.equal("rank excluded", l4.cells.status:GetText())
    assert.same({}, errors)
  end)

  it("filters by player and month", function()
    BR.Open()
    BR._panel().playerBtn.onClick()
    local labels = {}
    for _, it in ipairs(picked.items) do labels[#labels + 1] = it.label end
    assert.same({ "All players", "Alt", "Bob", "Cat" }, labels)
    picked.onPick("p:pBob")
    assert.same({ "bank:o1", "bank:o3" }, shownRefs())
    assert.equal("Bob", BR._panel().playerBtn:GetText())
    BR._panel().monthBtn.onClick()
    labels = {}
    for _, it in ipairs(picked.items) do labels[#labels + 1] = it.label end
    assert.same({ "All months", "November 2026", "October 2026" }, labels)
    picked.onPick("2026-10")
    assert.same({ "bank:o3" }, shownRefs())
    -- back to all players: both October entries
    BR._panel().playerBtn.onClick()
    picked.onPick(false)
    assert.same({ "bank:o3", "bank:o4" }, shownRefs())
    assert.equal("All players", BR._panel().playerBtn:GetText())
  end)

  it("filters by tab and by excluded only", function()
    excl["bank:o3"] = { excluded = true, reason = "moving guild funds", by = "Gm-Realm", at = 1 }
    rows[3].counted, rows[3].why, rows[3].reason = false, "excluded by an officer", "moving guild funds" -- as the Ledger marks it
    BR.Open()
    local p = BR._panel()
    p.tabBtn.onClick()
    local labels = {}
    for _, it in ipairs(picked.items) do labels[#labels + 1] = it.label end
    assert.same({ "All tabs", "Money", "Tab 1", "Tab 2" }, labels)
    picked.onPick("money")
    assert.same({ "bank:o1", "bank:o4" }, shownRefs())
    picked.onPick(1)
    assert.same({ "bank:o3" }, shownRefs())
    picked.onPick(false)
    p.excludedOnly:SetChecked(true)
    click(p.excludedOnly)
    assert.same({ "bank:o3" }, shownRefs())
    assert.is_false(lineOf("bank:o3").check.checked)
    assert.equal("excluded: moving guild funds", lineOf("bank:o3").cells.status:GetText())
  end)

  it("shows who excluded an entry only to officers", function()
    excl["bank:o1"] = { excluded = true, by = "Gm-Realm", at = 1 }
    BR.Open()
    assert.equal("counted, excluded", lineOf("bank:o1").cells.status:GetText())
    officer = true
    BR.Refresh()
    assert.equal("counted, excluded (Gm)", lineOf("bank:o1").cells.status:GetText())
  end)

  it("unticking asks why, then excludes; Cancel changes nothing; ticking counts it again with no prompt", function()
    BR.Open()
    local check = lineOf("bank:o1").check
    check:SetChecked(false) -- the click toggles it first, as in the client
    click(check)
    assert.is_true(check.checked) -- stays ticked until the prompt is accepted
    assert.equal(1, #popups)
    assert.equal("GUILDHALL_BANK_EXCLUDE", popups[1].which)
    assert.equal("bank:o1", popups[1].data)
    assert.same({}, setCalls())
    local dlg = StaticPopupDialogs.GUILDHALL_BANK_EXCLUDE
    assert.equal("Why doesn't this count? (optional)", dlg.text)
    assert.equal(80, dlg.maxLetters)
    -- Cancel
    dlg.OnCancel()
    assert.same({}, setCalls())
    -- OK with a reason
    local box = W.new("EditBox")
    box:SetText("moving guild funds")
    dlg.OnAccept({ editBox = box }, "bank:o1")
    assert.same({ { "SetExcluded", "bank:o1", true, "moving guild funds" } }, setCalls())
    assert.is_false(lineOf("bank:o1").check.checked)
    -- tick it again
    check = lineOf("bank:o1").check
    check:SetChecked(true)
    click(check)
    assert.equal(1, #popups)
    assert.same({ "SetExcluded", "bank:o1", false }, setCalls()[2])
    assert.is_true(lineOf("bank:o1").check.checked)
    assert.same({}, errors)
  end)

  it("Enter in the reason box excludes and closes the prompt", function()
    BR.Open()
    local dlg = StaticPopupDialogs.GUILDHALL_BANK_EXCLUDE
    local parent = W.new("Frame")
    local box = W.new("EditBox")
    box.GetParent = function() return parent end
    box:SetText("x")
    dlg.EditBoxOnEnterPressed(box, "bank:o2")
    assert.same({ { "SetExcluded", "bank:o2", true, "x" } }, setCalls())
    assert.is_not_nil(parent.calls.Hide)
  end)

  it("a refused change shows why and leaves the box as it was", function()
    BR.Open()
    setResult = false
    BR.DoExclude("bank:o1", "x")
    assert.is_true(lineOf("bank:o1").check.checked)
    assert.equal("Couldn't save the change: not accepted.", BR._panel().status:GetText())
  end)

  it("shows the empty state", function()
    rows = {}
    BR.Open()
    local p = BR._panel()
    assert.is_true(p.empty.shown)
    assert.equal("No guild bank activity recorded yet. Entries appear after someone with Guildhall opens the guild bank.",
      p.empty:GetText())
    assert.same({}, shownRefs())
  end)

  it("shows 14 rows and scrolls with the mouse wheel", function()
    rows = {}
    for i = 1, 20 do
      rows[i] = { type = "bank.gold", char = "Bob-Realm", profile = "pBob", value = 10000 * i, at = NOV - i * 60,
        ref = "bank:s" .. i, counted = true }
    end
    BR.Open()
    local p = BR._panel()
    assert.equal(14, #p.lines)
    assert.equal(14, #shownRefs())
    assert.equal("bank:s1", shownRefs()[1])
    handler(p.list, "OnMouseWheel")(p.list, -1)
    assert.equal("bank:s2", shownRefs()[1])
    handler(p.list, "OnMouseWheel")(p.list, -100)
    assert.equal("bank:s7", shownRefs()[1])
    assert.equal(14, #shownRefs())
    handler(p.list, "OnMouseWheel")(p.list, 100)
    assert.equal("bank:s1", shownRefs()[1])
  end)

  it("builds its frames once and refreshes on data events while shown", function()
    BR.Open()
    local n = #W.created
    BR.Open()
    assert.equal(n, #W.created)
    assert.is_true(#handlers >= 4)
    rows[#rows + 1] = { type = "bank.gold", char = "Dan-Realm", value = 1, at = NOV + 10, ref = "bank:o9", counted = true }
    for _, h in ipairs(handlers) do if h[1] == "LeaderboardConfigChanged" then h[2]() end end
    assert.equal("bank:o9", shownRefs()[1])
  end)

  it("lists demo rows read-only", function()
    ns.leaderboard.demo = true
    BR.Open()
    local line = lineOf("bank:o1")
    assert.is_not_nil(line.check.calls.Disable)
    assert.is_nil(line.check.calls.Enable)
    line.check:SetChecked(false)
    click(line.check)
    assert.same({}, popups)
    assert.same({}, setCalls())
    assert.is_false(BR.DoExclude("bank:o1", "x"))
    assert.same({}, setCalls())
  end)

  it("UI strings use allowed glyphs only", function()
    BR.Open()
    for _, t in ipairs(texts) do assert.is_true(isAllowed(tostring(t.text)), tostring(t.text)) end
    for _, path in ipairs({ "Guildhall/Core/Leaderboard/UI/BankReview.lua", "Guildhall/Core/Leaderboard/UI/View.lua",
      "Guildhall/Core/Leaderboard/Config.lua", "Guildhall/Core/Leaderboard/Ledger.lua" }) do
      local f = assert(io.open(path)); local src = f:read("*a"); f:close()
      for str in src:gmatch('"([^"\n]*)"') do assert.is_true(isAllowed(str), path .. ": " .. str) end
    end
  end)

  it("a member's excluded and unpaired rows appear under one player entry (real Ledger)", function()
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Ledger.lua")
    ns.Observations = { KINDS = { bank = true } }
    ns.Activity.Register({ id = "bank.gold", label = "Bank gold", unit = "gold", verify = "paired", weight = 0.2, order = 60 })
    local contribs = {
      { type = "bank.gold", char = "Bob-Realm", value = 10000, at = NOV, ref = "bank:a", counted = true, net = true },
      { type = "bank.gold", char = "Bob-Realm", value = 20000, at = NOV - 60, ref = "bank:b", counted = false,
        why = "unpaired", net = true },
      { type = "bank.gold", char = "Cat-Realm", value = 30000, at = NOV - 120, ref = "bank:c", counted = true, net = true },
    }
    ns.Activity.RegisterDeriver("bank", function() return contribs end)
    excl["bank:a"] = { excluded = true, reason = "moving guild funds", by = "Gm-Realm", at = 1 }
    local owners = { ["Bob-Realm"] = "pBob", ["Cat-Realm"] = "pCat" }
    ns.leaderboard.ledger = ns.Ledger.new({
      observations = { List = function() return { {} } end, changes = 0 },
      profile = {
        OwnerOf = function(_, ch) return owners[ch] end,
        CharsOf = function(_, id) return id == "pBob" and { "Bob-Realm" } or { "Cat-Realm" } end,
      },
      roster = { RankIndex = function() return nil end, ConfigList = function() return {} end },
      now = ns.services.now, config = ns.leaderboard.config,
    })
    BR.Open()
    BR._panel().playerBtn.onClick()
    local labels = {}
    for _, it in ipairs(picked.items) do labels[#labels + 1] = it.label end
    assert.same({ "All players", "Bob", "Cat" }, labels)
    picked.onPick("p:pBob")
    assert.same({ "bank:a", "bank:b" }, shownRefs())
    assert.equal("excluded: moving guild funds", lineOf("bank:a").cells.status:GetText())
    assert.equal("not verified yet", lineOf("bank:b").cells.status:GetText())
    assert.same({}, errors)
  end)
end)
