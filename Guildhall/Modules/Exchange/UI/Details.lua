local ADDON, ns = ...

-- Exchange board details pane: the selected listing's full text and its action buttons
-- (Whisper/Mail, Copy for Discord, Edit/Renew/Remove, Remove (officer), Remove from my board).
-- Loaded after Board.lua; Board.Build calls Details.Build(view, pane, innerWidth) and
-- Board.Refresh calls Details.Show(rec).
-- Also the "Record a deal" panel (Details.OpenRecordDeal), opened from the details pane.
-- Named global: "GuildhallUIRecordDeal" (UISpecialFrames needs a name for ESC to close it).
-- Global table entries: StaticPopupDialogs.GUILDHALL_REMOVE_LISTING / GUILDHALL_OFFICER_REMOVE.
ns.Exchange = ns.Exchange or {}
local UI = ns.UI
local Util = ns.Util
local Board = ns.Exchange.Board
local H = Board.H
local escape, itemText, isImported, setDot = H.escape, H.itemText, H.isImported, H.setDot
local setStatus, reportError, TAG = H.setStatus, H.reportError, H.TAG
local Details = {}
ns.Exchange.BoardDetails = Details

local DRAFTED = "Saved as a mail draft. Guildhall will offer it next time you open a mailbox."

local view -- the board view this pane belongs to

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function when(t)
  if type(date) == "function" and type(t) == "number" then
    local ok, s = pcall(date, "%Y-%m-%d %H:%M", t)
    if ok then return s end
  end
  return tostring(t)
end

