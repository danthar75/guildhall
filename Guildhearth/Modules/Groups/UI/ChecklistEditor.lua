local ADDON, ns = ...

-- Groups: the checklist editor. ChecklistEditor.Open(instance, id|nil) edits a raid checklist (a new
-- one when id is nil or no longer live): its name (1..32 bytes) and up to 12 lines, each an item with
-- a count (1..200), "All gear enchanted" or a line of text (64 bytes). Save calls
-- ns.groups.checklist:Save, which checks the "checklists" permission and the lines; its refusal is
-- shown in the editor. Without the permission tonight the editor says so and Save is off.
-- Items: shift-click (Form.ListenLinks), drag onto the item box's slot, or a typed item ID.
-- Named global frame: "GuildhearthUIChecklistEditor".
ns.Groups = ns.Groups or {}
local UI = ns.UI
local Util = ns.Util
local Editor = {}
ns.Groups.ChecklistEditor = Editor

local WIDTH, HEIGHT = 420, 520
local MAX_LINES, NAME_MAX, TEXT_MAX, COUNT_MAX = 12, 32, 64, 200
local ROW_H, ROWS_Y = 20, 84
local FULL = "A checklist holds at most 12 lines."

local ERRORS = {
  ["bad name"] = "Name the checklist (1 to 32 bytes).",
  ["bad lines"] = FULL,
  ["bad instance"] = "That run can't have a checklist.",
  ["bad id"] = "That checklist can't be saved for this run.",
}

local frame
local f = { lines = {}, rows = {} }
Editor._f = f -- for the specs

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function compat() return ns.services and ns.services.compat end

local function errorText(err)
  if ERRORS[err] then return ERRORS[err] end
  local D = ns.Groups.Details
  if D and D.ErrorText then return D.ErrorText(err) end
  return "That didn't work: " .. tostring(err)
end

local function setError(text) f.error:SetText(text or "") end

local function itemName(id)
  local c = compat()
  local name = c and c.ItemName and c:ItemName(id) or nil
  if type(name) == "string" and name ~= "" then return name end
  return "Item " .. tostring(id)
end

local function lineText(l)
  if l.kind == "item" then return l.count .. " × " .. Util.Escape(itemName(l.item)) end
  if l.kind == "enchants" then return "All gear enchanted" end
  return Util.Escape(l.text or "")
end

