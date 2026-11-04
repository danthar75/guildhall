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
    loadAddonFile(ns, "Guildhall/Core/Log.lua")
    loadAddonFile(ns, "Guildhall/Core/UI/LogView.lua")
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

  it("an officer export does", function()
    local text = ns.UI.LogView.Export(log, entries, true)
    assert.is_truthy(text:find("Secretchar", 1, true))
    assert.is_truthy(text:find("copper=12345", 1, true))
    assert.is_truthy(text:find("p9:o3", 1, true))
    assert.is_nil(text:find("received", 1, true))
  end)
end)
