-- Leaderboard section of the Settings tab: opt-out, weights editor, who may publish.
describe("Leaderboard.SettingsView", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, section, buttons, errors, officer, hidden, published, order, pubMap, pubResult, weights, info
  local GLOBALS = { "CreateFrame" }
  local saved = {}

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    buttons, errors, order, pubMap, pubResult = {}, {}, {}, nil, true
    officer, hidden, published = false, false, 0
    weights = { ["exchange.sales"] = 5, ["exchange.gold.earned"] = 0.1 }
    info = { char = "Dor-Realm", at = 1699999999 }
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/Activity.lua")
    ns.Activity.Register({ id = "exchange.sales", label = "Sales", unit = "count", verify = "paired", weight = 5, order = 20 })
    ns.Activity.Register({ id = "exchange.gold.earned", label = "Gold earned", unit = "gold", verify = "paired", weight = 0.1, order = 40 })
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.Boot = { PublishProfile = function() published = published + 1; order[#order + 1] = hidden end }
    ns.UI = {
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Text = function(_, _, text) local t = W.new("FontString"); t.text = text; return t end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; buttons[text] = b; return b
      end,
    }
    ns.services = {
      playerChar = "Dor-Realm",
      roster = { IsOfficer = function() return officer end },
      profile = {
        Id = function() return "p14" end,
        IsHidden = function() return hidden end,
        SetHidden = function(_, on) hidden = on end,
      },
    }
    ns.leaderboard = { config = {
      Weights = function() return weights end,
      Tz = function() return 0 end,
      WeightsInfo = function() return info end,
      PublishWeights = function(_, map) pubMap = map; return pubResult, (not pubResult) and "not accepted" or nil end,
    } }
    loadAddonFile(ns, "Guildhall/Core/Leaderboard/UI/SettingsView.lua")
    section = ns.Leaderboard.SettingsView.Build(W.new("Frame"))
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function handler(w, event)
    local h
    for _, c in ipairs(w.calls.SetScript or {}) do if c[1] == event then h = c[2] end end
    return h
  end
  local function type_(id, text) -- the user typing: SetText fires the handler as programmatic, so call it with userInput
    local box = section.boxes[id]
    box:SetText(text)
    handler(box, "OnTextChanged")(box, true)
  end
  local function becomeOfficer()
    officer = true
    section.refresh()
  end

  it("a non-officer sees no Publish button", function()
    assert.is_false(buttons["Publish weights"].shown)
    assert.is_false(section.boxes["exchange.sales"].shown)
    assert.same({}, errors)
  end)

  it("a non-officer never gets Reset buttons back from a box's OnTextChanged", function()
    section.refresh() -- SetText on each box fires OnTextChanged, as in the client
    for id in pairs(section.rows) do assert.is_not_true(section.rows[id].reset.shown) end
    assert.is_not_true(buttons["Publish weights"].shown)
  end)

  it("an officer sees Publish and the edit boxes", function()
    becomeOfficer()
    assert.is_true(buttons["Publish weights"].shown)
    assert.is_true(section.boxes["exchange.sales"].shown)
  end)

  it("Publish sends the weights", function()
    becomeOfficer()
    type_("exchange.sales", "7.5")
    buttons["Publish weights"].onClick()
    assert.same({ ["exchange.sales"] = 7.5, ["exchange.gold.earned"] = 0.1 }, pubMap)
    assert.same({}, errors)
  end)

  it("a changed weight shows in gold, and Reset restores the default", function()
    becomeOfficer()
    local box = section.boxes["exchange.gold.earned"] -- its Reset is the last one built
    local function lastColor() return box.calls.SetTextColor[#box.calls.SetTextColor] end
    type_("exchange.gold.earned", "3")
    assert.same({ 1, 0.82, 0 }, lastColor())
    buttons["Reset"].onClick()
    assert.equal("0.1", box:GetText())
    handler(box, "OnTextChanged")(box)
    assert.same({ 1, 1, 1 }, lastColor())
  end)

  it("an invalid entry shows the message and blocks Publish", function()
    becomeOfficer()
    for _, bad in ipairs({ "abc", "-1", "1001", "", "1e3", "0x10", "5 5" }) do
      pubMap = nil
      type_("exchange.sales", bad)
      assert.equal("Use a number from 0 to 1000.", section.error:GetText())
      buttons["Publish weights"].onClick()
      assert.is_nil(pubMap)
    end
    type_("exchange.sales", "1000")
    assert.equal("", section.error:GetText())
    type_("exchange.sales", ".5")
    buttons["Publish weights"].onClick()
    assert.equal(0.5, pubMap["exchange.sales"])
  end)

  it("a refresh leaves an edited, unpublished box alone until Publish or Reset", function()
    becomeOfficer()
    type_("exchange.sales", "7")
    section.refresh()
    assert.equal("7", section.boxes["exchange.sales"]:GetText())
    buttons["Publish weights"].onClick()
    weights["exchange.sales"] = 7
    section.refresh()
    assert.equal("7", section.boxes["exchange.sales"]:GetText())
    weights["exchange.sales"] = 6
    section.refresh() -- not dirty any more: follows the published value
    assert.equal("6", section.boxes["exchange.sales"]:GetText())
    type_("exchange.gold.earned", "3")
    buttons["Reset"].onClick() -- the last row's Reset
    weights["exchange.gold.earned"] = 0.1
    section.refresh()
    assert.equal("0.1", section.boxes["exchange.gold.earned"]:GetText())
  end)

  it("Reset is an unpublished edit that a refresh does not undo", function()
    weights["exchange.sales"] = 9
    becomeOfficer()
    assert.equal("9", section.boxes["exchange.sales"]:GetText())
    -- the sales row is first; its Reset is not the one in `buttons`, so click via the row
    section.rows["exchange.sales"].reset.onClick()
    assert.equal("5", section.boxes["exchange.sales"]:GetText())
    section.refresh()
    assert.equal("5", section.boxes["exchange.sales"]:GetText())
    type_("exchange.sales", "9") -- back to the published value: no longer an edit
    weights["exchange.sales"] = 8
    section.refresh()
    assert.equal("8", section.boxes["exchange.sales"]:GetText())
  end)

  it("has the Activity, Weight and Default header row", function()
    local seen = {}
    ns.UI.Text = function(_, _, text) local t = W.new("FontString"); t.text = text; seen[text or ""] = true; return t end
    ns.Leaderboard.SettingsView.Build(W.new("Frame"))
    assert.is_true(seen["Activity"] and seen["Weight"] and seen["Default"])
  end)

  it("names who last changed the weights, with the publish date", function()
    assert.equal("Last changed by Dor, 2023-11-14", section.changed:GetText())
    info = nil
    section.refresh()
    assert.equal("Weights are at their defaults.", section.changed:GetText())
  end)

  it("unchecking publishes a hidden profile", function()
    assert.is_true(section.check.checked) -- shown on the leaderboard
    section.check:SetChecked(false)
    handler(section.check, "OnClick")(section.check)
    assert.is_true(hidden)
    assert.same({ true }, order) -- the flag was set before the publish
    assert.equal(1, published)
    section.check:SetChecked(true)
    handler(section.check, "OnClick")(section.check)
    assert.is_false(hidden)
    assert.equal(2, published)
  end)

  it("shows the privacy note verbatim", function()
    local found
    local texts = {}
    ns.UI.Text = function(_, _, text) local t = W.new("FontString"); t.text = text; texts[#texts + 1] = t; return t end
    ns.Leaderboard.SettingsView.Build(W.new("Frame"))
    for _, t in ipairs(texts) do
      if t.text and t.text:find("^When this is off, your name isn't listed") then found = t.text end
    end
    assert.equal("When this is off, your name isn't listed, but your deals and donations still count toward the guild total. "
      .. "Guildhall only shows totals to members, and each breakdown only to its player and officers. "
      .. "The records still travel between guildmates' clients so deals can be checked, so someone reading their "
      .. "own SavedVariables file could see them.", found)
  end)
end)
