-- Log tab text: observation entries are counts only for non-officers.
describe("LogView export", function()
  local ns, log, entries
  local function fmt(t) return os.date("!%Y-%m-%d %H:%M:%S", t) end

  local function obs(kind, t, id)
    return { t = t, set = "core.observations", action = "observe", result = "accepted", id = id,
      v = 1, author = "p9", authorChar = "Secretchar", after = { kind = kind },
      detail = { kind = kind, player = "Secretchar", copper = 12345, at = t } }
  end

  before_each(function()
    ns = { UI = {}, Util = { Trim = function(s) return s end } }
    loadAddonFile(ns, "Guildhearth/Core/Log.lua")
    loadAddonFile(ns, "Guildhearth/Core/UI/LogView.lua")
    log = ns.Log.new({}, function() return 5000 end, fmt)
    -- newest first, as Log:Query returns them
    entries = {
      obs("trade", 1700000500, "p9:o1"), obs("trade", 1700000400, "p9:o2"),
      obs("bank", 1700000300, "p9:o3"), obs("bank", 1700000200, "p9:o4"),
      { t = 1700000100, set = "profiles", action = "set", result = "accepted", id = "p1", author = "p1" },
      obs("bank", 1700000050, "p9:o5"),
    }
  end)

  it("a non-officer export has no payload fields", function()
    local text = ns.UI.LogView.Export(log, entries, false)
    assert.is_nil(text:find("Secretchar", 1, true))
    assert.is_nil(text:find("12345", 1, true))
    assert.is_nil(text:find("p9", 1, true))
    assert.is_nil(text:find("detail", 1, true))
    assert.is_truthy(text:find("| observations | received 4 (trade 2, bank 2)", 1, true))
    assert.is_truthy(text:find("| observations | received 1 (bank 1)", 1, true))
    assert.equal(fmt(1700000500) .. " | observations | received 4 (trade 2, bank 2)", text:match("^[^\n]+"))
    -- the non-observation entry is untouched between the two runs
    assert.is_truthy(text:find("| set | accepted | p1 | p1 |", 1, true))
  end)

  it("N counts only accepted entries, so it equals the per-kind sum", function()
    local ignored = obs("trade", 1700000450, "p9:o9")
    ignored.result, ignored.after = "ignored", nil
    table.insert(entries, 2, ignored)
    local text = ns.UI.LogView.Export(log, entries, false)
    assert.is_truthy(text:find("received 4 (trade 2, bank 2)", 1, true))
  end)

  local function cfgEntry(id, detail, result, char)
    result, char = result or "accepted", char or "Reviewer-Realm"
    return { t = 1700000600, set = "core.config", action = result == "accepted" and "config" or "invalid",
      result = result, id = id, v = 1, author = "pOfficer", authorChar = char,
      relayer = char, detail = detail, reason = result ~= "accepted" and "author lacks permission" or nil }
  end
  local REF = "bank:0123456789ab:o1700000000_1"

  it("bank review entries collapse to one line without the officer's name for non-officers", function()
    local list = {
      cfgEntry("exclude:" .. REF, { ref = REF, excluded = true, by = "Reviewer-Realm", at = 1, reason = "funds" }),
      cfgEntry("history:pOfficer:1700000600:1", { what = "bank", key = REF, by = "Reviewer-Realm", at = 1,
        before = { excluded = false }, after = { excluded = true } }),
      cfgEntry("history:pOfficer:1700000601:2", nil, "rejected"),
      cfgEntry("weights", { weights = { sales = 5 } }),
    }
    local text = ns.UI.LogView.Export(log, list, false)
    local lines = {}
    for l in text:gmatch("[^\n]+") do lines[#lines + 1] = l end
    assert.equal(fmt(1700000600) .. " | bank review | received", lines[1])
    assert.equal(fmt(1700000600) .. " | bank review | received", lines[2])
    assert.equal(fmt(1700000600) .. " | bank review | rejected", lines[3])
    for i = 1, 3 do
      assert.is_nil(lines[i]:find("Reviewer", 1, true))
      assert.is_nil(lines[i]:find("pOfficer", 1, true))
      assert.is_nil(lines[i]:find("funds", 1, true))
    end
    -- weights entries are unchanged
    assert.is_truthy(lines[4]:find("weights", 1, true))
    -- an officer sees everything
    local full = ns.UI.LogView.Export(log, list, true)
    assert.is_truthy(full:find("Reviewer-Realm", 1, true))
    assert.is_nil(full:find("bank review", 1, true))
  end)

  it("a non-officer's filter can't find bank review entries by name", function()
    local GUILD = { roster = { IsOfficer = function() return false end }, playerChar = "Me-Realm" }
    local list = { cfgEntry("exclude:" .. REF, { ref = REF, excluded = true, by = "Reviewer-Realm", at = 1 }),
      cfgEntry("weights", { weights = { sales = 5 } }, nil, "Gm-Realm") }
    GUILD.log = setmetatable({ Query = function() return list end }, { __index = log })
    ns.services = GUILD
    local W = require("spec.helpers.fakes").widgets()
    ns.UI.Text = function() return W.new("FontString") end
    local savedCF = _G.CreateFrame
    _G.CreateFrame = W.CreateFrame
    ns.UI.Button = function() return W.new("Button") end
    ns.UI.ScrollText = function() return W.new("Scroll"), W.new("Edit") end
    local shown
    ns.UI.SetReadOnlyText = function(_, text) shown = text end
    ns.UI.Try = function(fn, ...) return fn(...) end
    ns.Util.Trim = function(x) return x end
    local view = ns.UI.LogView.Build(W.new("Frame"))
    _G.CreateFrame = savedCF
    view.filter:SetText("reviewer")
    view.refresh()
    assert.equal("No log entries.", shown)
    view.filter:SetText("exclude:")
    view.refresh()
    assert.equal("No log entries.", shown)
    view.filter:SetText("gm-realm")
    view.refresh()
    assert.is_truthy(shown:find("weights v1", 1, true))
    view.filter:SetText("")
    view.refresh()
    assert.is_truthy(shown:find("bank review", 1, true))
    assert.is_nil(shown:find("Reviewer", 1, true))
    ns.services = nil
  end)

  it("an officer export does", function()
    local text = ns.UI.LogView.Export(log, entries, true)
    assert.is_truthy(text:find("Secretchar", 1, true))
    assert.is_truthy(text:find("copper=12345", 1, true))
    assert.is_truthy(text:find("p9:o3", 1, true))
    assert.is_nil(text:find("received", 1, true))
  end)
end)
