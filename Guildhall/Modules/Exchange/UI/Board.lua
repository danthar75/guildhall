local ADDON, ns = ...

-- Exchange board (layout B): sub-tabs and a search box over a pooled, scrolling listing
-- list on the left; the selected listing's details and action buttons on the right.
-- Board.Build(parent) -> view {refresh}; Board.Refresh() re-reads ns.exchange:List(filter).
-- Named global: "GuildhallUIExchangeListScroll" (FauxScrollFrameTemplate needs a name).
-- Global table entries: StaticPopupDialogs.GUILDHALL_REMOVE_LISTING / GUILDHALL_OFFICER_REMOVE.
ns.Exchange = ns.Exchange or {}
local UI = ns.UI
local Util = ns.Util
local Board = ns.Exchange.Board or {}
ns.Exchange.Board = Board

local LIST_W, DETAIL_X = 340, 350
local TOP = 30         -- below the sub-tab row
local LIST_TOP = 56    -- below the search box
local BOTTOM = 20      -- status line
local ROW_H, ROWS = 34, 10

local FILTERS = {
  { key = "all", title = "All", width = 60 },
  { key = "LF", title = "Buying (LF)", width = 96 },
  { key = "WTS", title = "Selling", width = 76 },
  { key = "mine", title = "Mine", width = 60 },
}

local TAG = { LF = "|cff7fc8ffLF|r", WTS = "|cffffb84dWTS|r" }

local view -- the single built board
local Details -- ns.Exchange.BoardDetails, resolved at Build (UI/Details.lua loads after this file)

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local escape = Util.Escape
local function bare(name) return type(name) == "string" and ns.Util.DisplayName(name) or nil end

local function services() return ns.services end

-- Display helpers -------------------------------------------------------------------

local function isImported(rec) return ns.exchange:_isImported(rec) end

local function itemText(d)
  local item = d.item
  local s = Util.IsItemLink(item) and item or escape(item)
  if d.qty then s = s .. " x" .. d.qty end
  return s
end

local function posterOf(rec)
  if isImported(rec) then return rec.d.poster or rec.char end
  return rec.char
end

function Board.TimeLeft(exp, now)
  local left = (exp or 0) - (now or 0)
  if left >= 86400 then return math.floor(left / 86400) .. "d" end
  if left >= 3600 then return math.floor(left / 3600) .. "h" end
  return "<1h"
end

local function setDot(dot, q, status)
  if status == "unknown" then
    dot:Hide(); q:Show()
  else
    if status == "online" then dot:SetColorTexture(0.25, 0.82, 0.25) else dot:SetColorTexture(0.4, 0.4, 0.4) end
    dot:Show(); q:Hide()
  end
end

local function setStatus(text, isError)
  if not view then return end
  view.status:SetText(text or "")
  if isError then view.status:SetTextColor(1, 0.35, 0.35) else view.status:SetTextColor(0.8, 0.8, 0.8) end
end
Board.SetStatus = setStatus

local function reportError(err)
  setStatus(ns.Exchange.Form.HandleError(err), true)
end

-- Shared with UI/Details.lua.
Board.H = {
  escape = escape, itemText = itemText, isImported = isImported, setDot = setDot,
  setStatus = setStatus, reportError = reportError, TAG = TAG,
}

-- Data ---------------------------------------------------------------------------------

-- Member filter key: the poster's profile, or the Discord poster's name for imported
-- listings (they have no profile).
function Board.MemberKey(rec)
  local d = rec.d
  if type(d) == "table" and d.src == "discord" then return "discord:" .. tostring(d.poster or rec.char or "?") end
  return rec.by
end

local function textMatches(rec, needle)
  if needle == "" then return true end
  local d = rec.d
  for _, v in ipairs({ Util.ItemName(d.item or ""), rec.char, d.poster }) do
    if type(v) == "string" and string.find(string.lower(v), needle, 1, true) then return true end
  end
  return false
end

-- filters: { needle = lowercase search text, cat = "all"|"crafted"|"prof:<key>"|<category>,
-- member = Board.MemberKey value or nil }. All conditions must hold.
function Board.Matches(rec, filters)
  if type(rec) ~= "table" or type(rec.d) ~= "table" then return false end
  local f = filters or {}
  if f.member ~= nil and Board.MemberKey(rec) ~= f.member then return false end
  local cat = f.cat
  if cat ~= nil and cat ~= "all" then
    local c, prof = ns.Exchange.Category.Of(rec.d)
    local want = cat:match("^prof:(.+)$")
    if want then
      if c ~= "crafted" or prof ~= want then return false end
    elseif c ~= cat then
      return false
    end
  end
  return textMatches(rec, f.needle or "")
end

