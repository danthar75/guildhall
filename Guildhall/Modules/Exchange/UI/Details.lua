local ADDON, ns = ...

-- Exchange board details pane: the selected listing's full text and its action buttons
-- (Whisper/Mail, Copy for Discord, Edit/Renew/Remove, Remove (officer), Remove from my board).
-- Loaded after Board.lua; Board.Build calls Details.Build(view, pane, innerWidth) and
-- Board.Refresh calls Details.Show(rec).
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

local function when(t)
  if type(date) == "function" and type(t) == "number" then
    local ok, s = pcall(date, "%Y-%m-%d %H:%M", t)
    if ok then return s end
  end
  return tostring(t)
end

local function detailBody(rec, now)
  local d = rec.d
  local lines = {
    "I |cffffffff" .. (d.mats and "will" or "will not") .. "|r provide materials",
    "I am |cffffffff" .. (d.cod and "open" or "not open") .. "|r to COD",
  }
  if type(d.note) == "string" and d.note ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffc8b98aNote:|r " .. escape(d.note)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "|cff8a7d62Posted " .. when(rec.t) .. "|r"
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
    return
  end
  local ex, d, now = ns.exchange, rec.d, s.now()
  local imported = isImported(rec)
  local mine = not imported and s.profile:IsMine(rec.by)
  local status, char = ex:Status(rec)
  det.head:SetText((TAG[d.kind] or escape(d.kind)) .. "  " .. itemText(d))
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

local function buildButtons(det)
  local b = {}
  b.contact = UI.Button(det, "Whisper", 110, doContact)
  b.discord = UI.Button(det, "Copy for Discord", 130, function()
    local rec = selected()
    if rec then UI.CopyBox:Show("Copy for Discord", ns.exchange:DiscordText(rec.id)) end
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
  det.head = UI.Text(det, "GameFontNormalLarge")
  det.head:SetPoint("TOPLEFT", 12, -12)
  det.head:SetWidth(inner)
  det.dot = det:CreateTexture(nil, "ARTWORK")
  det.dot:SetSize(8, 8)
  det.dot:SetPoint("TOPLEFT", 14, -42)
  det.q = UI.Text(det, "GameFontDisableSmall", "?")
  det.q:SetPoint("TOPLEFT", 14, -40)
  det.who = UI.Text(det, "GameFontHighlight")
  det.who:SetPoint("TOPLEFT", 28, -38)
  det.who:SetWidth(inner - 16)
  det.alts = UI.Text(det, "GameFontHighlightSmall")
  det.alts:SetPoint("TOPLEFT", 12, -58)
  det.alts:SetWidth(inner)
  det.body = UI.Text(det, "GameFontHighlight")
  det.body:SetPoint("TOPLEFT", 12, -84)
  det.body:SetWidth(inner)
  det.body:SetJustifyV("TOP")
  det.body:SetSpacing(3)
  view.btn = buildButtons(det)
end