local function detailBody(rec, now)
  local d = rec.d
  local lines = {}
  if d.mats ~= nil then -- nil: the materials question doesn't apply to this item
    lines[#lines + 1] = "I |cffffffff" .. (d.mats and "will" or "will not") .. "|r provide materials"
  end
  lines[#lines + 1] = "I am |cffffffff" .. (d.cod and "open" or "not open") .. "|r to COD"
  if type(d.note) == "string" and d.note ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffc8b98aNote:|r " .. escape(d.note)
  end
  lines[#lines + 1] = ""
  local _, prof = ns.Exchange.Category.Of(d)
  if prof then
    lines[#lines + 1] = "|cffc8b98aProfession:|r " .. escape(ns.Exchange.Category.ProfName(prof))
  end
  -- Listings from before d.created existed fall back to t.
  local posted = type(d.created) == "number" and d.created or rec.t
  lines[#lines + 1] = "|cff8a7d62Posted " .. when(posted) .. "|r"
  if type(rec.t) == "number" and type(posted) == "number" and rec.t - posted >= 60 then
    lines[#lines + 1] = "|cff8a7d62Updated " .. when(rec.t) .. "|r"
  end
  lines[#lines + 1] = "|cff8a7d62Expires " .. when(rec.exp) .. " (" .. Board.TimeLeft(rec.exp, now) .. " left)|r"
  return table.concat(lines, "\n")
end

local function hideButtons()
  for _, b in pairs(view.btn) do b:Hide() end
end

-- Lays out the visible action buttons: row 1 contact + Discord, row 2 owner/officer actions.
local function placeButtons(row1, row2)
  for r, list in ipairs({ row1, row2 }) do
    local x = 10
    local y = r == 1 and 40 or 12
    for _, b in ipairs(list) do
      b:ClearAllPoints()
      b:SetPoint("BOTTOMLEFT", view.detail, "BOTTOMLEFT", x, y)
      b:Show()
      x = x + b:GetWidth() + 6
    end
  end
end

function Details.Show(rec)
  local det, s = view.detail, ns.services
  hideButtons()
  if not rec then
    det.head:SetText("")
    det.who:SetText("")
    det.alts:SetText("")
    det.body:SetText(ns.exchange and "Select a listing to see its details." or "")
    det.dot:Hide(); det.q:Hide()
    if det.iconBtn then det.iconBtn:Hide(); det.iconBtn.item = nil end
    return
  end
  local ex, d, now = ns.exchange, rec.d, s.now()
  local imported = isImported(rec)
  local mine = not imported and s.profile:IsMine(rec.by)
  local status, char = ex:Status(rec)
  det.head:SetText((TAG[d.kind] or escape(d.kind)) .. "  " .. itemText(d))
  if det.iconBtn then
    det.icon:SetTexture(UI.ItemIcon(d.item))
    det.iconBtn.item = d.item
    det.iconBtn:Show()
  end
  local whoName = char or (not imported and rec.char) or nil
  if whoName then
    setDot(det.dot, det.q, status)
    det.who:SetText(escape(ns.Util.DisplayName(whoName)) .. " |cff8a7d62(" .. status .. ")|r")
  else
    -- Imported listing with no in-game character: only the Discord poster is known.
    det.dot:Hide(); det.q:Hide()
    det.who:SetText("")
  end
  if imported then
    det.alts:SetText("Posted on Discord by " .. escape(ns.Util.DisplayName(d.poster or rec.char or "?")))
  else
    local others = {}
    for _, c in ipairs(s.profile:CharsOf(rec.by)) do
      if c ~= whoName then others[#others + 1] = escape(ns.Util.DisplayName(c)) end
    end
    det.alts:SetText(#others > 0 and ("Also: " .. table.concat(others, ", ")) or "")
  end
  det.body:SetText(detailBody(rec, now))

  local b, row1, row2 = view.btn, {}, {}
  if not mine and char then
    b.contact:SetText(status == "offline" and "Mail" or "Whisper")
    row1[#row1 + 1] = b.contact
  end
  row1[#row1 + 1] = b.discord
  if not imported then row1[#row1 + 1] = b.record end
  if imported then
    row2[#row2 + 1] = b.removeImported
  elseif ns.Exchange.Listing.CanEdit(rec, s.profile:Id()) then
    row2[#row2 + 1] = b.edit
    row2[#row2 + 1] = b.renew
    row2[#row2 + 1] = b.remove
  elseif not mine and s.roster:IsOfficer(s.playerChar) == true then
    row2[#row2 + 1] = b.officer
  end
  placeButtons(row1, row2)
end

local function selected()
  return view and view.selectedId and ns.exchange and ns.exchange:Get(view.selectedId) or nil
end

-- Button actions ------------------------------------------------------------------------

local function doContact()
  local rec = selected()
  if not rec then return end
  local res = ns.exchange:Contact(rec)
  if res == "whisper" then
    setStatus("Whisper typed in your chat box. Check it and press Enter to send.")
  elseif res == "mail" then
    setStatus("Send Mail filled in. Check it and press Send.")
  elseif res == "drafted" then
    setStatus(DRAFTED)
  else
    setStatus("There is no character to contact for this listing.", true)
  end
end

local function act(fn, id, okText)
  local ok, err = fn(ns.exchange, id)
  if ok then setStatus(okText) else reportError(err) end
  Board.Refresh()
end

local function confirm(which, rec)
  if not (StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs[which]) then return false end
  StaticPopup_Show(which, escape(Util.ItemName(rec.d.item or "")), nil, rec.id)
  return true
end

function Board.DoRemove(id) act(ns.exchange.Remove, id, "Listing removed.") end
function Board.DoOfficerRemove(id) act(ns.exchange.OfficerRemove, id, "Listing removed (officer).") end

if StaticPopupDialogs then
  StaticPopupDialogs["GUILDHALL_REMOVE_LISTING"] = {
    text = "Remove your listing for %s?",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(_, id) UI.Try(Board.DoRemove, id) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
  StaticPopupDialogs["GUILDHALL_OFFICER_REMOVE"] = {
    text = "Remove this member's listing for %s as an officer? This is logged.",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(_, id) UI.Try(Board.DoOfficerRemove, id) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
end

-- Record a deal -----------------------------------------------------------------------------

local MAX_COUNT, MAX_COPPER = 10000, 10000000000
local rd -- the panel's widgets, built on first use

local RECORD_ERRORS = {
  ["no partner"] = "Choose who you made the deal with.",
  ["partner is you"] = "Choose someone other than yourself.",
  ["bad count"] = "Quantity must be a whole number from 1 to 10000.",
  ["bad amount"] = "Enter the gold paid, for example 40 or 1.5.",
  ["unknown listing"] = "That listing is gone.",
  ["neither of you owns that listing"] = "One of you has to own the listing.",
  ["listing ended"] = "That listing ended too long ago to record a deal on.",
  ["already recorded"] = "That deal was already recorded.",
}

local function profileName(id) return H.nameOfProfile(id) end

-- Pick list entries for the partner: every other guild profile with a live record, by name.
-- Members hidden from the leaderboard are still listed: hiding only affects the boards, and
-- they remain consenting members who can confirm a deal.
function Details.PartnerItems()
  local s = ns.services
  local items, me, now = {}, s.profile:Id(), s.now()
  for _, rec in ipairs(s.profile.set:List(false)) do
    if rec.id ~= me and rec.del ~= true and type(rec.exp) == "number" and rec.exp > now then
      items[#items + 1] = { label = escape(profileName(rec.id)), value = rec.id }
    end
  end
  table.sort(items, function(a, b)
    local la, lb = a.label:lower(), b.label:lower()
    if la ~= lb then return la < lb end
    return a.value < b.value
  end)
  return items
end

-- Whole quantity from a box, or nil.
local function parseCount(text)
  local t = Util.Trim(text or "")
  if not t:match("^%d+$") then return nil end
  local n = tonumber(t)
  if n < 1 or n > MAX_COUNT then return nil end
  return n
end

-- Gold typed as "40", "1.5", "1,5", "40g", "1g 50s", "1g 50s 25c" or "50s" -> whole copper, or nil.
local UNIT_COPPER = { g = 10000, s = 100, c = 1 }
local function parseCopper(text)
  local t = Util.Trim(text or ""):lower()
  local copper
  local plain = t:gsub("^(%d+),(%d+)$", "%1.%2")
  if plain:match("^%d+%.?%d*$") or plain:match("^%.%d+$") then
    copper = math.floor(tonumber(plain) * 10000 + 0.5)
  elseif t:match("^%d+%s*[gsc]") then
    local rest, last, total = t, 0, 0
    while rest ~= "" do
      local n, unit, tail = rest:match("^(%d+)%s*([gsc])%s*(.*)$")
      local order = unit and ({ g = 1, s = 2, c = 3 })[unit]
      if not n or order <= last then return nil end
      last, total, rest = order, total + tonumber(n) * UNIT_COPPER[unit], tail
    end
    copper = total
  end
  if not copper or copper < 1 or copper > MAX_COPPER then return nil end
  return copper
end
Details.ParseCopper = parseCopper

local function rdError(text)
  rd.err:SetText(text or "")
end

local function submitDeal()
  local rec = rd.listing
  if not rec then return end
  if not rd.partner then return rdError(RECORD_ERRORS["no partner"]) end
  local count, copper = parseCount(rd.qty:GetText()), parseCopper(rd.gold:GetText())
  if not count then return rdError(RECORD_ERRORS["bad count"]) end
  if not copper then return rdError(RECORD_ERRORS["bad amount"]) end
  local ok, err = ns.exchange:RecordDeal(rec.id, rd.partner, count, copper)
  if not ok then return rdError(RECORD_ERRORS[err] or ns.Exchange.Form.HandleError(err)) end
  rd.panel:Hide()
  Board.SetStatus("Deal recorded. It counts once " .. escape(profileName(rd.partner)) .. " confirms it.")
  Board.Refresh()
end

local function buildRecordPanel()
  rd = {}
  rd.panel = UI.CreatePanel("GuildhallUIRecordDeal", 360, 250, "Record a deal")
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhallUIRecordDeal") end
  local p = rd.panel
  rd.item = UI.Text(p, "GameFontHighlight")
  rd.item:SetPoint("TOPLEFT", 16, -42)
  rd.item:SetWidth(328)
  local function label(text, y)
    local l = UI.Text(p, "GameFontNormalSmall", text)
    l:SetPoint("TOPLEFT", 16, y)
  end
  label("Who was the deal with?", -68)
  rd.partnerBtn = UI.Button(p, "Choose a player", 200, function()
    UI.PickList(rd.partnerBtn, Details.PartnerItems(), function(id, item)
      rd.partner = id
      rd.partnerBtn:SetText(item.label)
    end, rd.partner)
  end)
  rd.partnerBtn:SetPoint("TOPLEFT", 16, -86)
  rd.partnerName = UI.Text(p, "GameFontHighlight")
  rd.partnerName:SetPoint("TOPLEFT", 20, -90)
  label("Quantity", -120)
  rd.qty = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
  rd.qty:SetSize(80, 20)
  rd.qty:SetAutoFocus(false)
  rd.qty:SetMaxLetters(5)
  rd.qty:SetPoint("TOPLEFT", 22, -138)
  label("Gold paid", -120)
  rd.gold = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
  rd.gold:SetSize(100, 20)
  rd.gold:SetAutoFocus(false)
  rd.gold:SetMaxLetters(12)
  rd.gold:SetPoint("TOPLEFT", 150, -138)
  rd.err = UI.Text(p, "GameFontNormalSmall", "")
  rd.err:SetTextColor(1, 0.35, 0.35)
  rd.err:SetPoint("TOPLEFT", 16, -170)
  rd.err:SetWidth(328)
  rd.submit = UI.Button(p, "Record", 100, function() submitDeal() end)
  rd.submit:SetPoint("BOTTOMLEFT", 16, 14)
  rd.cancel = UI.Button(p, "Cancel", 100, function() p:Hide() end)
  rd.cancel:SetPoint("LEFT", rd.submit, "RIGHT", 8, 0)
  for _, box in ipairs({ rd.qty, rd.gold }) do
    on(box, "OnEnterPressed", function(self) self:ClearFocus() end)
    on(box, "OnEscapePressed", function(self) self:ClearFocus() end)
  end
end

-- Opens the panel for a listing. On someone else's listing the partner is its owner; on mine
-- you choose who you dealt with.
function Details.OpenRecordDeal(rec)
  if not rd then buildRecordPanel() end
  local s = ns.services
  rd.listing = rec
  rd.partner = nil
  rd.item:SetText((TAG[rec.d.kind] or escape(rec.d.kind)) .. "  " .. itemText(rec.d))
  rd.qty:SetText(tostring(rec.d.qty or 1))
  rd.gold:SetText("")
  rdError("")
  if s.profile:IsMine(rec.by) then
    rd.partnerBtn:SetText("Choose a player")
    rd.partnerBtn:Show()
    rd.partnerName:Hide()
  else
    rd.partner = rec.by
    rd.partnerBtn:Hide()
    rd.partnerName:SetText(escape(profileName(rec.by)))
    rd.partnerName:Show()
  end
  rd.panel:Show()
end

local function buildButtons(det)
  local b = {}
  b.contact = UI.Button(det, "Whisper", 110, doContact)
  b.discord = UI.Button(det, "Copy for Discord", 130, function()
    local rec = selected()
    if rec then UI.CopyBox:Show("Copy for Discord", ns.exchange:DiscordText(rec.id)) end
  end)
  b.record = UI.Button(det, "Record a deal", 120, function()
    local rec = selected()
    if rec then Details.OpenRecordDeal(rec) end
  end)
  b.edit = UI.Button(det, "Edit", 90, function()
    local rec = selected()
    if rec then ns.Exchange.Form.Open(rec) end
  end)
  b.renew = UI.Button(det, "Renew", 90, function()
    local rec = selected()
    if rec then act(ns.exchange.Renew, rec.id, "Listing renewed for another 7 days.") end
  end)
  b.remove = UI.Button(det, "Remove", 90, function()
    local rec = selected()
    if rec and not confirm("GUILDHALL_REMOVE_LISTING", rec) then Board.DoRemove(rec.id) end
  end)
  b.officer = UI.Button(det, "Remove (officer)", 140, function()
    local rec = selected()
    if rec and not confirm("GUILDHALL_OFFICER_REMOVE", rec) then Board.DoOfficerRemove(rec.id) end
  end)
  b.removeImported = UI.Button(det, "Remove from my board", 170, function()
    local rec = selected()
    if not rec then return end
    ns.exchange:RemoveImported(rec.id)
    setStatus("Removed from your board.")
    Board.Refresh()
  end)
  return b
end

function Details.Build(boardView, det, inner)
  view = boardView
  -- Item icon (hover: standard item tooltip); the header lines sit to its right.
  det.iconBtn = CreateFrame("Button", nil, det)
  det.iconBtn:SetSize(40, 40)
  det.iconBtn:SetPoint("TOPLEFT", 12, -12)
  det.icon = det.iconBtn:CreateTexture(nil, "ARTWORK")
  det.icon:SetAllPoints(det.iconBtn)
  det.iconBtn:SetScript("OnEnter", function(self) UI.Try(UI.ItemTooltip, self, self.item) end)
  det.iconBtn:SetScript("OnLeave", function() UI.Try(function() if GameTooltip then GameTooltip:Hide() end end) end)
  det.iconBtn:Hide()
  local x = 62
  det.head = UI.Text(det, "GameFontNormalLarge")
  det.head:SetPoint("TOPLEFT", x, -12)
  det.head:SetWidth(inner - (x - 12))
  det.dot = det:CreateTexture(nil, "ARTWORK")
  det.dot:SetSize(8, 8)
  det.dot:SetPoint("TOPLEFT", x + 2, -42)
  det.q = UI.Text(det, "GameFontDisableSmall", "?")
  det.q:SetPoint("TOPLEFT", x + 2, -40)
  det.who = UI.Text(det, "GameFontHighlight")
  det.who:SetPoint("TOPLEFT", x + 16, -38)
  det.who:SetWidth(inner - (x - 12) - 16)
  det.alts = UI.Text(det, "GameFontHighlightSmall")
  det.alts:SetPoint("TOPLEFT", x, -58)
  det.alts:SetWidth(inner - (x - 12))
  det.body = UI.Text(det, "GameFontHighlight")
  det.body:SetPoint("TOPLEFT", 12, -84)
  det.body:SetWidth(inner)
  det.body:SetJustifyV("TOP")
  det.body:SetSpacing(3)
  view.btn = buildButtons(det)
end
