-- Exchange board helpers that need no frames.
describe("Exchange.Board", function()
  local Board
  before_each(function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    ns.UI = {}
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Category.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/UI/Board.lua")
    Board = ns.Exchange.Board
    _G.GetItemInfoInstant = function(l)
      local id = tonumber(tostring(l):match("item:(%d+)"))
      local cls = ({ [1] = { 7, 5 }, [2] = { 0, 1 }, [3] = { 9, 2 }, [4] = { 4, 1 } })[id]
      if not cls then return nil end
      return id, "", "", "", 1, cls[1], cls[2]
    end
  end)
  after_each(function() _G.GetItemInfoInstant = nil end)

  local function link(id) return "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[Item" .. id .. "]|h|r" end
  local function rec(by, item, o)
    local r = { id = by .. ":" .. tostring(item), by = by, char = by .. "-Realm", t = 100, d = { kind = "LF", item = item, mats = false, cod = false } }
    for k, v in pairs(o or {}) do r.d[k] = v end
    return r
  end

  describe("Matches", function()
    it("passes everything with no filters", function()
      assert.is_true(Board.Matches(rec("p1", "Linen"), {}))
      assert.is_true(Board.Matches(rec("p1", "Linen"), nil))
      assert.is_false(Board.Matches({ id = "x" }, {}))
    end)
    it("filters by search text on item name, char and poster", function()
      assert.is_true(Board.Matches(rec("p1", "Linen Cloth"), { needle = "linen" }))
      assert.is_true(Board.Matches(rec("p1", "Linen Cloth"), { needle = "p1-r" }))
      assert.is_false(Board.Matches(rec("p1", "Linen Cloth"), { needle = "silk" }))
    end)
    it("filters by member profile", function()
      assert.is_true(Board.Matches(rec("p1", "A"), { member = "p1" }))
      assert.is_false(Board.Matches(rec("p2", "A"), { member = "p1" }))
    end)
    it("groups Discord imports under the poster name", function()
      local r = rec("imp", "A", { src = "discord", poster = "Brakka" })
      assert.equal("discord:Brakka", Board.MemberKey(r))
      assert.is_true(Board.Matches(r, { member = "discord:Brakka" }))
      assert.is_false(Board.Matches(r, { member = "imp" }))
    end)
    it("filters by category and by profession", function()
      local mats, potion, recipe, gear = rec("p", link(1)), rec("p", link(2)), rec("p", link(3)), rec("p", link(4))
      local typed = rec("p", "Silk Bolt", { prof = "tailoring" })
      assert.is_true(Board.Matches(mats, { cat = "materials" }))
      assert.is_false(Board.Matches(mats, { cat = "gear" }))
      assert.is_true(Board.Matches(potion, { cat = "crafted" }))
      assert.is_true(Board.Matches(potion, { cat = "prof:alchemy" }))
      assert.is_false(Board.Matches(potion, { cat = "prof:cooking" }))
      assert.is_true(Board.Matches(typed, { cat = "prof:tailoring" }))
      assert.is_true(Board.Matches(recipe, { cat = "recipes" }))
      assert.is_false(Board.Matches(recipe, { cat = "crafted" }))
      assert.is_true(Board.Matches(gear, { cat = "gear" }))
      assert.is_true(Board.Matches(rec("p", "Hand typed"), { cat = "other" }))
      assert.is_true(Board.Matches(mats, { cat = "all" }))
    end)
    it("combines category, member and search", function()
      local r = rec("p1", link(2))
      assert.is_true(Board.Matches(r, { cat = "crafted", member = "p1", needle = "item2" }))
      assert.is_false(Board.Matches(r, { cat = "crafted", member = "p2", needle = "item2" }))
      assert.is_false(Board.Matches(r, { cat = "crafted", member = "p1", needle = "zzz" }))
    end)
  end)

  describe("popup entries", function()
    it("CategoryItems lists only professions present, indented under Crafted", function()
      local items = Board.CategoryItems({ rec("p", link(2)), rec("p", "Silk", { prof = "tailoring" }), rec("p", link(1)) })
      local values = {}
      for _, it in ipairs(items) do values[#values + 1] = it.value end
      assert.same({ "all", "crafted", "prof:alchemy", "prof:tailoring", "materials", "recipes", "gear", "other" }, values)
      assert.equal(14, items[3].indent)
      assert.equal("Alchemy", items[3].label)
    end)
    it("CategoryItems has no profession entries when none appear", function()
      assert.equal(6, #Board.CategoryItems({ rec("p", link(1)) }))
    end)
    it("MemberItems is Anyone plus sorted members, Discord grouped by poster", function()
      local recs = { rec("p2", "A"), rec("p1", "B"), rec("p1", "C", { }), rec("imp", "D", { src = "discord", poster = "Axl" }) }
      local items = Board.MemberItems(recs, function(r) return r.by == "p1" and "Zed" or "Brakka" end)
      local labels = {}
      for _, it in ipairs(items) do labels[#labels + 1] = it.label end
      assert.same({ "Anyone", "Axl (Discord)", "Brakka", "Zed" }, labels)
      assert.is_false(items[1].value)
      assert.equal("discord:Axl", items[2].value)
    end)
  end)

  it("says when a post made during lockdown will reach guildmates (M11)", function()
    assert.equal("Listing posted.", Board.SavedText(false, false))
    assert.equal("Listing saved.", Board.SavedText(true, false))
    assert.equal("Listing posted. It will reach guildmates when chat restrictions lift.", Board.SavedText(false, true))
    assert.equal("Listing saved. It will reach guildmates when chat restrictions lift.", Board.SavedText(true, true))
  end)
end)
