-- Exchange board helpers that need no frames.
describe("Exchange.Board", function()
  local Board
  before_each(function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    ns.UI = {}
    loadAddonFile(ns, "Guildhall/Modules/Exchange/UI/Board.lua")
    Board = ns.Exchange.Board
  end)

  it("says when a post made during lockdown will reach guildmates (M11)", function()
    assert.equal("Listing posted.", Board.SavedText(false, false))
    assert.equal("Listing saved.", Board.SavedText(true, false))
    assert.equal("Listing posted. It will reach guildmates when chat restrictions lift.", Board.SavedText(false, true))
    assert.equal("Listing saved. It will reach guildmates when chat restrictions lift.", Board.SavedText(true, true))
  end)
end)
