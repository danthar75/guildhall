-- UI.ItemIcon / UI.ItemTooltip (board rows and details pane).
describe("UI item icon helpers", function()
  local ns, UI, saved
  local LINK = "|cffffffff|Hitem:14047::::::::60:::::|h[Runecloth]|h|r"
  local G = { "C_Item", "GetItemIcon", "GameTooltip" }

  before_each(function()
    saved = {}
    for _, k in ipairs(G) do saved[k] = _G[k] end
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Core/UI/Window.lua")
    UI = ns.UI
  end)
  after_each(function() for _, k in ipairs(G) do _G[k] = saved[k] end end)

  it("uses the item's icon for a link and a question mark otherwise", function()
    _G.C_Item = { GetItemIconByID = function(id) return id == 14047 and 132903 or nil end }
    assert.equal(132903, UI.ItemIcon(LINK))
    assert.equal(UI.UNKNOWN_ICON, UI.ItemIcon("Runecloth"))
    assert.equal(UI.UNKNOWN_ICON, UI.ItemIcon(nil))
  end)

  it("falls back to GetItemIcon, and to the question mark if lookups fail", function()
    _G.C_Item = { GetItemIconByID = function() error("not cached") end }
    _G.GetItemIcon = function() return 999 end
    assert.equal(999, UI.ItemIcon(LINK))
    _G.GetItemIcon = nil
    assert.equal(UI.UNKNOWN_ICON, UI.ItemIcon(LINK))
  end)

  it("shows the standard tooltip only for item links", function()
    local shown = {}
    _G.GameTooltip = {
      SetOwner = function() end,
      SetHyperlink = function(_, l) shown[#shown + 1] = l end,
      Show = function() end,
    }
    UI.ItemTooltip({}, "Runecloth")
    UI.ItemTooltip({}, LINK)
    assert.same({ LINK }, shown)
  end)
end)
