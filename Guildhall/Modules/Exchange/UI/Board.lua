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

local function escape(s) return (tostring(s or ""):gsub("|", "||")) end
local function bare(name) return type(name) == "string" and (name:match("^([^%-]+)") or name) or nil end

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

local function matches(rec, needle)
  if needle == "" then return true end
  local d = rec.d
  for _, v in ipairs({ Util.ItemName(d.item or ""), rec.char, d.poster }) do
    if type(v) == "string" and string.find(string.lower(v), needle, 1, true) then return true end
  end
  return false
end

local function load()
  local out = {}
  if not ns.exchange then return out end
  local needle = string.lower(Util.Trim(view.search:GetText() or ""))
  for _, rec in ipairs(ns.exchange:List(view.filter)) do
    if type(rec.d) == "table" and matches(rec, needle) then out[#out + 1] = rec end
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
  row.tag = UI.Text(row, "GameFontHighlightSmall")
  row.tag:SetPoint("TOPLEFT", 6, -4)
  row.tag:SetWidth(30)
  row.item = UI.Text(row, "GameFontHighlight")
  row.item:SetPoint("TOPLEFT", 38, -3)
  row.item:SetWidth(LIST_W - 74)
  if row.item.SetWordWrap then row.item:SetWordWrap(false) end
  row.dot = row:CreateTexture(nil, "ARTWORK")
  row.dot:SetSize(8, 8)
  row.dot:SetPoint("BOTTOMLEFT", 40, 6)
  row.q = UI.Text(row, "GameFontDisableSmall", "?")
  row.q:SetPoint("BOTTOMLEFT", 40, 4)
  row.sub = UI.Text(row, "GameFontDisableSmall")
  row.sub:SetPoint("BOTTOMLEFT", 54, 4)
  row.sub:SetWidth(LIST_W - 90)
  on(row, "OnClick", function(self)
    if not self.rec then return end
    view.selectedId = self.rec.id
    setStatus(nil)
    Board.Refresh()
  end)
  on(row, "OnEnter", function(self)
    local item = self.rec and self.rec.d and self.rec.d.item
    if not (GameTooltip and Util.IsItemLink(item)) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(item)
    GameTooltip:Show()
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

-- Called by the Form after a successful Post/Save.
function Board.OnSaved(rec, wasEditing)
  if not view then return end
  if rec then view.selectedId = rec.id end
  setStatus(wasEditing and "Listing saved." or "Listing posted.")
  Board.Refresh()
end

function Board.Build(parent)
  Details = ns.Exchange.BoardDetails
  view = { filter = "all", tabs = {}, rows = {}, list = {}, parent = parent }

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
  view.search:SetSize(LIST_W - 64, 20)
  view.search:SetAutoFocus(false)
  view.search:SetPoint("TOPLEFT", 58, -TOP)
  on(view.search, "OnTextChanged", function() Board.Refresh() end)
  on(view.search, "OnEscapePressed", function(self) self:ClearFocus() end)
  on(view.search, "OnEnterPressed", function(self) self:ClearFocus() end)

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
  det:SetPoint("TOPLEFT", DETAIL_X, -TOP)
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