-- Popup entries for the Category button, from the current listings: only professions that
-- appear on a Crafted listing are offered.
function Board.CategoryItems(recs)
  local C = ns.Exchange.Category
  local seen = {}
  for _, rec in ipairs(recs) do
    local c, prof = C.Of(rec.d)
    if c == "crafted" and prof then seen[prof] = true end
  end
  local items = { { label = "All", value = "all" } }
  for _, cat in ipairs(C.CATS) do
    items[#items + 1] = { label = cat.label, value = cat.key, short = cat.short }
    if cat.key == "crafted" then
      local keys = {}
      for _, p in ipairs(C.PROFS) do
        if seen[p.key] then keys[#keys + 1] = p.key; seen[p.key] = nil end
      end
      local extra = {}
      for k in pairs(seen) do extra[#extra + 1] = k end
      table.sort(extra)
      for _, k in ipairs(extra) do keys[#keys + 1] = k end
      for _, k in ipairs(keys) do
        items[#items + 1] = { label = C.ProfName(k), value = "prof:" .. k, indent = 14 }
      end
    end
  end
  return items
end

-- Popup entries for the Member button: one per profile (or Discord poster) among recs,
-- sorted by name. labelOf(rec) names the member from that member's newest listing.
function Board.MemberItems(recs, labelOf)
  local newest = {}
  for _, rec in ipairs(recs) do
    local k = Board.MemberKey(rec)
    if k ~= nil then
      local cur = newest[k]
      if not cur or (rec.t or 0) > (cur.t or 0) then newest[k] = rec end
    end
  end
  local items = {}
  for k, rec in pairs(newest) do
    local label
    if type(rec.d) == "table" and rec.d.src == "discord" then
      label = tostring(rec.d.poster or rec.char or "?") .. " (Discord)"
    else
      label = labelOf(rec)
    end
    items[#items + 1] = { label = tostring(label or "?"), value = k }
  end
  table.sort(items, function(a, b)
    local la, lb = a.label:lower(), b.label:lower()
    if la ~= lb then return la < lb end
    return tostring(a.value) < tostring(b.value)
  end)
  table.insert(items, 1, { label = "Anyone", value = false })
  return items
end

local function memberLabel(rec)
  local status, char = ns.exchange:Status(rec)
  return escape(ns.Util.DisplayName((status == "online" and char) or rec.char or "?"))
end

-- Every listing regardless of tab: the filter popups offer choices from these.
local function allRecs()
  local out = {}
  if not ns.exchange then return out end
  for _, rec in ipairs(ns.exchange:List("all")) do
    if type(rec.d) == "table" then out[#out + 1] = rec end
  end
  return out
end

-- True when anything narrows the board: a tab other than All, search text, a category or a member.
function Board.IsFiltered(s)
  return s.tab ~= "all" or (s.needle or ""):match("%S") ~= nil or s.cat ~= "all" or s.member ~= nil
end

local function updateFilterButtons()
  if not view.catBtn then return end
  if view.resetBtn then
    local on = Board.IsFiltered({ tab = view.filter, needle = view.search:GetText(), cat = view.cat, member = view.member })
    if on then view.resetBtn:Show() else view.resetBtn:Hide() end
  end
  local label = "All"
  for _, it in ipairs(Board.CategoryItems(view.all or {})) do
    if it.value == view.cat then label = it.short or it.label end
  end
  if view.cat ~= "all" and label == "All" then -- chosen profession no longer on any listing
    local k = tostring(view.cat):match("^prof:(.+)$")
    label = k and ns.Exchange.Category.ProfName(k) or tostring(view.cat)
  end
  view.catBtn:SetText("Category: " .. label)
  view.memberBtn:SetText("Member: " .. (view.member and view.memberText or "Anyone"))
end

local function load()
  local out = {}
  if not ns.exchange then return out end
  view.all = allRecs()
  if view.member ~= nil then
    local present = false
    for _, rec in ipairs(view.all) do
      if Board.MemberKey(rec) == view.member then present = true; break end
    end
    if not present then view.member, view.memberText = nil, nil end
  end
  updateFilterButtons()
  local f = {
    needle = string.lower(Util.Trim(view.search:GetText() or "")),
    cat = view.cat, member = view.member,
  }
  for _, rec in ipairs(ns.exchange:List(view.filter)) do
    if Board.Matches(rec, f) then out[#out + 1] = rec end
  end
  return out
end

-- List ----------------------------------------------------------------------------------

local function offset()
  if view.faux then return FauxScrollFrame_GetOffset(view.scroll) end
  return view.offset or 0
end

local function updateRows()
  local list, now = view.list, services() and services().now() or 0
  if view.faux then
    FauxScrollFrame_Update(view.scroll, #list, ROWS, ROW_H)
  else
    view.offset = math.max(0, math.min(view.offset or 0, #list - ROWS))
  end
  local off = offset()
  for i, row in ipairs(view.rows) do
    local rec = list[off + i]
    row.rec = rec
    if rec then
      local d = rec.d
      row.icon:SetTexture(UI.ItemIcon(d.item))
      row.tag:SetText(TAG[d.kind] or escape(d.kind))
      row.item:SetText(itemText(d))
      local status = ns.exchange:Status(rec)
      setDot(row.dot, row.q, status)
      row.sub:SetText(escape(bare(posterOf(rec)) or "?") .. " · " .. Board.TimeLeft(rec.exp, now) .. " left")
      if rec.id == view.selectedId then row.sel:Show() else row.sel:Hide() end
      row:Show()
    else
      row:Hide()
    end
  end
  if #list == 0 then
    view.empty:SetText(ns.exchange and "No listings here yet. Click + New listing to post one." or UI.NO_GUILD_TEXT)
    view.empty:Show()
  else
    view.empty:Hide()
  end
end

local function makeRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(LIST_W - 30, ROW_H)
  row:SetPoint("TOPLEFT", 2, -2 - (i - 1) * ROW_H)
  row:SetFrameLevel((parent:GetFrameLevel() or 1) + 5)
  row:RegisterForClicks("LeftButtonUp")
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints(row)
  row.sel:SetColorTexture(0.23, 0.18, 0.10, 0.9)
  row.sel:Hide()
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(row)
  hl:SetColorTexture(1, 1, 1, 0.08)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(28, 28)
  row.icon:SetPoint("LEFT", 3, 0)
  row.tag = UI.Text(row, "GameFontHighlightSmall")
  row.tag:SetPoint("TOPLEFT", 36, -4)
  row.tag:SetWidth(30)
  row.item = UI.Text(row, "GameFontHighlight")
  row.item:SetPoint("TOPLEFT", 68, -3)
  row.item:SetWidth(LIST_W - 104)
  if row.item.SetWordWrap then row.item:SetWordWrap(false) end
  row.dot = row:CreateTexture(nil, "ARTWORK")
  row.dot:SetSize(8, 8)
  row.dot:SetPoint("BOTTOMLEFT", 70, 6)
  row.q = UI.Text(row, "GameFontDisableSmall", "?")
  row.q:SetPoint("BOTTOMLEFT", 70, 4)
  row.sub = UI.Text(row, "GameFontDisableSmall")
  row.sub:SetPoint("BOTTOMLEFT", 84, 4)
  row.sub:SetWidth(LIST_W - 120)
  on(row, "OnClick", function(self)
    if not self.rec then return end
    view.selectedId = self.rec.id
    setStatus(nil)
    Board.Refresh()
  end)
  on(row, "OnEnter", function(self)
    UI.ItemTooltip(self, self.rec and self.rec.d and self.rec.d.item)
  end)
  on(row, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  return row
end

-- Build / refresh -------------------------------------------------------------------------

local function selectFilter(key)
  view.filter = key
  for _, t in ipairs(view.tabs) do
    if t.key == key then t.button:LockHighlight() else t.button:UnlockHighlight() end
  end
  if view.faux then FauxScrollFrame_SetOffset(view.scroll, 0) else view.offset = 0 end
  if view.scroll.SetVerticalScroll then view.scroll:SetVerticalScroll(0) end
  setStatus(nil)
  Board.Refresh()
end

function Board.Refresh()
  if not view then return end
  view.list = load()
  local found
  for _, rec in ipairs(view.list) do if rec.id == view.selectedId then found = rec end end
  if not found then
    found = view.list[1]
    view.selectedId = found and found.id or nil
  end
  updateRows()
  Details.Show(found)
end

-- Status line after a successful Post/Save. During a chat lockdown the message waits in
-- Comm's queue, so say so instead of implying guildmates already have it.
function Board.SavedText(wasEditing, chatRestricted)
  local text = wasEditing and "Listing saved." or "Listing posted."
  if chatRestricted then text = text .. " It will reach guildmates when chat restrictions lift." end
  return text
end

-- Called by the Form after a successful Post/Save.
function Board.OnSaved(rec, wasEditing)
  if not view then return end
  if rec then view.selectedId = rec.id end
  local s = services()
  setStatus(Board.SavedText(wasEditing, s and s.compat and s.compat:IsRestricted("Chat") or false))
  Board.Refresh()
end

function Board.Build(parent)
  Details = ns.Exchange.BoardDetails
  view = { filter = "all", cat = "all", tabs = {}, rows = {}, list = {}, parent = parent }

  local x = 0
  for _, flt in ipairs(FILTERS) do
    local t = { key = flt.key }
    t.button = UI.Button(parent, flt.title, flt.width, function() selectFilter(flt.key) end)
    t.button:SetPoint("TOPLEFT", x, 0)
    x = x + flt.width + 4
    view.tabs[#view.tabs + 1] = t
  end
  local new = UI.Button(parent, "+ New listing", 120, function()
    local kind = (view.filter == "LF" or view.filter == "WTS") and view.filter or nil
    ns.Exchange.Form.Open(nil, kind)
  end)
  new:SetPoint("TOPRIGHT", 0, 0)

  -- Search box above the list.
  local label = UI.Text(parent, "GameFontNormalSmall", "Search:")
  label:SetPoint("TOPLEFT", 2, -TOP - 5)
  view.search = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  view.search:SetSize(LIST_W - 64, 20) -- ends at x = 334, before the Category button
  view.search:SetAutoFocus(false)
  view.search:SetPoint("TOPLEFT", 58, -TOP)
  on(view.search, "OnTextChanged", function() Board.Refresh() end)
  on(view.search, "OnEscapePressed", function(self) self:ClearFocus() end)
  on(view.search, "OnEnterPressed", function(self) self:ClearFocus() end)

  -- Category and Member filters, to the right of the search box.
  view.catBtn = UI.Button(parent, "Category: All", 140, function()
    view.all = allRecs()
    UI.PickList(view.catBtn, Board.CategoryItems(view.all), function(v)
      view.cat = v
      Board.Refresh()
    end, view.cat)
  end)
  view.catBtn:SetPoint("TOPLEFT", LIST_W, -TOP)
  view.memberBtn = UI.Button(parent, "Member: Anyone", 140, function()
    view.all = allRecs()
    UI.PickList(view.memberBtn, Board.MemberItems(view.all, memberLabel), function(v, item)
      view.member = v or nil
      view.memberText = v and item.label or nil
      Board.Refresh()
    end, view.member or false)
  end)
  view.memberBtn:SetPoint("LEFT", view.catBtn, "RIGHT", 4, 0)
  -- Back to an unfiltered board; shown only while some filter is active.
  view.resetBtn = UI.Button(parent, "Reset", 70, function()
    UI.ClosePickList()
    view.cat, view.member, view.memberText = "all", nil, nil
    view.search:SetText("")
    view.search:ClearFocus()
    selectFilter("all")
  end)
  view.resetBtn:SetPoint("LEFT", view.memberBtn, "RIGHT", 4, 0)
  view.resetBtn:Hide()

  -- List panel with pooled rows.
  local listPanel = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  listPanel:SetPoint("TOPLEFT", 0, -LIST_TOP)
  listPanel:SetSize(LIST_W, ROWS * ROW_H + 4)
  UI.ApplyBackdrop(listPanel, 0.6)
  view.listPanel = listPanel

  view.faux = FauxScrollFrame_Update and FauxScrollFrame_GetOffset and FauxScrollFrame_OnVerticalScroll
    and FauxScrollFrame_SetOffset and true or false
  if view.faux then
    view.scroll = CreateFrame("ScrollFrame", "GuildhallUIExchangeListScroll", listPanel, "FauxScrollFrameTemplate")
    view.scroll:SetPoint("TOPLEFT", 2, -2)
    view.scroll:SetPoint("BOTTOMRIGHT", -26, 2)
    on(view.scroll, "OnVerticalScroll", function(self, value)
      FauxScrollFrame_OnVerticalScroll(self, value, ROW_H, updateRows)
    end)
  else
    -- Fallback: mouse wheel moves a manual offset.
    view.scroll = listPanel
    view.offset = 0
    listPanel:EnableMouseWheel(true)
    on(listPanel, "OnMouseWheel", function(_, delta)
      view.offset = (view.offset or 0) - delta
      updateRows()
    end)
  end
  for i = 1, ROWS do view.rows[i] = makeRow(listPanel, i) end
  view.empty = UI.Text(listPanel, "GameFontDisable")
  view.empty:SetPoint("TOPLEFT", 12, -14)
  view.empty:SetWidth(LIST_W - 40)

  -- Details pane (UI/Details.lua).
  local det = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  det:SetPoint("TOPLEFT", DETAIL_X, -LIST_TOP) -- below the filter row
  det:SetPoint("BOTTOMRIGHT", 0, BOTTOM)
  UI.ApplyBackdrop(det, 0.6)
  view.detail = det
  Details.Build(view, det, (736 - DETAIL_X) - 24)

  view.status = UI.Text(parent, "GameFontNormalSmall")
  view.status:SetPoint("BOTTOMLEFT", 2, 2)
  view.status:SetWidth(730)

  -- Data changes (sync, posts, removals) refresh the board while it is visible.
  if ns.Events and not Board.listening then
    Board.listening = true
    ns.Events:On("ExchangeChanged", function()
      if view and view.parent:IsVisible() then Board.Refresh() end
    end)
  end

  for _, t in ipairs(view.tabs) do
    if t.key == view.filter then t.button:LockHighlight() end
  end
  view.refresh = function() Board.Refresh() end
  return view
end
