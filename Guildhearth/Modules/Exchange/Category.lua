local ADDON, ns = ...

-- Pure listing categorisation: profession keys, item class lookup, and the board category
-- of a listing payload. Only read-only item/profession APIs, every call under pcall. No frames
-- are created; WindowProf only inspects whether a profession window is shown.
ns.Exchange = ns.Exchange or {}

local Category = {}

-- Canonical professions: key, skill line ID, English fallback name. Ordered for display.
local PROFS = {
  { key = "alchemy", id = 171, name = "Alchemy" },
  { key = "blacksmithing", id = 164, name = "Blacksmithing" },
  { key = "cooking", id = 185, name = "Cooking" },
  { key = "enchanting", id = 333, name = "Enchanting" },
  { key = "engineering", id = 202, name = "Engineering" },
  { key = "firstaid", id = 129, name = "First Aid" },
  { key = "leatherworking", id = 165, name = "Leatherworking" },
  { key = "tailoring", id = 197, name = "Tailoring" },
}
local BY_KEY, BY_ID = {}, {}
for _, p in ipairs(PROFS) do BY_KEY[p.key] = p; BY_ID[p.id] = p end
Category.PROFS = PROFS
Category.PROFS_BY_KEY = BY_KEY

-- Board categories in display order (after "all"), with their labels.
Category.CATS = {
  { key = "crafted", label = "Crafted (all professions)", short = "Crafted" },
  { key = "materials", label = "Materials" },
  { key = "recipes", label = "Recipes" },
  { key = "gear", label = "Gear (BoE)" },
  { key = "other", label = "Other" },
}

local function safe(v)
  local c = ns.compat
  if c and c.Safe then return c:Safe(v) end
  return v
end

function Category.IsProfKey(s)
  if type(s) ~= "string" then return false end
  if BY_KEY[s] then return true end
  return #s >= 1 and #s <= 24 and s:find("^%l+$") ~= nil
end

local function englishName(key)
  local p = BY_KEY[key]
  if p then return p.name end
  return key:sub(1, 1):upper() .. key:sub(2)
end

-- Localized name from the game when it has one, else English.
function Category.ProfName(key)
  if type(key) ~= "string" then return "?" end
  local p = BY_KEY[key]
  local api = p and C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName
  if api then
    local ok, name = pcall(api, p.id)
    name = ok and safe(name) or nil
    if type(name) == "string" and name ~= "" then return name end
  end
  return englishName(key)
end

-- Enum values with numeric fallbacks.
local function enumVal(tbl, name, fallback)
  local v = type(tbl) == "table" and tbl[name]
  if type(v) == "number" then return v end
  return fallback
end

local function classes()
  local e = Enum and Enum.ItemClass
  return {
    consumable = enumVal(e, "Consumable", 0), reagent = enumVal(e, "Reagent", 5),
    weapon = enumVal(e, "Weapon", 2), armor = enumVal(e, "Armor", 4),
    tradegoods = enumVal(e, "Tradegoods", 7), recipe = enumVal(e, "Recipe", 9),
  }
end

local function consumables()
  local e = Enum and Enum.ItemConsumableSubclass
  return {
    potion = enumVal(e, "Potion", 1), elixir = enumVal(e, "Elixir", 2),
    flask = enumVal(e, "Flasksphials", enumVal(e, "Flask", 3)),
    food = enumVal(e, "Fooddrink", 5), bandage = enumVal(e, "Bandage", 7),
  }
end

-- recipe subclass -> profession key
local function recipeProfs()
  local e = Enum and Enum.ItemRecipeSubclass
  return {
    [enumVal(e, "Leatherworking", 1)] = "leatherworking", [enumVal(e, "Tailoring", 2)] = "tailoring",
    [enumVal(e, "Engineering", 3)] = "engineering", [enumVal(e, "Blacksmithing", 4)] = "blacksmithing",
    [enumVal(e, "Cooking", 5)] = "cooking", [enumVal(e, "Alchemy", 6)] = "alchemy",
    [enumVal(e, "FirstAid", 7)] = "firstaid", [enumVal(e, "Enchanting", 8)] = "enchanting",
  }
