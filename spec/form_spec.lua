-- Exchange listing form under fake frames: input limits (M10) and the InsertLink hook (M9).
describe("Exchange.Form", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, hook, texts, panel, errors, buttons, split, now
  local saved = {}
  local GLOBALS = { "CreateFrame", "hooksecurefunc", "ChatFrameUtil", "StackSplitFrame", "GetTime",
    "GetItemInfoInstant", "ProfessionsFrame", "C_TradeSkillUI", "TradeSkillFrame", "CraftFrame" }
  local picked
  local POTION = "|cffffffff|Hitem:118::::::::60:::::|h[Potion]|h|r"
  local LINK = "|cffa335ee|Hitem:14152::::::::60:::::|h[Robe of the Archmage]|h|r"
  local SECRET = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    texts, errors, hook, buttons, now = {}, {}, nil, {}, 100
    split = W.new("Frame")
    _G.StackSplitFrame = split
    _G.ProfessionsFrame, _G.TradeSkillFrame, _G.CraftFrame, _G.C_TradeSkillUI = nil, nil, nil, nil
    _G.GetItemInfoInstant = function(l)
      if tostring(l):find("item:118:", 1, true) then return 118, "", "", "", 1, 0, 1 end -- potion
      return 14152, "", "", "", 1, 4, 1
    end
    picked = nil
    _G.GetTime = function() return now end
    _G.CreateFrame = W.CreateFrame
    _G.hooksecurefunc = function(tbl, name, fn) hook = fn end
    _G.ChatFrameUtil = { InsertLink = function() end }
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Category.lua")
    ns.compat = fakes.compat({ issecretvalue = function(v) return v == SECRET end })
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.UI = {
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      PickList = function(anchor, items, onPick, current)
        picked = { anchor = anchor, items = items, onPick = onPick, current = current }
      end,
      Text = function() local t = W.new("FontString"); texts[#texts + 1] = t; return t end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; buttons[text] = b; return b
      end,
      CreatePanel = function()
        panel = W.new("Frame")
        panel.title, panel.close = W.new("FontString"), W.new("Button")
        return panel
      end,
    }
    loadAddonFile(ns, "Guildhall/Modules/Exchange/UI/Form.lua")
    ns.Exchange.Form.Open()
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function shownText(s)
    for _, t in ipairs(texts) do if t.text == s then return true end end
    return false
  end

  it("limits the name and note boxes in bytes, matching Validate (M10)", function()
    local boxes = W.ofKind("EditBox") -- created in order: name, qty, note
    local name, note = boxes[1], boxes[3]
    assert.same({ { 256 } }, name.calls.SetMaxBytes)
    assert.same({ { 201 } }, note.calls.SetMaxBytes)
    assert.is_nil(name.calls.SetMaxLetters)
    assert.is_nil(note.calls.SetMaxLetters)
  end)

  it("the InsertLink hook skips secret arguments (M9)", function()
    assert.is_function(hook)
    hook(nil, SECRET, LINK)
    assert.is_true(shownText(LINK))
    assert.is_false(shownText(SECRET))
    assert.equal(0, #errors)
  end)

  it("a shift-clicked item fills and locks the Name box; X unlocks it", function()
    local name = W.ofKind("EditBox")[1]
    hook(LINK)
    assert.equal("Robe of the Archmage", name.text)
    assert.is_not_nil(name.calls.Disable)
    buttons["X"].onClick()
    assert.equal("", name.text)
    assert.is_not_nil(name.calls.Enable)
    assert.is_true(shownText("|cff888888No item chosen|r"))
  end)

  it("closes the stack-split popup that the same shift-click opened", function()
    local onShow = split.calls.HookScript and split.calls.HookScript[1]
    assert.equal("OnShow", onShow and onShow[1])
    split:Show(); hook(LINK); onShow[2](split)
    assert.is_false(split.shown)
    now = 105
    split:Show(); onShow[2](split)
    assert.is_true(split.shown) -- a later, unrelated split is left alone
  end)

  it("the InsertLink hook never lets an error escape (M9)", function()
    panel.IsShown = function() error("boom") end
    assert.has_no.errors(function() hook(LINK) end)
    assert.equal(1, #errors)
  end)

  describe("profession picker", function()
    local function pickItem(value)
      for _, it in ipairs(picked.items) do if it.value == value then return it end end
    end
    local function choose(key) picked.onPick(key) end

    it("starts at None and the list offers None plus the professions", function()
      buttons["None"].onClick()
      assert.equal("None", picked.items[1].label)
      assert.equal(9, #picked.items)
      assert.is_not_nil(pickItem("tailoring"))
      assert.is_false(picked.current)
    end)

    it("a choice shows on the button and goes into the payload", function()
      buttons["None"].onClick()
      choose("tailoring")
      assert.equal("Tailoring", buttons["None"].text)
      local posted
      ns.exchange = { Post = function(_, d) posted = d; return true, {} end }
      hook(LINK)
      buttons["Post"].onClick()
      assert.equal("tailoring", posted.prof)
    end)

    it("choosing None sends no prof, and Save clears it with prof = false", function()
      local sent
      ns.exchange = { Edit = function(_, id, ch) sent = ch; return true, {} end }
      ns.Exchange.Form.Open({ id = "p:1", d = { kind = "LF", item = "Silk", mats = false, cod = false, prof = "tailoring" } })
      assert.equal("Tailoring", buttons["None"].text)
      buttons["None"].onClick()
      choose(nil)
      buttons["Post"].onClick()
      assert.is_false(sent.prof)
    end)

    it("editing shows the listing's profession and Save keeps it", function()
      local sent
      ns.exchange = { Edit = function(_, id, ch) sent = ch; return true, {} end }
      ns.Exchange.Form.Open({ id = "p:1", d = { kind = "LF", item = "Silk", mats = false, cod = false, prof = "cooking" } })
      assert.equal("Cooking", buttons["None"].text)
      buttons["Post"].onClick()
      assert.equal("cooking", sent.prof)
    end)

    it("opening a new listing resets the choice to None", function()
      buttons["None"].onClick(); choose("tailoring")
      ns.Exchange.Form.Open()
      assert.equal("None", buttons["None"].text)
    end)
  end)

  describe("profession auto-fill", function()
    local function profText() return buttons["None"].text end
    it("uses the item type when no profession window is open", function()
      hook(POTION)
      assert.equal("Alchemy", profText())
    end)
    it("prefers the open profession window", function()
      _G.ProfessionsFrame = { IsShown = function() return true end }
      _G.C_TradeSkillUI = { GetBaseProfessionInfo = function() return { professionID = 185 } end }
      hook(POTION)
      assert.equal("Cooking", profText())
    end)
    it("reads the Era TradeSkillFrame and CraftFrame", function()
      _G.TradeSkillFrame = { IsShown = function() return true end }
      _G.GetTradeSkillLine = function() return "Blacksmithing" end
      hook(LINK)
      assert.equal("Blacksmithing", profText())
      _G.TradeSkillFrame, _G.GetTradeSkillLine = nil, nil
      _G.CraftFrame = { IsShown = function() return true end }
      hook(POTION)
      assert.equal("Enchanting", profText())
    end)
    it("leaves the current choice when nothing is implied", function()
      buttons["None"].onClick(); picked.onPick("tailoring")
      ns.Exchange.Form.Open() -- reset, then pick again after loading
      hook(LINK)
      assert.equal("None", profText())
      buttons["None"].onClick(); picked.onPick("tailoring")
      hook(LINK) -- same item again
      assert.equal("Tailoring", profText())
    end)
    it("does not override a hand-made choice for the same item", function()
      hook(POTION)
      buttons["None"].onClick(); picked.onPick("cooking")
      hook(POTION)
      assert.equal("Cooking", profText())
    end)
    it("a different item auto-fills again", function()
      hook(POTION)
      buttons["None"].onClick(); picked.onPick("cooking")
      hook(LINK) -- nothing implied: the earlier choice stays
      assert.equal("Cooking", profText())
      hook(POTION)
      assert.equal("Alchemy", profText())
    end)
    it("an edited listing keeps its own profession over auto-fill", function()
      ns.Exchange.Form.Open({ id = "p:1", d = { kind = "LF", item = POTION, mats = false, cod = false, prof = "cooking" } })
      assert.equal("Cooking", profText())
    end)
  end)
end)
