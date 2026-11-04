-- Groups new-post form and checklist editor under fake frames.
describe("Groups.Form", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, texts, buttons, picked, errors, posted, saved, offset, canKey, refreshed, hook, stored
  local split, clockT
  local NOW = 1699999999       -- 2023-11-14 22:46:39 UTC
  local MIDNIGHT = 1699920000  -- 2023-11-14 00:00 UTC
  local GLOBALS = { "CreateFrame", "hooksecurefunc", "ChatFrameUtil", "GetCursorInfo", "ClearCursor",
    "StackSplitFrame", "GetTime" }
  local keep = {}
  local LINK = "|cffffffff|Hitem:13444::::::::60:::::|h[Major Mana Potion]|h|r"

  local function script(w, event)
    for _, c in ipairs(w.calls.SetScript or {}) do
      if c[1] == event then return c[2] end
    end
  end
  local function click(w) script(w, "OnClick")(w) end
  local function shown(s)
    for _, t in ipairs(texts) do if t.text == s and t.shown ~= false then return true end end
    return false
  end

  before_each(function()
    for _, k in ipairs(GLOBALS) do keep[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    _G.hooksecurefunc = function(_, _, fn) hook = fn end
    _G.ChatFrameUtil = { InsertLink = function() end }
    _G.GetCursorInfo, _G.ClearCursor = nil, nil
    split, clockT = W.new("Frame"), 100
    _G.StackSplitFrame = split
    _G.GetTime = function() return clockT end
    texts, buttons, picked, errors, posted, saved, refreshed, hook = {}, {}, nil, {}, nil, {}, 0, nil
    offset, canKey, stored = 0, { checklists = true }, {}
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Scoring.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Post.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/Credit.lua")
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.UI = {
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Text = function(_, _, text)
        local t = W.new("FontString"); t.text = text; t.shown = true; texts[#texts + 1] = t; return t
      end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; b.text = text; b.shown = true; buttons[text] = b; return b
      end,
      PickList = function(anchor, items, onPick, current)
        picked = { anchor = anchor, items = items, onPick = onPick, current = current }
      end,
      CreatePanel = function()
        local p = W.new("Frame")
        p.title, p.close = W.new("FontString"), W.new("Button")
        return p
      end,
    }
    ns.services = {
      now = function() return NOW end, playerChar = "Dor-R",
      compat = {
        ServerOffset = function() return offset end,
        SecondsUntilWeeklyReset = function() return nil end,
        ItemName = function(_, id) return id == 13444 and "Major Mana Potion" or nil end,
        Safe = function(_, v) return v end,
      },
    }
    _G.GuildhallDB = { personal = { groups = { roles = { d = true } } } }
    ns.leaderboard = {
      permissions = { Can = function(_, _, key) return canKey[key] == true end },
      config = { Tz = function() return offset end },
    }
    ns.groups = {
      svc = {
        Post = function(_, d)
          posted = d
          local ok, err = ns.Groups.Post.CheckNew(d, NOW)
          if not ok then return false, err end
          return true, { id = "p1:g1_1", d = d }
        end,
      },
      checklist = {
        Get = function(_, id) return stored[id] end,
        Save = function(_, d)
          saved[#saved + 1] = d
          if saved.refuse then return false, saved.refuse end
          return true, d.id or "checklist:mc:raid_basics"
        end,
      },
    }
    ns.Groups.View = { Refresh = function() refreshed = refreshed + 1 end }
    loadAddonFile(ns, "Guildhall/Modules/Groups/UI/Details.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/UI/Form.lua")
    loadAddonFile(ns, "Guildhall/Modules/Groups/UI/ChecklistEditor.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = keep[k] end
    _G.GuildhallDB = nil
  end)

  local function form() return ns.Groups.Form end
  local function f() return ns.Groups.Form._f end

  local function pickRun(key)
    f().runBtn.onClick()
    picked.onPick(key)
  end

  local function need()
    return { tonumber(f().need.t:GetText()), tonumber(f().need.h:GetText()), tonumber(f().need.d:GetText()) }
  end

  describe("post form", function()
    before_each(function() form().Open() end)

    it("the run picker lists the dungeons by name, then the raids by tier", function()
      f().runBtn.onClick()
      local keys = {}
      for _, item in ipairs(picked.items) do keys[#keys + 1] = item.value end
      assert.equal(26 + 7, #keys)
      assert.equal("bfd", keys[1]) -- Blackfathom Deeps
      assert.equal("mc", keys[27])
      assert.equal("naxx", keys[33])
    end)

    it("need defaults to 1/1/3 minus your role", function()
      assert.is_true(shown("Filled from the run size and your role. Change if friends are coming."))
      pickRun("wc")
      assert.same({ 1, 1, 2 }, need()) -- your usual role is DPS
      click(f().roles.t)
      assert.same({ 0, 1, 3 }, need())
      click(f().roles.h)
      assert.same({ 1, 0, 3 }, need())
      pickRun("mc")
      assert.same({ 2, 7, 30 }, need())
      click(f().roles.d)
      assert.same({ 2, 8, 29 }, need())
      pickRun("ubrs") -- 10-player: derived proportionally
      assert.same({ 1, 2, 6 }, need())
      pickRun("zg") -- 20-player
      assert.same({ 1, 4, 14 }, need())
    end)

    it("DefaultNeed derives from the size and takes your role off", function()
      local D = form().DefaultNeed
      assert.same({ t = 0, h = 1, d = 3 }, D(5, "t"))
      assert.same({ t = 2, h = 8, d = 29 }, D(40, "d"))
      assert.same({ t = 1, h = 8, d = 30 }, D(40, "t"))
      assert.same({ t = 1, h = 2, d = 6 }, D(10, "d"))
    end)

    it("posting without a run says Pick a run.", function()
      buttons["Post"].onClick()
      assert.equal("Pick a run.", f().error.text)
    end)

    it("more people than the run allows is refused by the service", function()
      pickRun("wc")
      f().need.d:SetText("3")
      buttons["Post"].onClick()
      assert.equal("That's more people than the run allows.", f().error.text)
    end)

    it("a scheduled time in the past is refused", function()
      pickRun("wc")
      click(f().scheduled)
      f().time:SetText("20:00") -- today 20:00 server time: before 22:46
      buttons["Post"].onClick()
      assert.equal(MIDNIGHT + 72000, posted.start)
      assert.equal("Pick a time in the future.", f().error.text)
      assert.is_true(f().frame.shown)
    end)

    it("a bad time or an unknown server offset is refused before posting", function()
      pickRun("wc")
      click(f().scheduled)
      f().time:SetText("25:00")
      buttons["Post"].onClick()
      assert.is_nil(posted)
      assert.equal("Enter the time as HH:MM, server time.", f().error.text)
      f().time:SetText("21:30")
      offset = nil
      buttons["Post"].onClick()
      assert.is_nil(posted)
      assert.equal("The server time isn't known yet. Try again in a moment, or post for Now.", f().error.text)
    end)

    it("the payload matches the inputs", function()
      offset = 3600 -- server time is UTC+1: 23:46 on the 14th
      pickRun("strat_ud")
      click(f().roles.h)
      f().need.t:SetText("1"); f().need.h:SetText("0"); f().need.d:SetText("2")
      click(f().scheduled)
      f().dayBtn.onClick()
      assert.equal(14, #picked.items)
      assert.equal("Today", picked.items[1].label)
      assert.equal("Tomorrow", picked.items[2].label)
      picked.onPick(1)
      f().time:SetText("20:00")
      f().note:SetText("  bring pots  ")
      f().wantName:SetText("Linen Cloth")
      f().remind:SetChecked(false) -- untick
      buttons["Post"].onClick()
      assert.same({
        instance = "strat_ud", role = "h", need = { t = 1, h = 0, d = 2 },
        start = MIDNIGHT + 86400 + 72000 - 3600, note = "bring pots", want = "Linen Cloth", remind = false,
      }, posted)
      assert.equal("", f().error.text)
      assert.is_false(f().frame.shown)
      assert.equal(1, refreshed)
    end)

    it("a Now post sends no start, a shift-clicked item goes by id, and the reminder stays on", function()
      pickRun("mc")
      assert.is_true(f().remind:GetChecked())
      assert.is_function(hook)
      hook(LINK)
      buttons["Post"].onClick()
      assert.same({ instance = "mc", role = "d", need = { t = 2, h = 8, d = 29 }, want = 13444 }, posted)
    end)

    it("closes the stack-split popup the same shift-click opened, and a dragged item fills the slot", function()
      local onShow = split.calls.HookScript and split.calls.HookScript[1]
      assert.equal("OnShow", onShow and onShow[1])
      split:Show(); hook(LINK); onShow[2](split)
      assert.is_false(split.shown)
      clockT = 105
      split:Show(); onShow[2](split)
      assert.is_true(split.shown)
      _G.GetCursorInfo = function() return "item", 13444, LINK end
      _G.ClearCursor = function() end
      f().wantName:SetText("")
      click(f().slot)
      assert.equal("Major Mana Potion", f().wantName.text)
      assert.equal(0, #errors)
    end)

    it("the note counter counts bytes up to 120, and the preview follows the inputs", function()
      assert.same({ { 121 } }, f().note.calls.SetMaxBytes)
      f().note:SetText("hello")
      assert.equal("5/120", f().count.text)
      pickRun("wc")
      assert.equal("Preview: Wailing Caverns · Now · need 1 tank, 1 healer, 2 DPS", f().preview.text)
      click(f().scheduled)
      f().time:SetText("23:15")
      assert.equal("Preview: Wailing Caverns · Today 23:15 server time · need 1 tank, 1 healer, 2 DPS",
        f().preview.text)
    end)

    it("maps the service's errors to the form's copy", function()
      local E = form().ErrorText
      assert.equal("Note is too long.", E("bad note"))
      assert.equal("Pick a run.", E("bad instance"))
      assert.equal("That's more people than the run allows.", E("need exceeds size"))
      assert.equal("Pick a time in the future.", E("start in past"))
      assert.equal("Trial accounts can't post or sign up.", E("trial"))
    end)

    it("opens with a prefilled run and role", function()
      form().Open({ instance = "brd", role = "t" })
      assert.equal("Blackrock Depths", f().runBtn.text)
      assert.same({ 0, 1, 3 }, need())
    end)

    it("uses no glyph above U+00FF", function()
      for _, path in ipairs({ "Guildhall/Modules/Groups/UI/Form.lua", "Guildhall/Modules/Groups/UI/ChecklistEditor.lua" }) do
        local src = assert(io.open(path)):read("*a")
        -- UTF-8 lead bytes C4..F4 start code points >= U+0100
        assert.is_nil(src:find("[\196-\244]"), path)
      end
    end)
  end)

  describe("checklist editor", function()
    local function e() return ns.Groups.ChecklistEditor._f end
    local function addText(s)
      e().text:SetText(s)
      e().addText.onClick()
    end

    it("the editor caps at 12 lines and saves through cl:Save", function()
      ns.Groups.ChecklistEditor.Open("mc", nil)
      e().name:SetText(" Raid basics ")
      e().addEnchants.onClick()
      e().item:SetText("13444")
      e().count:SetText("5")
      e().addItem.onClick()
      for i = 1, 10 do addText("Line " .. i) end
      assert.equal(12, #e().lines)
      addText("One too many")
      assert.equal(12, #e().lines)
      assert.equal("A checklist holds at most 12 lines.", e().error.text)
      buttons["Save"].onClick()
      assert.equal(1, #saved)
      local d = saved[1]
      assert.is_nil(d.id)
      assert.equal("mc", d.instance)
      assert.equal("Raid basics", d.name)
      assert.equal(12, #d.lines)
      assert.same({ kind = "enchants" }, d.lines[1])
      assert.same({ kind = "item", item = 13444, count = 5 }, d.lines[2])
      assert.same({ kind = "manual", text = "Line 1" }, d.lines[3])
      assert.is_false(e().frame.shown)
      assert.equal(1, refreshed)
    end)

    it("edits an existing checklist: loads its lines, removes one and saves with its id", function()
      stored["checklist:mc:raid"] = { id = "checklist:mc:raid", instance = "mc", name = "Raid",
        lines = { { kind = "item", item = 13444, count = 10 }, { kind = "manual", text = "Flask" } } }
      ns.Groups.ChecklistEditor.Open("mc", "checklist:mc:raid")
      assert.equal("Raid", e().name.text)
      assert.equal("10 × Major Mana Potion", e().rows[1].text.text)
      assert.equal("Flask", e().rows[2].text.text)
      e().rows[1].remove.onClick()
      buttons["Save"].onClick()
      assert.same({ id = "checklist:mc:raid", instance = "mc", name = "Raid",
        lines = { { kind = "manual", text = "Flask" } } }, saved[1])
    end)

    it("a shift-clicked item fills the item box; bad counts and ids are refused", function()
      ns.Groups.ChecklistEditor.Open("mc", nil)
      hook(LINK)
      assert.equal(LINK, e().itemLink)
      e().count:SetText("0")
      e().addItem.onClick()
      assert.equal(0, #e().lines)
      assert.equal("Count must be 1 to 200.", e().error.text)
      e().count:SetText("20")
      e().addItem.onClick()
      assert.same({ kind = "item", item = 13444, count = 20 }, e().lines[1])
      e().item:SetText("potion")
      e().addItem.onClick()
      assert.equal(1, #e().lines)
      assert.equal("Shift-click or drag an item in, or type its item ID.", e().error.text)
    end)

    it("an unknown instance is refused", function()
      assert.same({ false, "unknown instance" }, { ns.Groups.ChecklistEditor.Open("nope", nil) })
      assert.same({ true }, { ns.Groups.ChecklistEditor.Open("mc", nil) })
    end)

    it("with the post form open too, one shift-click fills only one of them", function()
      form().Open()
      ns.Groups.ChecklistEditor.Open("mc", nil)
      hook(LINK)
      local filled = (f().wantLink ~= nil and 1 or 0) + (e().itemLink ~= nil and 1 or 0)
      assert.equal(1, filled)
      form().Hide()
      hook(LINK)
      assert.equal(LINK, e().itemLink)
    end)

    it("a permission error shows the message cl:Save returned", function()
      saved.refuse = "no permission"
      ns.Groups.ChecklistEditor.Open("mc", nil)
      e().name:SetText("Basics")
      buttons["Save"].onClick()
      assert.equal(1, #saved)
      assert.equal("You don't have permission for that.", e().error.text)
      assert.is_true(e().frame.shown)
    end)

    it("without the checklists permission it says so and Save is off", function()
      canKey.checklists = nil
      ns.Groups.ChecklistEditor.Open("mc", nil)
      assert.equal("You need the checklists permission to edit Molten Core checklists.", e().error.text)
      assert.is_not_nil(buttons["Save"].calls.Disable)
    end)
  end)
end)