end

-- classID, subClassID for an item link; nil for anything else or on failure.
function Category.ItemClass(item)
  if type(item) ~= "string" or not item:find("|Hitem:", 1, true) then return nil end
  local api = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not api then return nil end
  local ok, _, _, _, _, _, classID, subClassID = pcall(api, item)
  if not ok then return nil end
  classID, subClassID = safe(classID), safe(subClassID)
  if type(classID) ~= "number" then return nil end
  return classID, type(subClassID) == "number" and subClassID or nil
end

function Category.ImpliedProf(item)
  local class, sub = Category.ItemClass(item)
  if not class then return nil end
  local C = classes()
  if class == C.recipe then return sub and recipeProfs()[sub] or nil end
  if class == C.consumable and sub then
    local S = consumables()
    if sub == S.potion or sub == S.elixir or sub == S.flask then return "alchemy" end
    if sub == S.food then return "cooking" end
    if sub == S.bandage then return "firstaid" end
  end
  return nil
end

-- Listing payload -> category, effective profession. Never raises.
function Category.Of(d)
  if type(d) ~= "table" then return "other", nil end
  local prof = d.prof
  if not Category.IsProfKey(prof) then prof = nil end
  local ok, class, c2 = pcall(Category.ItemClass, d.item)
  if not ok then class = nil end
  if not prof then
    local ok2, p = pcall(Category.ImpliedProf, d.item)
    if ok2 then prof = p end
  end
  local C = classes()
  if class == C.recipe then return "recipes", prof end
  if prof then return "crafted", prof end
  if class == C.tradegoods or class == C.reagent then return "materials", nil end
  if class == C.weapon or class == C.armor then return "gear", nil end
  return "other", nil
end

-- Which optional form fields make sense for a listing payload: matsApplies, profApplies.
-- "I will provide materials" only means something for crafting (a profession is set) or
-- for items we can't classify (a typed name may be a crafting request). The profession
-- picker is pointless for materials, and implied by the recipe itself for recipes.
function Category.Applies(d)
  local cat = Category.Of(d)
  if cat == "materials" or cat == "recipes" then return false, false end
  if cat == "gear" then return false, true end
  return true, true -- crafted, other
end

-- Profession window detection (auto-fill) -------------------------------------------

-- Profession key for a localized or English name, nil when unknown.
function Category.KeyFromName(name)
  name = safe(name)
  if type(name) ~= "string" or name == "" then return nil end
  local lower = name:lower()
  for _, p in ipairs(PROFS) do
    if lower == Category.ProfName(p.key):lower() or lower == p.name:lower() then return p.key end
  end
  local k = lower:gsub("[^%a]", "")
  if k ~= "" and Category.IsProfKey(k) and k == lower:gsub("%s", "") then return k end
  return nil
end

local function shown(f)
  if type(f) ~= "table" or not f.IsShown then return false end
  local ok, s = pcall(f.IsShown, f)
  return ok and safe(s) == true
end

-- Profession of the open profession window, or nil.
function Category.WindowProf()
  if shown(ProfessionsFrame) and C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if ok and type(info) == "table" then
      local id = safe(info.professionID)
      if type(id) == "number" and BY_ID[id] then return BY_ID[id].key end
      local k = Category.KeyFromName(info.professionName)
      if k then return k end
    end
  end
  if shown(TradeSkillFrame) and GetTradeSkillLine then
    local ok, name = pcall(GetTradeSkillLine)
    if ok then
      local k = Category.KeyFromName(name)
      if k then return k end
    end
  end
  if shown(CraftFrame) then return "enchanting" end
  return nil
end

ns.Exchange.Category = Category
