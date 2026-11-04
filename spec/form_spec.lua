-- Exchange listing form under fake frames: input limits (M10) and the InsertLink hook (M9).
describe("Exchange.Form", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, hook, texts, panel, errors
  local saved = {}
  local GLOBALS = { "CreateFrame", "hooksecurefunc", "ChatFrameUtil" }
  local LINK = "|cffa335ee|Hitem:14152::::::::60:::::|h[Robe of the Archmage]|h|r"
  local SECRET = "|cff1eff00|Hitem:2589::::::::60:::::|h[Linen Cloth]|h|r"

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    texts, errors, hook = {}, {}, nil
    _G.CreateFrame = W.CreateFrame
    _G.hooksecurefunc = function(tbl, name, fn) hook = fn end
    _G.ChatFrameUtil = { InsertLink = function() end }
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    ns.compat = fakes.compat({ issecretvalue = function(v) return v == SECRET end })
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.UI = {
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Text = function() local t = W.new("FontString"); texts[#texts + 1] = t; return t end,
      Button = function() return W.new("Button") end,
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

  it("the InsertLink hook never lets an error escape (M9)", function()
    panel.IsShown = function() error("boom") end
    assert.has_no.errors(function() hook(LINK) end)
    assert.equal(1, #errors)
  end)
end)