local function render()
  for i, row in ipairs(f.rows) do
    local l = f.lines[i]
    if l then
      row.text:SetText(lineText(l))
      row.text:Show(); row.remove:Show()
    else
      row.text:SetText("")
      row.text:Hide(); row.remove:Hide()
    end
  end
  f.countText:SetText(string.format("%d/%d lines", #f.lines, MAX_LINES))
  local full = #f.lines >= MAX_LINES
  for _, b in ipairs({ f.addItem, f.addEnchants, f.addText }) do
    if full then b:Disable() else b:Enable() end
  end
end

local function add(line)
  if #f.lines >= MAX_LINES then setError(FULL); return false end
  f.lines[#f.lines + 1] = line
  setError(nil)
  render()
  return true
end

local function remove(i)
  if not f.lines[i] then return end
  table.remove(f.lines, i)
  setError(nil)
  render()
end

local function setItemLink(link)
  f.itemLink = link
  f.item:SetText(link and Util.ItemName(link) or "")
end

-- The item the item box names: the loaded link while the box still shows its name, else a typed ID.
local function itemId()
  local text = Util.Trim(f.item:GetText() or "")
  if f.itemLink and text == Util.ItemName(f.itemLink) then
    return tonumber(Util.ItemIdFromLink(f.itemLink))
  end
  local id = tonumber(text:match("^%d+$") or "")
  if id and id >= 1 and id <= 2147483647 then return id end
  return nil
end

local function addItem()
  if #f.lines >= MAX_LINES then setError(FULL); return end
  local id = itemId()
  if not id then setError("Shift-click or drag an item in, or type its item ID."); return end
  local count = tonumber(f.count:GetText() or "")
  if not count or count < 1 or count > COUNT_MAX or count ~= math.floor(count) then
    setError("Count must be 1 to 200.")
    return
  end
  if add({ kind = "item", item = id, count = count }) then
    setItemLink(nil)
    f.count:SetText("1")
  end
end

local function addEnchants()
  for _, l in ipairs(f.lines) do
    if l.kind == "enchants" then setError("All gear enchanted is already on the list."); return end
  end
  add({ kind = "enchants" })
end

local function addText()
  local text = Util.Trim(f.text:GetText() or "")
  if text == "" then setError("Type the line first."); return end
  if add({ kind = "manual", text = text }) then f.text:SetText("") end
end

local function save()
  local g = ns.groups
  local cl = g and g.checklist
  if not cl then setError("Guildhearth isn't ready yet. Try again in a moment."); return end
  local lines = {}
  for i, l in ipairs(f.lines) do lines[i] = Util.DeepCopy(l) end
  local ok, res = cl:Save({ id = f.id, instance = f.instance, name = Util.Trim(f.name:GetText() or ""),
    lines = lines })
  if not ok then setError(errorText(res)); return end
  setError(nil)
  frame:Hide()
  local View = ns.Groups.View
  if View and View.Refresh then View.Refresh() end
end

local function onLink(link)
  if not (frame and frame:IsShown()) then return end
  if not Util.IsItemLink(link) then return false end
  setItemLink(link)
  return true
end

-- Build ---------------------------------------------------------------------------------------------

local function input(width)
  local e = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  on(e, "OnEscapePressed", function(self) self:ClearFocus() end)
  on(e, "OnEnterPressed", function(self) self:ClearFocus() end)
  return e
end

local function label(text, x, y, font)
  local t = UI.Text(frame, font or "GameFontNormal", text)
  t:SetPoint("TOPLEFT", x, y)
  return t
end

local function build()
  if frame then return end
  frame = UI.CreatePanel("GuildhearthUIChecklistEditor", WIDTH, HEIGHT, "Checklist")
  f.frame = frame
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhearthUIChecklistEditor") end

  label("Name:", 20, -50)
  f.name = input(240)
  f.name:SetMaxBytes(NAME_MAX + 1)
  f.name:SetPoint("TOPLEFT", 80, -46)

  f.countText = UI.Text(frame, "GameFontDisableSmall")
  f.countText:SetPoint("TOPRIGHT", -20, -70)
  label("Lines:", 20, -70)

  for i = 1, MAX_LINES do
    local y = -ROWS_Y - (i - 1) * ROW_H
    local row = {}
    row.text = UI.Text(frame, "GameFontHighlight")
    row.text:SetPoint("TOPLEFT", 28, y - 3)
    row.text:SetWidth(WIDTH - 90)
    if row.text.SetWordWrap then row.text:SetWordWrap(false) end
    row.text:SetJustifyH("LEFT")
    row.remove = UI.Button(frame, "×", 22, function() remove(i) end)
    row.remove:SetPoint("TOPRIGHT", -20, y)
    f.rows[i] = row
  end

  local y = -ROWS_Y - MAX_LINES * ROW_H - 10
  label("Item:", 20, y - 4)
  f.slot = CreateFrame("Button", nil, frame)
  f.slot:SetSize(20, 20)
  f.slot:SetPoint("TOPLEFT", 64, y)
  f.slot:RegisterForClicks("LeftButtonUp")
  local icon = f.slot:CreateTexture(nil, "ARTWORK")
  icon:SetAllPoints(f.slot)
  icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
  local function takeCursor()
    local link = ns.Groups.Form and ns.Groups.Form.CursorLink and ns.Groups.Form.CursorLink()
    if link then setItemLink(link) end
  end
  on(f.slot, "OnReceiveDrag", takeCursor)
  on(f.slot, "OnClick", takeCursor)
  f.item = input(150)
  f.item:SetPoint("TOPLEFT", 92, y)
  label("Count:", 252, y - 4)
  f.count = input(36)
  f.count:SetNumeric(true)
  f.count:SetMaxLetters(3)
  f.count:SetPoint("TOPLEFT", 300, y)
  f.addItem = UI.Button(frame, "Add item", 70, addItem)
  f.addItem:SetPoint("TOPRIGHT", -16, y)
  local hint = label("Shift-click or drag an item in, or type its item ID.", 20, y - 24, "GameFontDisableSmall")
  hint:SetWidth(WIDTH - 40)

  y = y - 48
  label("Text:", 20, y - 4)
  f.text = input(250)
  f.text:SetMaxBytes(TEXT_MAX + 1)
  f.text:SetPoint("TOPLEFT", 64, y)
  f.addText = UI.Button(frame, "Add text", 70, addText)
  f.addText:SetPoint("TOPRIGHT", -16, y)

  f.addEnchants = UI.Button(frame, "All gear enchanted", 150, addEnchants)
  f.addEnchants:SetPoint("TOPLEFT", 20, y - 30)

  f.error = UI.Text(frame, "GameFontNormalSmall")
  f.error:SetPoint("TOPLEFT", 20, y - 60)
  f.error:SetWidth(WIDTH - 40)
  f.error:SetJustifyH("LEFT")
  f.error:SetTextColor(1, 0.35, 0.35)

  f.save = UI.Button(frame, "Save", 100, save)
  f.save:SetPoint("BOTTOMRIGHT", -16, 14)
  local cancel = UI.Button(frame, "Cancel", 90, function() frame:Hide() end)
  cancel:SetPoint("RIGHT", f.save, "LEFT", -8, 0)

  on(frame, "OnHide", function()
    for _, e in ipairs({ f.name, f.item, f.count, f.text }) do e:ClearFocus() end
  end)
end

-- Opens the editor for an instance's checklist id, or a new checklist when id is nil (or gone).
-- Returns true, or false, "unknown instance".
function Editor.Open(instance, id)
  local entry = type(instance) == "string" and ns.Instances.Get(instance)
  if not entry then return false, "unknown instance" end
  build()
  if ns.Groups.Form and ns.Groups.Form.ListenLinks then ns.Groups.Form.ListenLinks(onLink) end
  local cl = ns.groups and ns.groups.checklist
  local cur = id and cl and cl:Get(id) or nil
  if cur and cur.instance ~= instance then cur = nil end
  f.instance, f.id = instance, cur and cur.id or nil
  f.lines = {}
  for i, l in ipairs(cur and cur.lines or {}) do f.lines[i] = Util.DeepCopy(l) end
  frame.title:SetText((cur and "Edit checklist · " or "New checklist · ") .. entry.name)
  f.name:SetText(cur and cur.name or "")
  setItemLink(nil)
  f.count:SetText("1")
  f.text:SetText("")
  setError(nil)
  render()
  local D = ns.Groups.Details
  if D and D.Can and not D.Can("checklists", instance) then
    setError("You need the checklists permission to edit " .. entry.name .. " checklists.")
    f.save:Disable()
  else
    f.save:Enable()
  end
  frame:ClearAllPoints()
  frame:SetPoint("CENTER")
  frame:Show()
  return true
end

function Editor.IsShown() return frame ~= nil and frame:IsShown() end

function Editor.Hide() if frame then frame:Hide() end end
