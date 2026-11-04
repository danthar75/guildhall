local ADDON, ns = ...

-- New / edit listing form. Form.Open(existingRec?) shows it; Post or Save calls the
-- Exchange module and reports errors inline. Never sends anything itself.
-- Named global: "GuildhallUIExchangeForm" (UISpecialFrames needs a name for ESC to close it).
-- Item input: shift-click (post-hook on ChatFrameUtil.InsertLink, Classic: ChatEdit_InsertLink),
-- drag and drop onto the slot, or a typed name. Only the link (or the typed name) goes into d.item.
ns.Exchange = ns.Exchange or {}
local UI = ns.UI
local Util = ns.Util
local Form = {}
ns.Exchange.Form = Form

local WIDTH, HEIGHT = 400, 420
local NOTE_MAX = 200
local EMPTY_ICON = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local frame, hooked
local f = {} -- widgets

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

-- Friendly text for an Exchange error code. Shared with the Board.
local ERRORS = {
  trial = "Trial accounts can browse but can't post (Blizzard blocks addon messages for trial accounts).",
  consent = "Choose which characters to link first.",
  excluded = "This character isn't linked to your profile. Posting from it would reveal the link. Link it in Settings or post from a linked character.",
  ["not owner"] = "That listing isn't yours to change.",
  ["not officer"] = "Only officers can remove other members' listings.",
  expired = "That listing has already expired.",
  stale = "A newer version of that listing already exists. Refresh and try again.",
  future = "The listing was rejected because its time is in the future. Check your clock.",
  invalid = "The listing was rejected as invalid.",
  ["bad kind"] = "Choose Buying (LF) or Selling (WTS).",
  ["bad item"] = "Choose an item (shift-click or drag one in) or type its name.",
  ["bad qty"] = "Quantity must be a whole number from 1 to 9999.",
  ["bad note"] = "The note is too long (200 bytes; accented letters take 2).",
  ["bad mats"] = "Choose whether you will provide materials.",
  ["bad cod"] = "Choose whether you are open to COD.",
}

function Form.ErrorText(err)
  return ERRORS[err] or ("Couldn't save: " .. tostring(err) .. ".")
end

-- Shows the consent dialog when posting is blocked on it.
function Form.HandleError(err)
  if err == "consent" and ns.Boot and ns.Boot.ShowConsent then ns.Boot.ShowConsent() end
  return Form.ErrorText(err)
end

-- Item helpers -----------------------------------------------------------------

local function itemIcon(id)
  if not id then return nil end
  if C_Item and C_Item.GetItemIconByID then
    local ok, icon = pcall(C_Item.GetItemIconByID, id)
    if ok and icon then return icon end
  end
  if GetItemIcon then
    local ok, icon = pcall(GetItemIcon, id)
    if ok and icon then return icon end
  end
  return nil
end

-- Item link for an id, when the client has it cached.
local function linkForId(id)
  if not id then return nil end
  local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not getInfo then return nil end
  local ok, _, link = pcall(getInfo, id)
  if ok and Util.IsItemLink(link) then return link end
  return nil
end

-- A recipe link (profession list) -> the crafted item's link, or nil.
local function recipeOutputLink(link)
  local spellId = link:match("|Henchant:(%d+)") or link:match("|Hspell:(%d+)")
  spellId = tonumber(spellId)
  if not spellId then return nil end
  local api = C_TradeSkillUI and C_TradeSkillUI.GetRecipeOutputItemData
  if not api then return nil end
  local ok, info = pcall(api, spellId)
  if not ok or type(info) ~= "table" then return nil end
  if Util.IsItemLink(info.hyperlink) then return info.hyperlink end
  return linkForId(info.itemID)
end

-- Form state ---------------------------------------------------------------------

local function setError(text)
  f.error:SetText(text or "")
end

local function setKind(kind)
  f.kind = kind
  f.lf:SetChecked(kind == "LF")
  f.wts:SetChecked(kind == "WTS")
