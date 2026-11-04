-- Listing categories and professions: pure logic over stubbed item APIs.
describe("Exchange.Category", function()
  local C, ns
  local GLOBALS = { "C_Item", "GetItemInfoInstant", "Enum", "C_TradeSkillUI", "ProfessionsFrame",
    "TradeSkillFrame", "CraftFrame", "GetTradeSkillLine" }
  local saved = {}
  local function link(id) return "|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[X" .. id .. "]|h|r" end
  -- id -> { class, sub }
  local items
  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k]; _G[k] = nil end
    items = {
      [1] = { 7, 5 },   -- tradegoods
      [2] = { 5, 0 },   -- reagent
      [3] = { 2, 7 },   -- weapon
      [4] = { 4, 1 },   -- armor
      [5] = { 9, 2 },   -- recipe: tailoring
      [6] = { 0, 1 },   -- potion
      [7] = { 0, 2 },   -- elixir
      [8] = { 0, 3 },   -- flask
      [9] = { 0, 5 },   -- food
      [10] = { 0, 7 },  -- bandage
      [11] = { 15, 0 }, -- misc
      [12] = { 9, 6 },  -- recipe: alchemy
    }
    _G.GetItemInfoInstant = function(l)
      local id = tonumber(tostring(l):match("item:(%d+)"))
      local it = items[id]
      if not it then return nil end
      return id, "t", "s", "", 1, it[1], it[2]
    end
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Category.lua")
    C = ns.Exchange.Category
  end)
  after_each(function() for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end end)

  it("Applies: which form fields make sense for an item", function()
    local function ap(d) local m, p = C.Applies(d); return { m, p } end
    assert.same({ false, false }, ap({ item = link(1) }))                     -- materials
    assert.same({ false, false }, ap({ item = link(2) }))                     -- reagent
    assert.same({ false, false }, ap({ item = link(5) }))                     -- recipe
    assert.same({ false, true }, ap({ item = link(3) }))                      -- BoE gear
    assert.same({ true, true }, ap({ item = link(3), prof = "blacksmithing" })) -- crafted gear
    assert.same({ true, true }, ap({ item = link(6) }))                       -- potion: crafted
    assert.same({ true, true }, ap({ item = link(11) }))                      -- other
    assert.same({ true, true }, ap({ item = "Custom robe" }))                 -- typed name
    assert.same({ true, true }, ap({}))
  end)

  it("IsProfKey accepts canonical and plausible future keys only", function()
    assert.is_true(C.IsProfKey("tailoring"))
    assert.is_true(C.IsProfKey("jewelcrafting"))
    assert.is_false(C.IsProfKey("Tailoring"))
    assert.is_false(C.IsProfKey("a b"))
    assert.is_false(C.IsProfKey(""))
    assert.is_false(C.IsProfKey(5))
    assert.is_false(C.IsProfKey(string.rep("a", 25)))
  end)

  it("ProfName prefers the game's name, falls back to English, survives errors", function()
    assert.equal("First Aid", C.ProfName("firstaid"))
    _G.C_TradeSkillUI = { GetTradeSkillDisplayName = function(id) return id == 197 and "Schneiderei" or nil end }
    assert.equal("Schneiderei", C.ProfName("tailoring"))
    assert.equal("Alchemy", C.ProfName("alchemy"))
    _G.C_TradeSkillUI = { GetTradeSkillDisplayName = function() error("x") end }
    assert.equal("Cooking", C.ProfName("cooking"))
    assert.equal("Jewelcrafting", C.ProfName("jewelcrafting"))
  end)

  it("ItemClass reads returns 6 and 7, nil for non-links and failures", function()
    assert.same({ 9, 2 }, { C.ItemClass(link(5)) })
    assert.is_nil(C.ItemClass("Linen Cloth"))
    assert.is_nil(C.ItemClass(nil))
    assert.is_nil(C.ItemClass(link(999)))
    _G.GetItemInfoInstant = function() error("boom") end
    assert.is_nil(C.ItemClass(link(5)))
  end)

  it("ItemClass prefers C_Item.GetItemInfoInstant", function()
    _G.C_Item = { GetItemInfoInstant = function() return 1, "", "", "", 1, 4, 2 end }
    assert.same({ 4, 2 }, { C.ItemClass(link(1)) })
  end)

  it("ImpliedProf follows item type", function()
    assert.equal("tailoring", C.ImpliedProf(link(5)))
    assert.equal("alchemy", C.ImpliedProf(link(12)))
    assert.equal("alchemy", C.ImpliedProf(link(6)))
    assert.equal("alchemy", C.ImpliedProf(link(7)))
    assert.equal("alchemy", C.ImpliedProf(link(8)))
    assert.equal("cooking", C.ImpliedProf(link(9)))
    assert.equal("firstaid", C.ImpliedProf(link(10)))
    assert.is_nil(C.ImpliedProf(link(1)))
    assert.is_nil(C.ImpliedProf("Linen Cloth"))
  end)

  it("uses Enum values when present", function()
    _G.Enum = { ItemClass = { Recipe = 77, Tradegoods = 1 } }
    items[20] = { 77, 2 }
    items[21] = { 1, 0 }
    assert.equal("recipes", (C.Of({ item = link(20) })))
    assert.equal("materials", (C.Of({ item = link(21) })))
  end)

  it("Of applies the rules in order", function()
    local function of(d) return { C.Of(d) } end
    assert.same({ "recipes", "tailoring" }, of({ item = link(5) }))
    assert.same({ "recipes", "alchemy" }, of({ item = link(5), prof = "alchemy" }))
    assert.same({ "crafted", "alchemy" }, of({ item = link(6) }))
    assert.same({ "crafted", "cooking" }, of({ item = link(1), prof = "cooking" }))
    assert.same({ "crafted", "enchanting" }, of({ item = "Enchant Boots", prof = "enchanting" }))
    assert.same({ "materials" }, of({ item = link(1) }))
    assert.same({ "materials" }, of({ item = link(2) }))
    assert.same({ "gear" }, of({ item = link(3) }))
    assert.same({ "gear" }, of({ item = link(4) }))
    assert.same({ "other" }, of({ item = link(11) }))
    assert.same({ "other" }, of({ item = "Linen Cloth" }))
  end)

  it("Of ignores an invalid prof and never raises on odd input", function()
    assert.same({ "materials" }, { C.Of({ item = link(1), prof = "Bad Key" }) })
    assert.same({ "other" }, { C.Of(nil) })
    assert.same({ "other" }, { C.Of("x") })
    assert.same({ "other" }, { C.Of({}) })
    assert.same({ "other" }, { C.Of({ item = 5, prof = {} }) })
    _G.GetItemInfoInstant = function() error("boom") end
    assert.same({ "other" }, { C.Of({ item = link(1) }) })
  end)

  describe("WindowProf", function()
    local function frame(shown) return { IsShown = function() return shown end } end
    it("is nil with no profession window", function()
      assert.is_nil(C.WindowProf())
    end)
    it("reads the Mainline ProfessionsFrame skill line", function()
      _G.ProfessionsFrame = frame(true)
      _G.C_TradeSkillUI = { GetBaseProfessionInfo = function() return { professionID = 197 } end }
      assert.equal("tailoring", C.WindowProf())
    end)
    it("ignores a hidden ProfessionsFrame", function()
      _G.ProfessionsFrame = frame(false)
      _G.C_TradeSkillUI = { GetBaseProfessionInfo = function() return { professionID = 197 } end }
      assert.is_nil(C.WindowProf())
    end)
    it("falls back to the profession name for unknown ids", function()
      _G.ProfessionsFrame = frame(true)
      _G.C_TradeSkillUI = { GetBaseProfessionInfo = function()
        return { professionID = 755, professionName = "Jewelcrafting" } end }
      assert.equal("jewelcrafting", C.WindowProf())
    end)
    it("maps the Era TradeSkillFrame name, localized or English", function()
      _G.TradeSkillFrame = frame(true)
      _G.GetTradeSkillLine = function() return "First Aid" end
      assert.equal("firstaid", C.WindowProf())
      _G.C_TradeSkillUI = { GetTradeSkillDisplayName = function(id) return id == 164 and "Schmiedekunst" or nil end }
      _G.GetTradeSkillLine = function() return "Schmiedekunst" end
      assert.equal("blacksmithing", C.WindowProf())
    end)
    it("treats an open CraftFrame as enchanting", function()
      _G.CraftFrame = frame(true)
      assert.equal("enchanting", C.WindowProf())
    end)
    it("survives API errors", function()
      _G.ProfessionsFrame = frame(true)
      _G.C_TradeSkillUI = { GetBaseProfessionInfo = function() error("x") end }
      assert.is_nil(C.WindowProf())
    end)
  end)
end)
