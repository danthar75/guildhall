-- Settings tab: the sub-tabs, the shared Change history view, the Permissions grid's raid-leader
-- column for the group finder keys, and the Groups settings.
local fakes = require("spec.helpers.fakes")

local GLOBALS = { "CreateFrame", "GuildhearthDB", "GetItemInfo" }

local function handler(w, event)
  local h
  for _, c in ipairs(w.calls.SetScript or {}) do if c[1] == event then h = c[2] end end
  return h
end

local function click(w, ...)
  if rawget(w, "onClick") then return w.onClick(w, ...) end
  return handler(w, "OnClick")(w, ...)
end

local function fakeUI(ns, W, texts, buttons, errors)
  ns.OnError = function(e) errors[#errors + 1] = e end
  ns.UI = {
    NO_GUILD_TEXT = "Join a guild",
    Try = function(fn, ...)
      local ok, res = pcall(fn, ...)
      if not ok then ns.OnError(res); return nil end
      return res
    end,
    Text = function(_, _, text)
      local t = W.new("FontString"); t.text = text; t.shown = true; texts[#texts + 1] = t; return t
    end,
    Button = function(_, text, _, onClick)
      local b = W.new("Button"); b.onClick = onClick; b.shown = true; buttons[text] = b; return b
    end,
    Personal = function()
      local sv = _G.GuildhearthDB
      if type(sv) ~= "table" or type(sv.personal) ~= "table" then return nil end
      return sv.personal
    end,
  }
end

describe("Settings sub-tabs", function()
  local ns, W, texts, buttons, errors, built
  local saved = {}

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    texts, buttons, errors, built = {}, {}, {}, {}
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    fakeUI(ns, W, texts, buttons, errors)
    local function section(name)
      return function(parent)
        local obj = { parent = parent, refreshed = 0 }
        function obj.refresh() obj.refreshed = obj.refreshed + 1 end
        built[name] = obj
        return obj
      end
    end
    local mods = {
      Leaderboard = { settings = { title = "Leaderboard", build = section("Leaderboard") } },
      Groups = { settings = { title = "Groups", build = section("Groups") } },
    }
    ns.Modules = function() return { "Leaderboard", "Groups" } end
    ns.GetModule = function(name) return mods[name] end
    ns.UI.PermissionsView = { Build = section("Permissions") }
    ns.UI.HistoryView = { Build = section("Change history") }
    loadAddonFile(ns, "Guildhearth/Core/UI/SettingsView.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  it("shows General, Leaderboard, Groups, Permissions and Change history, in that order", function()
    local view = ns.UI.SettingsView.Build(W.new("Frame"))
    assert.same({ "General", "Leaderboard", "Groups", "Permissions", "Change history" }, view.tabKeys)
    for _, key in ipairs(view.tabKeys) do assert.is_truthy(buttons[key], key) end
    view.refresh()
    assert.is_true(view.panes.General.shown)
    for _, key in ipairs({ "Leaderboard", "Groups", "Permissions", "Change history" }) do
      assert.is_false(view.panes[key].shown, key)
    end
    -- the core lines stay under General
    assert.is_truthy(view.info.text:find("not in a guild", 1, true))
    click(buttons["Change history"])
    assert.is_true(view.panes["Change history"].shown)
    assert.is_false(view.panes.General.shown)
    assert.is_true(built["Change history"].refreshed >= 1)
    click(buttons["Groups"])
    assert.is_true(view.panes.Groups.shown)
    assert.is_false(view.panes["Change history"].shown)
    -- each module section is built inside its own sub-tab
    assert.is_truthy(built.Groups.parent)
    assert.are_not.equal(built.Groups.parent, built.Leaderboard.parent)
    assert.same({}, errors)
  end)

  it("a section that fails to build says so and is retried once services exist", function()
    local tries = 0
    ns.UI.PermissionsView = { Build = function()
      tries = tries + 1
      if not ns.services then error("no guild services yet") end
      return {}
    end }
    local view = ns.UI.SettingsView.Build(W.new("Frame"))
    assert.equal(1, tries)
    local found = false
    for _, t in ipairs(texts) do if t.text == "These settings could not be loaded yet." then found = true end end
    assert.is_true(found)
    ns.services = { guildKey = "g", profile = { Id = function() return "p1" end, GuildChars = function() return {} end },
      roster = { OfficerThreshold = function() return 2 end } }
    click(buttons["Permissions"])
    assert.equal(2, tries)
    assert.equal(1, #errors) -- the first failure is reported once
  end)
end)

describe("Change history view", function()
  local ns, W, texts, buttons, errors, history, ranks, officer, granted, view
  local saved = {}

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    texts, buttons, errors, history, granted = {}, {}, {}, {}, {}
    ranks = { ["Boss-Realm"] = 0, ["Dor-Realm"] = 1, ["Vet-Realm"] = 2, ["Me-Realm"] = 3 }
    officer = {}
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Core/Leaderboard/Activity.lua")
    ns.Activity.Register({ id = "exchange.sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 20 })
    loadAddonFile(ns, "Guildhearth/Core/Permissions.lua")
    loadAddonFile(ns, "Guildhearth/Modules/Groups/Perms.lua")
    fakeUI(ns, W, texts, buttons, errors)
    ns.services = {
      playerChar = "Me-Realm",
      roster = {
        IsOfficer = function(_, name) return officer[name] == true end,
        RankIndex = function(_, name) return ranks[name] end,
        RankNames = function() return { "Guild Master", "Officer", "Veteran", "Member" } end,
      },
    }
    ns.leaderboard = {
      permissions = { Can = function(_, _, key) return granted[key] == true end },
      config = {
        Tz = function() return 0 end,
        History = function() return history end,
        HistoryAuthorPermitted = function(_, e) return e.by ~= "Gone-Realm" end,
      },
    }
    loadAddonFile(ns, "Guildhearth/Core/UI/HistoryView.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function build()
    view = ns.UI.HistoryView.Build(W.new("Frame"))
    view.refresh()
    return view
  end
  local function lines()
    local out = {}
    for _, r in ipairs(view.rows) do
      if r.text and r.text ~= "" then out[#out + 1] = r.text end
    end
    return out
  end

  it("history lines render in plain language for each what", function()
    officer["Me-Realm"] = true
    _G.GetItemInfo = function(id) if id == 13457 then return "Fire Protection Potion" end end
    local T = 1700000000
    ns.leaderboard.ledger = { Contributions = function()
      return { { type = "bank.gold", char = "Bob-Realm", value = 500000, ref = "bank:o1", at = T - 86400 } }
    end }
    history = {
      { what = "month", key = "2026-10", by = "Boss-Realm", at = T + 3600,
        before = { savedBy = "A-Realm", savedAt = 1 }, after = { savedBy = "Boss-Realm", savedAt = 2 } },
      { what = "weights", by = "Dor-Realm", at = T + 60,
        before = { ["exchange.sales"] = 3 }, after = { ["exchange.sales"] = 30 } },
      { what = "perms", by = "Boss-Realm", at = T + 30,
        before = { weights = { ranks = { 0, 2 }, raidlead = false } },
        after = { weights = { ranks = { 0 }, raidlead = false }, checklists = { ranks = { 0, 1 }, raidlead = true } } },
      { what = "checklist", key = "checklist:mc:fire", by = "Dor-Realm", at = T + 20,
        before = { name = "Molten Core", lines = { { kind = "item", item = 13457, count = 3 } } },
        after = { name = "Molten Core", lines = { { kind = "item", item = 13457, count = 5 } } } },
      { what = "bank", key = "bank:o1", by = "Dor-Realm", at = T + 10,
        before = { excluded = false }, after = { excluded = true, reason = "moving guild funds" } },
      { what = "bank", key = "bank:o1", by = "Dor-Realm", at = T + 5,
        before = { excluded = true }, after = { excluded = false } },
      { what = "weights", by = "Gone-Realm", at = T,
        before = { ["exchange.sales"] = 3 }, after = {} },
    }
    build()
    assert.same({
      "2023-11-14 23:13  Boss [Guild Master]  Retook October 2026 top 5",
      "2023-11-14 22:14  Dor [Officer]  Leaderboard weight Sales: 3 -> 30",
      "2023-11-14 22:13  Boss [Guild Master]  Permission Edit raid checklists: added Officer",
      "2023-11-14 22:13  Boss [Guild Master]  Permission Edit raid checklists: added Raid leader & assistants",
      "2023-11-14 22:13  Boss [Guild Master]  Permission Edit leaderboard weights: removed Veteran",
      "2023-11-14 22:13  Dor [Officer]  Checklist Molten Core: Fire Protection Potion 3 -> 5",
      "2023-11-14 22:13  Dor [Officer]  Bank entry 2023-11-13 Bob 50g deposit: excluded \194\183 moving guild funds",
      "2023-11-14 22:13  Dor [Officer]  Bank entry 2023-11-13 Bob 50g deposit: counted again",
      "2023-11-14 22:13  Gone  Leaderboard weight Sales: 3 -> removed (no permission now)",
    }, lines())
    for _, l in ipairs(lines()) do assert.is_nil(l:gsub("\194\183", ""):find("[\128-\255]"), l) end
    assert.is_false(view.note.shown)
    -- the other checklist changes, in the same style
    local D = ns.UI.HistoryView.Describe
    local function cl(before, after)
      before.name = before.name or "Fire"; after.name = after.name or before.name
      return D({ what = "checklist", key = "checklist:mc:fire", before = before, after = after })
    end
    assert.same({ "Checklist Fire: added Fire Protection Potion x2" },
      cl({ lines = {} }, { lines = { { kind = "item", item = 13457, count = 2 } } }))
    assert.same({ "Checklist Fire: removed an item" },
      cl({ lines = { { kind = "item", item = 999, count = 1 } } }, { lines = {} }))
    assert.same({ "Checklist Fire: added All gear enchanted", "Checklist Fire: added \"Bring a soulstone\"" },
      cl({ lines = {} }, { lines = { { kind = "enchants" }, { kind = "manual", text = "Bring a soulstone" } } }))
    assert.same({ "Checklist Fire: renamed to Fire pots" }, cl({}, { name = "Fire pots" }))
    assert.same({ "Checklist Fire: deleted" }, cl({ deleted = false }, { deleted = true }))
    assert.same({ "Checklist Fire: restored" }, cl({ deleted = true }, { deleted = false }))
    assert.same({ "Checklist Fire: made the default" }, cl({ default = false }, { default = true }))
    -- a bank entry the ledger no longer has, and reason edits
    assert.same({ "Bank entry (no longer in the ledger): excluded" },
      D({ what = "bank", key = "bank:o9", before = { excluded = false }, after = { excluded = true } }))
    assert.same({ "Bank entry 2023-11-13 Bob 50g deposit: reason changed \194\183 b" },
      D({ what = "bank", key = "bank:o1", before = { reason = "a" }, after = { reason = "b" } }))
    assert.same({ "Bank entry 2023-11-13 Bob 50g deposit: reason removed" },
      D({ what = "bank", key = "bank:o1", before = { reason = "a" }, after = {} }))
    assert.same({}, errors)
  end)

  describe("never shows a raw id", function()
    local function D(e) return ns.UI.HistoryView.Describe(e) end

    it("a bank entry the ledger no longer has", function()
      ns.leaderboard.ledger = { Contributions = function() return {} end }
      assert.same({ "Bank entry (no longer in the ledger): excluded" },
        D({ what = "bank", key = "bank:o9", before = { excluded = false }, after = { excluded = true } }))
      assert.same({ "Bank entry (no longer in the ledger): counted again" },
        D({ what = "bank", key = "bank:o9", before = { excluded = true }, after = { excluded = false } }))
    end)

    it("an item the client hasn't cached", function()
      _G.GetItemInfo = function() return nil end
      assert.same({ "Checklist Fire: an item 3 -> 5" }, D({ what = "checklist", key = "checklist:mc:fire",
        before = { name = "Fire", lines = { { kind = "item", item = 4242, count = 3 } } },
        after = { name = "Fire", lines = { { kind = "item", item = 4242, count = 5 } } } }))
    end)

    it("the group finder guild settings", function()
      assert.same({ "Groups: raids on the guild calendar don't count with non-guild players" },
        D({ what = "groups", key = "settings", before = { calendar = true, other = false },
          after = { calendar = false, other = false } }))
      assert.same({ "Groups: raids on the guild calendar count with non-guild players",
        "Groups: other runs count with non-guild players" },
        D({ what = "groups", key = "settings", before = { calendar = false, other = false },
          after = { calendar = true, other = true } }))
      assert.same({ "Groups: other runs don't count with non-guild players" },
        D({ what = "groups", key = "settings", before = { calendar = true, other = true },
          after = { calendar = true, other = false } }))
    end)

    it("a weight type this version doesn't know", function()
      assert.same({ "Leaderboard weight an unknown activity: 1 -> 2" },
        D({ what = "weights", before = { ["future.kind"] = 1 }, after = { ["future.kind"] = 2 } }))
    end)

    it("a checklist with no name on either side", function()
      assert.same({ "A checklist: deleted" },
        D({ what = "checklist", key = "checklist:mc:fire", before = { deleted = false }, after = { deleted = true } }))
    end)

    it("a permission key this version doesn't list", function()
      assert.same({ "Permission an unknown permission: added Officer" },
        D({ what = "perms", before = {}, after = { ["future.key"] = { ranks = { 0, 1 }, raidlead = false } } }))
    end)
  end)

  it("members can't see the change history", function()
    history = { { what = "weights", by = "Dor-Realm", at = 1700000000,
      before = { ["exchange.sales"] = 3 }, after = { ["exchange.sales"] = 30 } } }
    build()
    assert.is_true(view.note.shown)
    assert.equal("Only officers and the guild master can see the change history.", view.note.text)
    assert.is_false(view.box.shown)
    assert.same({}, lines())
    assert.is_nil(ns.UI.HistoryView.Lines(4))
  end)

  it("officers, the guild master and anyone holding a permission see it", function()
    history = { { what = "month", key = "2026-10", by = "Boss-Realm", at = 1700000000 } }
    officer["Me-Realm"] = true
    build()
    assert.is_true(view.box.shown); assert.is_false(view.note.shown)
    officer["Me-Realm"] = nil
    ranks["Me-Realm"] = 0
    view.refresh()
    assert.is_true(view.box.shown)
    ranks["Me-Realm"] = 3
    granted.flex = true
    view.refresh()
    assert.is_true(view.box.shown)
    assert.equal(1, #lines())
  end)

  it("shows an empty state, and the wheel scrolls a long list", function()
    officer["Me-Realm"] = true
    build()
    assert.is_true(view.empty.shown)
    for i = 1, 60 do
      history[i] = { what = "weights", by = "Dor-Realm", at = 1700000000 - i,
        before = { ["exchange.sales"] = i }, after = { ["exchange.sales"] = i + 100 } }
    end
    view.refresh()
    assert.is_false(view.empty.shown)
    assert.equal(60, #view.lines)
    local rows = #view.rows
    assert.equal(rows, #lines())
    local wheel = handler(view.box, "OnMouseWheel")
    for _ = 1, 100 do wheel(view.box, -1) end
    assert.equal(60 - rows, view.offset)
    assert.is_truthy(lines()[rows]:find("60 -> 160", 1, true))
    wheel(view.box, 100)
    assert.equal(0, view.offset)
    assert.same({}, errors)
  end)
end)

describe("Permissions grid with the group finder keys", function()
  local ns, W, texts, buttons, errors
  local saved = {}

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    texts, buttons, errors = {}, {}, {}
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Core/Permissions.lua")
    loadAddonFile(ns, "Guildhearth/Modules/Groups/Perms.lua")
    fakeUI(ns, W, texts, buttons, errors)
    local roster = {
      RankIndex = function(_, name) return ({ ["Gm-Realm"] = 0 })[name] end,
      IsOfficer = function() return true end,
      RankNames = function() return { "Guild Master", "Officer", "Member" } end,
    }
    ns.services = { playerChar = "Gm-Realm", roster = roster }
    ns.leaderboard = { permissions = ns.Permissions.new({ roster = roster, playerChar = "Gm-Realm" }) }
    loadAddonFile(ns, "Guildhearth/Core/UI/HistoryView.lua")
    loadAddonFile(ns, "Guildhearth/Core/UI/PermissionsView.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  it("the groups keys show the raid-leader column; leaderboard keys don't", function()
    local view = ns.UI.PermissionsView.Build(W.new("Frame"))
    local head = false
    for _, t in ipairs(texts) do if t.text == "Raid leader & assistants" and t.shown then head = true end end
    assert.is_true(head)
    for _, key in ipairs({ "checklists", "prepared", "flex" }) do
      assert.is_truthy(view.raid[key], key)
      assert.is_true(view.raid[key].shown, key)
    end
    for _, key in ipairs({ "weights", "retake", "bankreview" }) do
      assert.is_nil(view.raid[key], key)
      assert.is_truthy(view.cells[key], key)
    end
    assert.same({}, errors)
  end)
end)

describe("Groups settings", function()
  local ns, W, texts, buttons, errors, section
  local saved = {}

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    texts, buttons, errors = {}, {}, {}
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    fakeUI(ns, W, texts, buttons, errors)
    loadAddonFile(ns, "Guildhearth/Modules/Groups/Reminders.lua")
    loadAddonFile(ns, "Guildhearth/Modules/Groups/UI/Details.lua")
    loadAddonFile(ns, "Guildhearth/Modules/Groups/UI/SettingsView.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function build()
    section = ns.Groups.SettingsView.Build(W.new("Frame"))
    section.refresh()
    return section
  end
  local function has(s)
    for _, t in ipairs(texts) do if t.text == s and t.shown then return true end end
    return false
  end
  local function toggle(cb, on)
    cb:SetChecked(on)
    click(cb)
  end

  it("shows the three settings with their defaults when nothing is saved yet", function()
    _G.GuildhearthDB = nil
    build()
    for _, s in ipairs({ "Remind me 15 min before runs I signed up for", "Play a sound with reminders",
      "My usual roles", "Tank", "Healer", "DPS" }) do
      assert.is_true(has(s), s)
    end
    assert.is_true(section.reminders:GetChecked())
    assert.is_true(section.sound:GetChecked())
    assert.is_false(section.roles.t:GetChecked())
    assert.is_false(section.roles.h:GetChecked())
    assert.is_true(section.roles.d:GetChecked())
    toggle(section.reminders, false) -- nowhere to save it, and no error
    toggle(section.roles.t, true)
    assert.is_false(section.roles.t:GetChecked()) -- nothing was saved, so the box resets
    assert.is_true(section.reminders:GetChecked())
    assert.same({}, errors)
  end)

  it("fills a missing personal.groups and saves each change", function()
    _G.GuildhearthDB = { personal = {} }
    build()
    local g = _G.GuildhearthDB.personal.groups
    assert.same({ reminders = true, sound = true, roles = { d = true } }, g)
    toggle(section.sound, false)
    assert.is_false(g.sound)
    toggle(section.reminders, false)
    assert.is_false(g.reminders)
    toggle(section.reminders, true)
    assert.is_true(g.reminders)
    toggle(section.roles.t, true)
    toggle(section.roles.d, false)
    assert.same({ t = true }, g.roles)
    assert.same({}, errors)
  end)

  it("keeps saved choices, and the last role can't be unticked", function()
    _G.GuildhearthDB = { personal = { groups = { reminders = false, roles = { h = true } } } }
    build()
    local g = _G.GuildhearthDB.personal.groups
    assert.is_false(section.reminders:GetChecked())
    assert.same({ h = true }, g.roles) -- Defaults never adds DPS to a saved choice
    assert.is_true(section.roles.h:GetChecked())
    assert.is_false(section.roles.d:GetChecked())
    toggle(section.roles.h, false)
    assert.same({ h = true }, g.roles)
    assert.is_true(section.roles.h:GetChecked())
    assert.is_true(has("Keep at least one role."))
  end)

  describe("the guild section", function()
    local state, gm, sets
    before_each(function()
      _G.GuildhearthDB = { personal = {} }
      state, gm, sets = { calendar = true, other = false }, false, {}
      ns.leaderboard = { config = {} }
      ns.Groups.Credit = {
        Settings = function(cfg)
          assert.equal(ns.leaderboard and ns.leaderboard.config, cfg)
          return { calendar = state.calendar, other = state.other }
        end,
        CanSetSettings = function() return gm end,
        SetSetting = function(_, key, on)
          sets[#sets + 1] = key .. "=" .. tostring(on)
          state[key] = on
          return true
        end,
      }
    end)

    it("the guild master gets two checkboxes with the defaults, each saving its setting", function()
      gm = true
      build()
      assert.is_true(has("Guild settings (guild master)"))
      assert.is_true(has("Raids on the guild calendar count with non-guild players"))
      assert.is_true(has("Other runs count with non-guild players"))
      assert.is_true(section.calendar.shown)
      assert.is_true(section.other.shown)
      assert.is_true(section.calendar:GetChecked())
      assert.is_false(section.other:GetChecked())
      toggle(section.other, true)
      toggle(section.calendar, false)
      assert.same({ "other=true", "calendar=false" }, sets)
      assert.is_true(section.other:GetChecked())
      assert.is_false(section.calendar:GetChecked())
      assert.same({}, errors)
    end)

    it("a refused save shows why and resets the box", function()
      gm = true
      build()
      ns.Groups.Credit.SetSetting = function() return false, "no permission" end
      toggle(section.other, true)
      assert.is_false(section.other:GetChecked())
      assert.is_true(has("Only the guild master can change this."))
    end)

    it("everyone else sees the current state as text", function()
      build()
      assert.is_false(section.calendar.shown)
      assert.is_false(section.other.shown)
      assert.is_true(has("Raids on the guild calendar with non-guild players: count"))
      assert.is_true(has("Other runs with non-guild players: don't count"))
      state = { calendar = false, other = true }
      section.refresh()
      assert.is_true(has("Raids on the guild calendar with non-guild players: don't count"))
      assert.is_true(has("Other runs with non-guild players: count"))
      assert.same({}, errors)
    end)

    it("without the leaderboard it reads as the defaults and offers nothing", function()
      ns.leaderboard = nil
      gm = true
      ns.Groups.Credit.CanSetSettings = function(cfg) return cfg ~= nil end
      build()
      assert.is_false(section.calendar.shown)
      assert.is_true(has("Raids on the guild calendar with non-guild players: count"))
      assert.is_true(has("Other runs with non-guild players: don't count"))
    end)
  end)

  it("My usual roles feed Ready now and Sign up", function()
    _G.GuildhearthDB = { personal = {} }
    build()
    toggle(section.roles.t, true)
    toggle(section.roles.h, true)
    toggle(section.roles.d, false)
    local D = ns.Groups.Details
    assert.same({ t = true, h = true }, D.PersonalRoles())
    local usual
    for _, it in ipairs(D.RoleItems()) do
      if it.label:find("^My usual roles") then usual = it end
    end
    assert.is_truthy(usual)
    assert.equal("My usual roles (T/H)", usual.label)
    assert.same({ t = true, h = true }, usual.value)
  end)
end)