end

local function showSlot()
  local link = f.link
  if link then
    f.icon:SetTexture(itemIcon(Util.ItemIdFromLink(link)) or UNKNOWN_ICON)
    f.itemText:SetText(link) -- the link is already in its quality color
  else
    f.icon:SetTexture(EMPTY_ICON)
    f.itemText:SetText("|cff888888No item chosen|r")
  end
end

-- While an item is loaded the Name box shows its name and is locked; X unlocks it.
local function lockName(locked)
  if locked then
    f.name:ClearFocus()
    f.name:Disable()
    f.name:SetTextColor(0.6, 0.6, 0.6)
  else
    f.name:Enable()
    f.name:SetTextColor(1, 1, 1)
  end
end

-- Profession picker ----------------------------------------------------------------

local function profLabel(key)
  return key and ns.Exchange.Category.ProfName(key) or "None"
end

-- Shows only the optional fields that make sense for the current item (Category.Applies) and
-- stacks the rows below them so hidden ones leave no gap.
local function currentItem() return f.link or Util.Trim(f.name:GetText() or "") end

local function fieldsApply()
  local ok, m, p = pcall(ns.Exchange.Category.Applies, { item = currentItem(), prof = f.prof })
  if not ok then return true, true end
  return m, p
end

local function relayout()
  if not f.error then return end -- still building
  local matsOn, profOn = fieldsApply()
  f.matsOn, f.profOn = matsOn, profOn
  local y = -182
  if matsOn then
    f.mats:ClearAllPoints(); f.mats:SetPoint("TOPLEFT", 16, y); f.mats:Show()
    y = y - 26
  else
    f.mats:Hide()
  end
  f.cod:ClearAllPoints(); f.cod:SetPoint("TOPLEFT", 16, y)
  y = y - 34
  if profOn then
    f.profLabelText:ClearAllPoints(); f.profLabelText:SetPoint("TOPLEFT", 20, y - 4)
    f.profBtn:ClearAllPoints(); f.profBtn:SetPoint("TOPLEFT", 92, y)
    f.profLabelText:Show(); f.profBtn:Show(); f.profHint:Show()
    y = y - 36
  else
    f.profLabelText:Hide(); f.profBtn:Hide(); f.profHint:Hide()
  end
  f.noteLabel:ClearAllPoints(); f.noteLabel:SetPoint("TOPLEFT", 20, y)
  f.count:ClearAllPoints(); f.count:SetPoint("TOPRIGHT", -20, y - 2)
  f.note:ClearAllPoints(); f.note:SetPoint("TOPLEFT", 24, y - 18)
  f.error:ClearAllPoints(); f.error:SetPoint("TOPLEFT", 20, y - 48)
end

-- fromUser marks a hand-made choice, which auto-fill then leaves alone for the same item.
local function setProf(key, fromUser)
  f.prof = key
  if f.profBtn then f.profBtn:SetText(profLabel(key)) end
  if fromUser then f.profManualFor = f.link or Util.Trim(f.name:GetText() or "") end
  relayout()
end

