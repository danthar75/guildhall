-- Groups tab under fake frames: the board, details, Ready now and history.
describe("Groups.View", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, view, texts, buttons, picked, errors, handlers, chat, invited, searched, formOpened
  local posts, signups, events, ready, kills, rows, canKey, night, flexStatus, assigned, confirmed, asked, personal
  local NOW = 1699999999 -- 2023-11-14 22:46:39 UTC
  local GLOBALS = { "CreateFrame", "InviteUnit", "C_PartyInfo" }
  local saved = {}

  local NAMES = { p1 = "Dor-R", p2 = "Brakka-R", p3 = "Mireth-R", p4 = "Thalwyn-R" }
  local ONLINE = { p1 = true, p2 = true }

  local function post(id, by, d, exp)
    d.created = d.created or NOW - 600
    return { id = id, by = by, char = NAMES[by], v = 1, t = d.created, exp = exp or NOW + 3600, d = d }
  end

  -- The Groups service's own Filled rule (the poster fills their role, then each assignment).
  local function filled(p)
    local d = p.d
    local out = { t = {}, h = {}, d = {}, open = {} }
    out[d.role][1] = p.by
    for pid, role in pairs(d.assign or {}) do
      if pid ~= p.by then table.insert(out[role], pid) end
    end
    for _, r in ipairs({ "t", "h", "d" }) do
      local n = #out[r] - (d.role == r and 1 or 0)
      out.open[r] = math.max(0, d.need[r] - n)
    end
    return out
  end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    invited = 0
    _G.InviteUnit = function() invited = invited + 1 end
    _G.C_PartyInfo = { InviteUnit = function() invited = invited + 1 end }
    texts, buttons, errors, handlers, picked, chat = {}, {}, {}, {}, nil, {}
    posts, signups, events, ready, kills, rows = {}, {}, {}, {}, {}, {}
    canKey, night, flexStatus, assigned, confirmed, asked = {}, {}, {}, {}, {}, {}
    searched, formOpened = nil, nil
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Credit.lua")
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
        local b = W.new("Button"); b.onClick = onClick; buttons[text] = b; b.text = text; b.shown = true; return b
      end,
      PickList = function(anchor, items, onPick, current)
        picked = { anchor = anchor, items = items, onPick = onPick, current = current }
      end,
    }
    ns.ExchangeUI = {
      Search = function(text) searched = text end,
      OpenForm = function(prefill) formOpened = prefill end,
    }
    local profile = {
      Id = function() return "p1" end,
      IsHidden = function() return false end,
      OnlineChar = function(_, id) return ONLINE[id] and NAMES[id] or nil end,
      CharsOf = function(_, id) return { NAMES[id] } end,
      OwnerOf = function(_, ch) for p, n in pairs(NAMES) do if n == ch then return p end end end,
      set = { Get = function() return nil end },
    }
    ns.services = {
      now = function() return NOW end, playerChar = "Dor-R", profile = profile,
      roster = { IsMember = function() return true end, IsOnline = function() return false end },
      compat = {
        ServerOffset = function() return 0 end,
        SecondsUntilWeeklyReset = function() return nil end,
        OpenChat = function(_, text) chat[#chat + 1] = text end,
        GroupSnapshot = function() return nil end,
        PlayerLevel = function() return 60 end,
        ItemName = function() return nil end,
      },
      after = function(_, cb) cb() end,
    }
    personal = { groups = { roles = { d = true } } }
    _G.GuildhallDB = { personal = personal }
    ns.leaderboard = {
      permissions = { Can = function(_, _, key) return canKey[key] == true end },
      config = { Tz = function() return 0 end },
      observations = { changes = 1, List = function(_, kind) return kind == "kill" and kills or {} end },
      ledger = { Query = function() return { rows = rows } end },
    }
    local svc = {
      Posts = function() return posts end,
      Signups = function(_, id) return signups[id] or {} end,
      Filled = function(_, p) return filled(p) end,
      Ready = function() return ready end,
      Assign = function(_, id, pid, role) assigned[#assigned + 1] = { id, pid, role }; return true end,
      SignUp = function() return true end,
      Withdraw = function() return true end,
      Close = function() return true end,
      SetReady = function(_, roles, level, secs) ready.set = { roles, level, secs }; return true end,
      ClearReady = function() ready.cleared = true; return true end,
      profile = profile,
    }
    ns.groups = {
      svc = svc,
      calendar = { Events = function() return events end, Attendees = function() return {} end },
      checklist = {
        List = function() return {} end,
        Active = function() return nil end,
        Night = function() return night end,
        SelfCheck = function() return { lines = {} } end,
        ConfirmTicks = function(_, inst, boxes) confirmed[#confirmed + 1] = { inst, boxes }; return 1 end,
      },
      flex = {
        Status = function() return flexStatus end,
        Ask = function(_, char, inst) asked[#asked + 1] = { char, inst }; return true, "a1" end,
        Tick = function() return true end,
      },
      credit = { Bosses = function() return 0 end },
    }
    loadAddonFile(ns, "Guildhall/Modules/Groups/UI/Details.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/UI/View.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
    _G.GuildhallDB = nil
  end)

  local function build()
    local parent = W.new("Frame")
    parent:Show()
    view = ns.Groups.View.Build(parent)
    view:Refresh()
    return view
  end

  local function has(s)
    for _, t in ipairs(texts) do if t.text == s and t.shown then return true end end
    return false
  end
  local function hasLike(s)
    for _, t in ipairs(texts) do
      if t.shown and type(t.text) == "string" and t.text:find(s, 1, true) then return true end
    end
    return false
  end
  local function click(w, ...)
    if rawget(w, "onClick") then return w.onClick(w, ...) end
    local h
    for _, c in ipairs(w.calls.SetScript or {}) do if c[1] == "OnClick" then h = c[2] end end
    return h(w, ...)
  end
  local function shownRows()
    local out = {}
    for _, r in ipairs(view.rows) do
      if r.shown then out[#out + 1] = r end
    end
    return out
  end
  local function pick(label)
    for _, it in ipairs(picked.items) do
      if it.label == label then return picked.onPick(it.value, it) end
    end
    error("no item " .. label)
  end

  local STRAT = { instance = "strat_ud", role = "t", need = { t = 0, h = 1, d = 3 }, note = "fast run", want = "Arcanite Bar" }

  -- The brief's six tests ------------------------------------------------------------------

  it("Now posts list before scheduled, calendar events tagged", function()
    posts = {
      post("p2:g1_1", "p2", { instance = "strat_ud", role = "t", need = { t = 0, h = 1, d = 3 } }),
      post("p3:g1_1", "p3", { instance = "mc", role = "h", need = { t = 2, h = 7, d = 29 }, start = NOW + 7200 }),
    }
    events = { { title = "BWL night", start = NOW + 3600, instance = "bwl", source = "Calendar", accepted = 3 } }
    build()
    local r = shownRows()
    assert.equal(5, #r)
    assert.equal("NOW", r[1].name.text)
    assert.equal("Stratholme (Undead) · Brakka", r[2].name.text)
    assert.equal("SCHEDULED", r[3].name.text)
    assert.is_truthy(r[4].name.text:find("BWL night", 1, true))
    assert.is_truthy(r[4].tags.text:find("Calendar", 1, true))
    assert.is_truthy(r[5].name.text:find("Molten Core", 1, true))
    assert.is_falsy(r[5].tags.text:find("Calendar", 1, true))
    assert.same({}, errors)
  end)

  it("a filled slot shows full", function()
    posts = { post("p2:g1_1", "p2", { instance = "strat_ud", role = "t", need = { t = 0, h = 1, d = 3 },
      assign = { p3 = "h" } }) }
    build()
    local tags = shownRows()[2].tags.text
    assert.is_truthy(tags:find("T full", 1, true))
    assert.is_truthy(tags:find("H full", 1, true))
    assert.is_truthy(tags:find("D 3", 1, true))
    assert.same({}, errors)
  end)

  it("Invite fills the chat box and calls no invite API", function()
    posts = { post("p1:g1_1", "p1", STRAT) }
    signups["p1:g1_1"] = { { profile = "p2", char = "Brakka-R", roles = { h = true, d = true }, at = NOW - 60 } }
    build()
    assert.is_true(has("Signups waiting"))
    local row = view.d.signRows[1]
    assert.is_true(row.shown)
    assert.equal("Brakka", row.name.text)
    click(row.invite)
    assert.same({ "/invite Brakka" }, chat)
    assert.equal(0, invited)
    -- the poster's role buttons assign the signup
    click(row.roles.h)
    assert.same({ { "p1:g1_1", "p2", "h" } }, assigned)
    assert.same({}, errors)
  end)

  it("Prepared checkbox disabled without permission", function()
    posts = { post("p3:g1_1", "p3", { instance = "mc", role = "h", need = { t = 2, h = 7, d = 29 }, start = NOW + 600 }) }
    signups["p3:g1_1"] = { { profile = "p2", char = "Brakka-R", roles = { d = true }, at = NOW - 60 } }
    night = { ["Brakka-R"] = { ok = true, miss = 0 } }
    build()
    local row = view.d.roster[1]
    assert.is_true(row.shown)
    assert.equal(true, row.check.checked) -- pre-ticked from the raider's own check
    assert.is_not_nil(row.check.calls.Disable)
    assert.is_nil(row.check.calls.Enable)
    assert.is_false(buttons["Confirm all checked"].shown)
    assert.is_false(buttons["Edit checklist"].shown)

    canKey.prepared, canKey.checklists = true, true
    view:Refresh()
    assert.is_not_nil(row.check.calls.Enable)
    assert.is_true(buttons["Confirm all checked"].shown)
    assert.is_true(buttons["Edit checklist"].shown)
    -- the leader unticks Brakka, then ticks him again: a change; Mireth (the poster, no check) untouched
    row.check:SetChecked(false); click(row.check)
    row.check:SetChecked(true); click(row.check)
    click(buttons["Confirm all checked"])
    assert.equal(1, #confirmed)
    assert.equal("mc", confirmed[1][1])
    assert.same({ ["Brakka-R"] = { checked = true, changed = true }, ["Mireth-R"] = { checked = false, changed = false } },
      confirmed[1][2])
    assert.same({}, errors)
  end)

  it("history line reads 'Strat UD cleared by Dor, Brakka and 3 more, 42 min'", function()
    local members = { "Dor-R", "Brakka-R", "Mireth-R", "Thalwyn-R", "Vex-R" }
    kills = {
      { id = "o1", by = "p1", char = "Dor-R", d = { kind = "kill", instance = "strat_ud", encounter = 484,
        members = members, at = NOW - 3600, dur = 2520 } },
      { id = "o2", by = "p2", char = "Brakka-R", d = { kind = "kill", instance = "strat_ud", encounter = 484,
        members = members, at = NOW - 3590 } },
    }
    build()
    click(buttons["History"])
    click(buttons["Guild"])
    assert.is_true(has("Strat UD cleared by Dor, Brakka and 3 more, 42 min"))
    assert.same({}, errors)
  end)

  it("the Exchange link calls Search with the item", function()
    posts = { post("p2:g1_1", "p2", STRAT) }
    build()
    assert.equal("Needs: [Arcanite Bar]", view.d.needs.label.text)
    click(view.d.needs)
    assert.equal("Arcanite Bar", searched)
    assert.same({}, errors)
  end)

  -- More ------------------------------------------------------------------------------------

  it("shows the empty state when nothing is posted", function()
    build()
    assert.is_true(has("No runs posted. Post one, or mark yourself Ready now so guildmates know."))
    assert.same({}, errors)
  end)

  it("the dungeon details read as the brief says", function()
    posts = { post("p2:g1_1", "p2", STRAT) }
    build()
    assert.is_true(has("Stratholme (Undead) · Now"))
    assert.is_true(has("Posted by Brakka 10 min ago · \"fast run\""))
    assert.is_true(has("Group (1 of 5) · 1 online"))
    assert.is_true(has("Credit when the group kills the last boss with 3+ guild members. Once per dungeon per player per day."))
    assert.is_true(buttons["Sign up"].shown)
    assert.is_false(buttons["Close post"].shown)
    click(buttons["Sign up"])
    local labels = {}
    for _, it in ipairs(picked.items) do labels[#labels + 1] = it.label end
    assert.same({ "Tank", "Healer", "DPS" }, labels)
    assert.same({}, errors)
  end)

  it("the poster gets Post LF on Exchange, Copy for chat and Close post", function()
    posts = { post("p1:g1_1", "p1", STRAT) }
    build()
    assert.is_true(buttons["Close post"].shown)
    assert.is_false(buttons["Sign up"].shown)
    click(buttons["Post LF on Exchange"])
    assert.same({ kind = "LF", item = "Arcanite Bar" }, formOpened)
    click(buttons["Copy for chat"])
    assert.equal(1, #chat)
    assert.is_truthy(chat[1]:find("Stratholme (Undead)", 1, true))
    assert.same({}, errors)
  end)

  it("Ready now shows up to 4 names with roles, then +N more", function()
    for i, p in ipairs({ "p1", "p2", "p3", "p4" }) do
      ready[i] = { profile = p, char = NAMES[p], roles = { d = true, t = i == 2 or nil }, level = 60,
        exp = NOW + 3600 * i, at = NOW }
    end
    ready[5] = { profile = "p5", char = "Vex-R", roles = { h = true }, level = 60, exp = NOW + 60, at = NOW }
    NAMES.p5 = "Vex-R"
    build()
    NAMES.p5 = nil
    assert.equal("Dor (D) · 1 h", view.ready.slots[1].text.text)
    assert.equal("Brakka (T/D) · 2 h", view.ready.slots[2].text.text)
    assert.equal("+1 more", view.ready.more.text)
    assert.same({}, errors)
  end)

  it("I'm ready now picks roles and a window, or Not ready", function()
    build()
    click(buttons["I'm ready now"])
    pick("Healer")
    assert.same({ { h = true }, 60, 7200 }, ready.set)
    click(buttons["I'm ready now"])
    pick("Free for 4 h")
    assert.equal(14400, ready.set[3])
    click(buttons["I'm ready now"])
    pick("Not ready")
    assert.is_true(ready.cleared)
    assert.same({}, errors)
  end)

  it("Mine shows uncounted runs greyed with a plain reason", function()
    rows = {
      { type = "groups.dungeon", profile = "p1", char = "Dor-R", at = NOW - 7200, counted = true,
        ref = "kill:strat_ud:484:2023-11-14:Dor-R:groups.dungeon" },
      { type = "groups.dungeon", profile = "p1", char = "Dor-R", at = NOW - 3600, counted = false,
        why = "not verified", ref = "kill:rfc:2733:2023-11-14:Dor-R:groups.dungeon" },
      { type = "groups.dungeon", profile = "p2", char = "Brakka-R", at = NOW - 3600, counted = true,
        ref = "kill:rfc:2733:2023-11-14:Brakka-R:groups.dungeon" },
    }
    build()
    click(buttons["History"])
    assert.is_true(has("Your last runs"))
    local line = view.hist.lines[1]
    assert.equal("Cleared RFC, no second Guildhall player saw it", line.text.text)
    assert.is_not_nil(line.text.calls.SetTextColor)
    local c = line.text.calls.SetTextColor[#line.text.calls.SetTextColor]
    assert.same({ 0.62, 0.62, 0.62 }, { c[1], c[2], c[3] })
    assert.equal("Cleared Strat UD", view.hist.lines[2].text.text)
    assert.is_false(view.hist.lines[3].shown)
    assert.is_false(hasLike("not verified"))
    assert.same({}, errors)
  end)

  it("refreshes on GroupsChanged, ObservationsChanged and the config events", function()
    build()
    local events = {}
    for _, h in ipairs(handlers) do events[h[1]] = true end
    for _, e in ipairs({ "GroupsChanged", "ObservationsChanged", "LeaderboardConfigChanged", "RosterRefreshed",
      "ProfilesChanged" }) do
      assert.is_true(events[e], e)
    end
    posts = { post("p2:g1_1", "p2", STRAT) }
    for _, h in ipairs(handlers) do if h[1] == "GroupsChanged" then h[2]() end end
    assert.equal("Stratholme (Undead) · Brakka", shownRows()[2].name.text)
  end)

  it("Ask to switch asks the raider; a finished switch reads Switched", function()
    posts = { post("p3:g1_1", "p3", { instance = "mc", role = "h", need = { t = 2, h = 7, d = 29 }, start = NOW + 600 }) }
    signups["p3:g1_1"] = { { profile = "p2", char = "Brakka-R", roles = { d = true }, at = NOW - 60 } }
    canKey.flex = true
    build()
    local row = view.d.roster[1]
    assert.equal("Ask to switch", row.flex.text)
    click(row.flex)
    assert.same({ { "Brakka-R", "mc" } }, asked)
    flexStatus = { ["Brakka-R"] = { ask = "a1", mine = true, done = true } }
    view:Refresh()
    assert.is_false(row.flex.shown)
    assert.equal("Switched", row.flexText.text)
    assert.same({}, errors)
  end)

  it("an item the client hasn't cached reads 'Needs: item' and searches nothing", function()
    posts = { post("p2:g1_1", "p2", { instance = "strat_ud", role = "t", need = { t = 0, h = 1, d = 3 }, want = 12345 }) }
    build()
    assert.equal("Needs: item", view.d.needs.label.text)
    click(view.d.needs)
    assert.is_nil(searched)
    assert.same({}, errors)
  end)

  it("with 5 signups waiting, +N more sits on the header line and nothing overlaps", function()
    posts = { post("p1:g1_1", "p1", STRAT) }
    local list = {}
    for i = 1, 5 do
      list[i] = { profile = "x" .. i, char = "Pug" .. i .. "-R", roles = { d = true }, at = NOW - 60 + i }
    end
    signups["p1:g1_1"] = list
    build()
    local d, L = view.d, ns.Groups.Details.LAYOUT
    assert.equal("+2 more", d.signMore.text)
    assert.is_true(d.signMore.shown)
    local function topOf(w)
      local c = w.calls.SetPoint[#w.calls.SetPoint]
      return -c[3]
    end
    -- "+N more" is on the header's line, at the right
    assert.equal("TOPRIGHT", d.signMore.calls.SetPoint[#d.signMore.calls.SetPoint][1])
    assert.is_true(math.abs(topOf(d.signMore) - topOf(d.signHead)) <= 4)
    -- the last signup row ends before the footnote, and the footnote before the buttons
    local last = d.signRows[#d.signRows]
    assert.is_true(last.shown)
    local lastBottom = topOf(last) + L.signRow
    assert.is_true(lastBottom <= topOf(d.foot), "rows overlap the footnote")
    assert.is_true(topOf(d.foot) + L.footH <= L.panel - L.buttonGap - L.button, "footnote overlaps the buttons")
    assert.same({}, errors)
  end)
end)