local function openProfPicker()
  local items = { { label = "None", value = false } }
  for _, p in ipairs(ns.Exchange.Category.PROFS) do
    items[#items + 1] = { label = ns.Exchange.Category.ProfName(p.key), value = p.key }
  end
  -- A key outside the canonical set (set by a newer client) stays selectable.
  if f.prof and not ns.Exchange.Category.PROFS_BY_KEY[f.prof] then
    items[#items + 1] = { label = profLabel(f.prof), value = f.prof }
  end
  UI.PickList(f.profBtn, items, function(v) setProf(v or nil, true) end, f.prof or false)
end

-- Open profession window first, then what the item type implies, else keep the choice.
local function autoFillProf(link)
  if f.profManualFor ~= nil and f.profManualFor == link then return end
  local C = ns.Exchange.Category
  local key = C.WindowProf() or C.ImpliedProf(link)
  if key then setProf(key) end
end

function Form.SetLink(link)
  if f.link ~= link then f.profManualFor = nil end
  f.link = link
  f.settingName = true
  f.name:SetText(Util.ItemName(link))
  f.settingName = nil
  lockName(true)
  showSlot()
  setError(nil)
  UI.Try(autoFillProf, link)
  relayout()
end

local function setTypedName(name)
  f.link = nil
  f.settingName = true
  f.name:SetText(name or "")
  f.settingName = nil
  lockName(false)
  showSlot()
  relayout()
end

-- Loads any link: item links directly, recipe links via the crafted item, else the plain name.
function Form.LoadLink(link)
  if type(link) ~= "string" or link == "" then return end
  if Util.IsItemLink(link) then Form.SetLink(link); return end
  local out = link:find("|H", 1, true) and recipeOutputLink(link)
  if out then Form.SetLink(out); return end
  local name = Util.ItemName(link)
  name = name:match("^%a[%a ]*: (.+)$") or name -- "Tailoring: Bolt of Silk" -> "Bolt of Silk"
  setTypedName(name)
end

local function takeCursorItem()
  if not GetCursorInfo then return end
  local kind, id, link = GetCursorInfo()
  if kind ~= "item" then return end
  link = Util.IsItemLink(link) and link or linkForId(id)
  if link then Form.SetLink(link) end
  if ClearCursor then ClearCursor() end
end

-- Runs inside Blizzard's InsertLink call, so nothing may escape: the whole body runs under
-- UI.Try and every argument goes through Compat:Safe (a secret string can't be searched).
local function scanInsertLink(...)
  if not (frame and frame:IsShown()) then return end
  local compat = ns.compat
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if compat then v = compat:Safe(v) end
    if type(v) == "string" and v:find("|H", 1, true) then
      Form.LoadLink(v)
      f.linkAt = GetTime and GetTime() or nil
      return
    end
  end
end

local function onInsertLink(...)
  UI.Try(scanInsertLink, ...)
end

-- Post-hook only (never replaced), installed once. The link still also reaches an open chat box.
-- With no chat box open, shift-clicking a bag stack also opens Blizzard's stack-split popup
-- (InsertLink returned false). When that click just loaded an item into the form, close it.
local splitHooked = false
local function onSplitShow(self)
  if not (frame and frame:IsShown() and f.linkAt and GetTime) then return end
  if GetTime() == f.linkAt then self:Hide() end
end

local function installHook()
  if not splitHooked and StackSplitFrame and StackSplitFrame.HookScript then
    StackSplitFrame:HookScript("OnShow", function(self) UI.Try(onSplitShow, self) end)
    splitHooked = true
  end
  if hooked or not hooksecurefunc then return end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink)
    hooked = true
  elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", onInsertLink)
    hooked = true
  end
end

local function payload()
  local item = f.link or Util.Trim(f.name:GetText() or "")
  local qty = tonumber(f.qty:GetText() or "")
  local note = Util.Trim(f.note:GetText() or "")
  return {
    kind = f.kind,
    item = item,
    qty = qty,
    -- nil when the field doesn't apply to this item (hidden on the form).
    mats = f.matsOn ~= false and (f.mats:GetChecked() and true or false) or nil,
    cod = f.cod:GetChecked() and true or false,
    note = note ~= "" and note or nil,
    prof = f.profOn ~= false and f.prof or nil,
  }
end

local function submit()
  local ex = ns.exchange
  if not ex then setError("Guildhall isn't ready yet. Try again in a moment."); return end
  local d = payload()
  local ok, res
  if f.editing then
    ok, res = ex:Edit(f.editing, {
      kind = d.kind, item = d.item, qty = d.qty or false, cod = d.cod,
      mats = d.mats == nil and ns.Exchange.Listing.CLEAR or d.mats,
      note = d.note or false, prof = d.prof or false,
    })
  else
    ok, res = ex:Post(d)
  end
  if not ok then setError(Form.HandleError(res)); return end
  local wasEditing = f.editing ~= nil
  frame:Hide()
  local Board = ns.Exchange.Board
  if Board and Board.OnSaved then Board.OnSaved(res, wasEditing) end
end

-- Build ----------------------------------------------------------------------------

local function check(parent, label, x, y)
  local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  c:SetSize(24, 24)
  c:SetPoint("TOPLEFT", x, y)
  local t = UI.Text(c, "GameFontHighlight", label) -- child of the box, so it hides with it
  t:SetPoint("LEFT", c, "RIGHT", 4, 0)
  return c
end

local function radio(parent, label, x, y, kind)
  local r = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
  r:SetSize(16, 16)
  r:SetPoint("TOPLEFT", x, y)
  local t = UI.Text(parent, "GameFontHighlight", label)
  t:SetPoint("LEFT", r, "RIGHT", 6, 0)
  on(r, "OnClick", function() setKind(kind) end)
  return r
end

local function input(parent, width)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  on(e, "OnEscapePressed", function(self) self:ClearFocus() end)
  on(e, "OnEnterPressed", function(self) self:ClearFocus() end)
  return e
end

local function build()
  if frame then return end
  frame = UI.CreatePanel("GuildhallUIExchangeForm", WIDTH, HEIGHT, "New listing")
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhallUIExchangeForm") end

  -- Kind
  f.lf = radio(frame, "Buying (LF)", 20, -46, "LF")
  f.wts = radio(frame, "Selling (WTS)", 180, -46, "WTS")

  -- Item slot: icon button, name in quality color, Clear (X), typed-name fallback.
  f.slot = CreateFrame("Button", nil, frame)
  f.slot:SetSize(40, 40)
  f.slot:SetPoint("TOPLEFT", 16, -74)
  f.slot:RegisterForClicks("LeftButtonUp")
  f.icon = f.slot:CreateTexture(nil, "ARTWORK")
  f.icon:SetAllPoints(f.slot)
  local hl = f.slot:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(f.slot)
  hl:SetColorTexture(1, 1, 1, 0.15)
  on(f.slot, "OnReceiveDrag", takeCursorItem)
  on(f.slot, "OnClick", takeCursorItem)
  on(f.slot, "OnEnter", function(self)
    if not (f.link and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(f.link)
    GameTooltip:Show()
  end)
  on(f.slot, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

  f.itemText = UI.Text(frame, "GameFontHighlight")
  f.itemText:SetPoint("TOPLEFT", 64, -78)
  f.itemText:SetWidth(280)
  if f.itemText.SetWordWrap then f.itemText:SetWordWrap(false) end

  f.clear = UI.Button(frame, "X", 24, function() setTypedName("") end)
  f.clear:SetPoint("TOPRIGHT", -16, -74)

  local hint = UI.Text(frame, "GameFontDisableSmall", "Shift-click or drag an item here, or type a name below.")
  hint:SetPoint("TOPLEFT", 64, -98)
  hint:SetWidth(320)

  local nameLabel = UI.Text(frame, "GameFontNormal", "Name:")
  nameLabel:SetPoint("TOPLEFT", 20, -128)
  f.name = input(frame, 280)
  f.name:SetMaxBytes(256) -- 255 bytes + terminator: Validate counts bytes, not letters
  f.name:SetPoint("TOPLEFT", 92, -124)
  on(f.name, "OnTextChanged", function(self, userInput)
    if f.settingName or not userInput then return end
    if f.link then f.link = nil; showSlot() end
  end)

  local qtyLabel = UI.Text(frame, "GameFontNormal", "Quantity:")
  qtyLabel:SetPoint("TOPLEFT", 20, -158)
  f.qty = input(frame, 60)
  f.qty:SetNumeric(true)
  f.qty:SetMaxLetters(4)
  f.qty:SetPoint("TOPLEFT", 92, -154)
  local qtyHint = UI.Text(frame, "GameFontDisableSmall", "optional")
  qtyHint:SetPoint("LEFT", f.qty, "RIGHT", 8, 0)

  f.mats = check(frame, "I will provide materials", 16, -182)
  f.cod = check(frame, "I am open to COD", 16, -208)

  f.profLabelText = UI.Text(frame, "GameFontNormal", "Profession:")
  f.profLabelText:SetPoint("TOPLEFT", 20, -242)
  f.profBtn = UI.Button(frame, "None", 160, openProfPicker)
  f.profBtn:SetPoint("TOPLEFT", 92, -238)
  f.profHint = UI.Text(frame, "GameFontDisableSmall", "optional")
  f.profHint:SetPoint("LEFT", f.profBtn, "RIGHT", 8, 0)

  f.noteLabel = UI.Text(frame, "GameFontNormal", "Note (optional):")
  f.noteLabel:SetPoint("TOPLEFT", 20, -274)
  f.count = UI.Text(frame, "GameFontDisableSmall")
  f.count:SetPoint("TOPRIGHT", -20, -276)
  f.note = input(frame, 356)
  f.note:SetMaxBytes(NOTE_MAX + 1) -- bytes + terminator, matching Validate and the counter
  f.note:SetPoint("TOPLEFT", 24, -292)
  on(f.note, "OnTextChanged", function(self)
    f.count:SetText(string.format("%d/%d", #(self:GetText() or ""), NOTE_MAX))
  end)

  f.error = UI.Text(frame, "GameFontNormalSmall")
  f.error:SetPoint("TOPLEFT", 20, -322)
  f.error:SetWidth(360)
  f.error:SetTextColor(1, 0.35, 0.35)

  f.submit = UI.Button(frame, "Post", 100, submit)
  f.submit:SetPoint("BOTTOMRIGHT", -16, 14)
  local cancel = UI.Button(frame, "Cancel", 90, function() frame:Hide() end)
  cancel:SetPoint("RIGHT", f.submit, "LEFT", -8, 0)

  on(frame, "OnHide", function()
    if UI.ClosePickList then UI.ClosePickList() end
    for _, e in ipairs({ f.name, f.qty, f.note }) do e:ClearFocus() end
  end)
end

-- Opens the form. With a record, edits it (Save); otherwise starts a new listing (Post).
-- defaultKind ("LF"/"WTS") preselects the type of a new listing.
function Form.Open(rec, defaultKind)
  build()
  installHook()
  local d = type(rec) == "table" and type(rec.d) == "table" and rec.d or nil
  f.editing = d and rec.id or nil
  frame.title:SetText(d and "Edit listing" or "New listing")
  f.submit:SetText(d and "Save" or "Post")
  setKind(d and d.kind or defaultKind or "LF")
  f.prof, f.profManualFor = nil, nil
  if d and Util.IsItemLink(d.item) then
    Form.SetLink(d.item)
  else
    setTypedName(d and d.item or "")
  end
  setProf(d and d.prof or nil) -- after SetLink: an edited listing shows its own choice
  f.qty:SetText(d and d.qty and tostring(d.qty) or "")
  f.mats:SetChecked(d and d.mats == true or false)
  f.cod:SetChecked(d and d.cod == true or false)
  f.note:SetText(d and d.note or "")
  f.count:SetText(string.format("%d/%d", #(f.note:GetText() or ""), NOTE_MAX))
  setError(nil)
  relayout()
  frame:ClearAllPoints()
  frame:SetPoint("CENTER")
  frame:Show()
end

function Form.IsShown() return frame ~= nil and frame:IsShown() end

function Form.Hide() if frame then frame:Hide() end end
