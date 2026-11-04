local ADDON, ns = ...

-- Leaderboard tab: period and board pickers, a ranked list on the left and the selected
-- player's score on the right (a full breakdown for yourself and for officers, totals for
-- everyone else). Past months read the saved month record instead of the ledger.
-- View.Build(parent) -> view {Refresh, refresh}; layout follows the design mockup
-- ("Leaderboard, member view" and "your own breakdown"), 736 x 412 inside the tab.
-- Hidden profiles (profile:IsHidden) are left out of live boards but still count toward the
-- guild total; a past month shows them as "(hidden)". A month record's rec.t is inverted for
-- tie-breaking and is never shown; "Saved <date> by <name>" uses d.savedAt and d.savedBy.
-- Refreshes when the tab is shown and, debounced to once a second while visible, when the data
-- behind the ledger changes.
-- Global table entry: StaticPopupDialogs.GUILDHALL_LB_RETAKE.
ns.Leaderboard = ns.Leaderboard or {}
local UI = ns.UI
local Util = ns.Util
local View = ns.Leaderboard.View or {}
ns.Leaderboard.View = View

local LIST_W, LIST_TOP, ROW_H, ROWS, ROWS_TOP = 300, 56, 26, 11, 20
local DETAIL_X, DETAIL_TOP, DETAIL_W, DETAIL_H = 310, 26, 426, 382
local LINES, LINE_H = 8, 18
local LINE_POOL = 14 -- LINES rows, but collapsed headers each take a button on a shared row
local TABLE_MAX = 10
local DEBOUNCE = 1

local PERIOD_TEXT = { week = "this week", month = "this month", all = "in the last 400 days" }
local MONTH_NAMES = { "January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December" }
local WHY = {
  ["waiting for confirmation"] = "waiting for the other player to confirm",
  ["rank excluded"] = "this guild rank's deposits are not counted",
  ["tab not counted"] = "this bank tab is not counted",
  ["not linked"] = "the character is not linked to a profile",
}
local UNPAIRED = {
  exchange = "the other player's client hasn't confirmed it yet",
  bank = "no second guildmate with Guildhall has seen this in the bank log yet",
}
local function whyText(row)
  if row.why == "unpaired" then
    return tostring(row.type):match("^bank%.") and UNPAIRED.bank or UNPAIRED.exchange
  end
  return WHY[row.why] or tostring(row.why or "not counted")
end
local EMPTY_TEXT = "No verified activity yet. Deals made through Exchange listings and guild bank donations will show here."
local PRIVATE_TEXT = "The breakdown of a player's score is visible to that player and to officers."
local FOOT_TEXT = "Only deals matched to an Exchange listing and checked by both clients count, plus guild bank donations. "
  .. "Members who turned off \"Show me on the leaderboard\" aren't listed, but their activity still counts toward the guild total."
local GOLD, GRAY, TAN = { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }, { 0.78, 0.73, 0.54 }
local RANK_COLOR = { { 1, 0.82, 0 }, { 0.85, 0.85, 0.85 }, { 0.82, 0.54, 0.29 } }

local view -- the single built tab

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function services() return ns.services end
local function lb() return ns.leaderboard end

local function isOfficer()
  local s = services()
  return s ~= nil and s.roster:IsOfficer(s.playerChar) == true
end

-- Who may retake a saved month. Task 16 switches this to a rank permission.
local function canRetake()
  local s = services()
  return s ~= nil and s.roster:IsOfficer(s.playerChar) == true
end

-- Formatting ----------------------------------------------------------------------------

local function commas(n)
  local s = string.format("%d", math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

local function fmtGold(copper) return commas(math.floor(copper / 10000)) .. " g" end

local function fmtValue(id, v)
  if id == "overall" then return ns.Scoring.FormatPoints(v) end
  local def = ns.Activity.Get(id)
  if def and def.unit == "gold" then return fmtGold(v) end
  return commas(v)
end

local function monthLabel(ym)
  local y, m = tostring(ym):match("^(%d+)-(%d+)$")
  local name = MONTH_NAMES[tonumber(m) or 0]
  if not name then return tostring(ym) end
  return name .. " " .. y
end

local function periodText()
  if view.pastMonth then return "in " .. monthLabel(view.pastMonth) end
  return PERIOD_TEXT[view.period]
end

local function boardLabel(id)
  if id == "overall" then return "Overall" end
  local def = ns.Activity.Get(id)
  return def and def.label or tostring(id)
end

local function clockTz()
  local s, l = services(), lb()
  return ns.Scoring.Clock(l.config, s.compat, s.now()).tz or 0
end

-- Server-time date of a stored epoch second.
local function serverDate(t, fmt)
  local f = date or os.date
  return f("!" .. fmt, t + clockTz())
end

local function nameOf(profileId)
  return Util.Escape(ns.LbConfig._displayName(services().profile, profileId))
end

-- Data ----------------------------------------------------------------------------------

-- { entries = { {profile, name, value, rank, online, hidden} }, goldKept, from, to, rec, weights }
local function model()
  local s, l = services(), lb()
  local m = { entries = {}, goldKept = 0, weights = l.config:Weights() }
  if view.pastMonth then
    local rec = l.config:Month(view.pastMonth)
    m.rec = rec
    if rec then
      m.goldKept = rec.goldKept or 0
      local list = view.board == "overall" and rec.overall or (rec.boards or {})[view.board] or {}
      for _, e in ipairs(list) do
        local hidden = s.profile:IsHidden(e.profile) == true
        m.entries[#m.entries + 1] = { profile = e.profile, value = e.value, rank = e.rank, hidden = hidden,
          name = hidden and "(hidden)" or Util.Escape(Util.DisplayName(e.name)), online = false }
      end
    end
    return m
  end
  local now = s.now()
  local clock = ns.Scoring.Clock(l.config, s.compat, now)
  m.from, m.to = ns.Scoring.Period(view.period, now, clock)
  local result = l.ledger:Query({ from = m.from, to = m.to })
  m.goldKept = result.goldKept or 0
  local board = ns.Scoring.Board(result, view.board, m.weights, {
    isHidden = function(id) return s.profile:IsHidden(id) == true end,
  })
  for _, e in ipairs(board) do
    m.entries[#m.entries + 1] = { profile = e.profile, value = e.value, rank = e.rank, hidden = false,
      name = nameOf(e.profile), online = s.profile:OnlineChar(e.profile) ~= nil }
  end
  local me = s.profile:Id()
  if me ~= nil then
    local ranked = false
    for _, e in ipairs(m.entries) do if e.profile == me then ranked = true end end
    if not ranked then
      m.unranked = { profile = me, value = 0, hidden = false, online = true, name = nameOf(me), unranked = true }
    end
  end
  return m
end

local function myId()
  local s = services()
  return s.profile:Id()
end

-- The entry shown on the right: the chosen one, else yours, else the top.
local function selectedEntry(m)
  local mine, first
  for _, e in ipairs(m.entries) do
    if e.profile == view.selected then return e end
    if e.profile == myId() then mine = e end
    first = first or e
  end
  return mine or m.unranked or first
end

local function myEntry(m)
  for i, e in ipairs(m.entries) do
    if e.profile == myId() then return e, i end
  end
end

-- Rows ----------------------------------------------------------------------------------

local function setRow(row, e, selected)
  row.entry = e or false
  if not e then row:Hide(); return end
  local c = RANK_COLOR[e.rank] or TAN
  row.rank:SetText(tostring(e.rank))
  row.rank:SetTextColor(c[1], c[2], c[3])
  if e.online then row.dot:SetColorTexture(0.25, 0.82, 0.25) else row.dot:SetColorTexture(0.4, 0.4, 0.4) end
  local name = e.name
  if e.profile == myId() then name = name .. " |cff9d9d9d(you)|r" end
  row.name:SetText(name)
  row.value:SetText(fmtValue(view.board, e.value))
  if selected then row.sel:Show() else row.sel:Hide() end
  row:Show()
end

local function makeRow(parent, y, width)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(width, ROW_H)
  row:SetPoint("TOPLEFT", 2, y)
  row:RegisterForClicks("LeftButtonUp")
  row.entry = false
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints(row)
  row.sel:SetColorTexture(0.23, 0.18, 0.10, 0.9)
  row.sel:Hide()
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(row)
  hl:SetColorTexture(1, 1, 1, 0.08)
  row.rank = UI.Text(row, "GameFontNormal")
  row.rank:SetPoint("LEFT", 6, 0)
  row.rank:SetWidth(26)
  row.dot = row:CreateTexture(nil, "ARTWORK")
  row.dot:SetSize(8, 8)
  row.dot:SetPoint("LEFT", 32, 0)
  row.value = UI.Text(row, "GameFontNormal")
  row.value:SetPoint("RIGHT", -6, 0)
  row.value:SetJustifyH("RIGHT")
  row.value:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  row.name = UI.Text(row, "GameFontHighlight")
  row.name:SetPoint("LEFT", 46, 0)
  row.name:SetPoint("RIGHT", row.value, "LEFT", -6, 0)
  if row.name.SetWordWrap then row.name:SetWordWrap(false) end
  on(row, "OnClick", function(self)
    if not self.entry then return end
    view.selected = self.entry.profile
    View.Refresh()
  end)
  return row
end

local function renderList(m)
  local entries = m.entries
  view.offset = math.max(0, math.min(view.offset, #entries - ROWS))
  local sel = selectedEntry(m)
  for i, row in ipairs(view.rows) do
    local e = entries[view.offset + i]
    setRow(row, e, e ~= nil and sel ~= nil and e.profile == sel.profile)
  end
  local mine, idx = myEntry(m)
  local pinned = mine ~= nil and (idx <= view.offset or idx > view.offset + ROWS)
  if pinned then
    setRow(view.pinned, mine, sel ~= nil and mine.profile == sel.profile)
  else
    setRow(view.pinned, nil)
  end
  for _, t in ipairs(view.dashes) do
    if pinned then t:Show() else t:Hide() end
  end
  if #entries == 0 then
    view.empty:SetText(view.pastMonth and "Nobody was ranked on this board that month." or EMPTY_TEXT)
    view.empty:Show()
  else
    view.empty:Hide()
  end
  local unit = view.board == "overall" and "Points" or boardLabel(view.board)
  view.unit:SetText(unit)
end

-- Detail pane ---------------------------------------------------------------------------

local function place(fs, x, y)
  fs:ClearAllPoints()
  fs:SetPoint("TOPLEFT", view.detail, "TOPLEFT", x, -y)
end

local function show(fs, text, x, y)
  fs:SetText(text)
  if x then place(fs, x, y) end
  fs:Show()
end

local function clearDetail()
  local d = view.d
  for _, fs in ipairs({ d.title, d.sub, d.status, d.big, d.bigLabel, d.hint, d.foot, d.saved,
    d.hActivity, d.hValue, d.hWeight, d.hPoints, d.totalLabel, d.totalValue, d.msg }) do
    fs:SetText("")
    fs:Hide()
  end
  d.dot:Hide()
  d.retake:Hide()
  for _, r in ipairs(d.table) do
    for _, fs in ipairs(r) do fs:SetText(""); fs:Hide() end
  end
  for _, line in ipairs(d.lines) do
    line.toggle = false
    line.left:SetText("")
    line.mid:SetText("")
    line.right:SetText("")
    line:Hide()
  end
end

local function shortDate(at) return serverDate(at, "%m-%d") end

local function itemText(item)
  if item == nil then return nil end
  if type(item) == "number" then
    local name
    for _, f in ipairs({ C_Item and C_Item.GetItemNameByID, GetItemInfo }) do
      if not name and type(f) == "function" then
        local ok, n = pcall(f, item)
        if ok and type(n) == "string" then name = n end
      end
    end
    return "[" .. Util.Escape(name or ("item " .. item)) .. "]"
  end
  item = tostring(item)
  if Util.IsItemLink(item) then return item end
  return "[" .. Util.Escape(Util.ItemName(item)) .. "]"
end

local function rowValue(row)
  local def = ns.Activity.Get(row.type)
  if def and def.unit == "gold" then return fmtGold(math.abs(row.value)) end
  return commas(math.abs(row.value))
end

-- One list line in plain words, from the row's own fields (counterparty is optional).
local function describe(row)
  local who = type(row.counterparty) == "string" and nameOf(row.counterparty) or nil
  local item = itemText(row.item)
  local t = row.type
  if t == "exchange.sales" then
    return "Sold " .. (item or "an item") .. (who and (" to " .. who) or "")
  elseif t == "exchange.purchases" then
    return "Bought " .. (item or "an item") .. (who and (" from " .. who) or "")
  elseif t == "exchange.listings" then
    return "Listed " .. (item or "an item")
  elseif t == "bank.items" then
    return (row.value < 0 and "Withdrew " or "Deposited ") .. (item or "items") .. " x" .. commas(math.abs(row.value))
  elseif t == "bank.gold" then
    return (row.value < 0 and "Withdrew " or "Deposited ") .. fmtGold(math.abs(row.value))
  end
  local def = ns.Activity.Get(t)
  local label = def and def.label or tostring(t)
  return label .. (item and (" " .. item) or "")
end

-- Lines under the breakdown table: an open section is a header plus its items; consecutive
-- collapsed sections share one row of headers joined with " · ".
local function listLines(bd)
  local groups = {}
  for _, def in ipairs(ns.Activity.Types()) do
    local items = bd.items[def.id]
    if items and #items > 0 then
      table.sort(items, function(a, b) return a.at > b.at end)
      groups[#groups + 1] = { key = def.id, title = def.label, rows = items, counted = true }
    end
  end
  if #bd.notCounted > 0 then
    table.sort(bd.notCounted, function(a, b) return a.at > b.at end)
    groups[#groups + 1] = { key = "uncounted", title = "Not counted", rows = bd.notCounted, counted = false }
  end
  view.firstKey = groups[1] and groups[1].key
  local headerRows, prevCollapsed = 0, false
  for i, g in ipairs(groups) do
    local open = view.expanded[g.key]
    if open == nil then open = (i == 1) end
    g.open = open
    if open or not prevCollapsed then headerRows = headerRows + 1 end
    prevCollapsed = not open
  end
  local out, budget, run = {}, LINES - headerRows, nil
  for _, g in ipairs(groups) do
    local head = (g.open and "- " or "+ ") .. g.title .. " (" .. #g.rows .. ")"
    if g.open then
      run = nil
      out[#out + 1] = { key = g.key, header = head, gray = not g.counted }
      for _, row in ipairs(g.rows) do
        if budget <= 0 then break end
        budget = budget - 1
        local what = describe(row)
        if not g.counted then what = what .. ", " .. whyText(row) end
        out[#out + 1] = { date = shortDate(row.at), what = what, value = g.counted and rowValue(row) or "",
          gray = not g.counted }
      end
    else
      if not run then run = {}; out[#out + 1] = { segs = run } end
      run[#run + 1] = { key = g.key, header = head, gray = not g.counted }
    end
  end
  for _, spec in ipairs(out) do
    if spec.segs then
      for i, seg in ipairs(spec.segs) do
        if i < #spec.segs then seg.header = seg.header .. " ·" end
      end
    end
  end
  return out
end

local function renderBreakdown(m, sel, isMe)
  local d = view.d
  local bd = ns.Scoring.Breakdown(lb().ledger, sel.profile, m.from, m.to, m.weights)
  local pts = ns.Scoring.FormatPoints(bd.total)
  local boardText = view.board == "overall" and "overall" or boardLabel(view.board):lower()
  local rankText = (sel.rank and ("#" .. sel.rank .. " " .. boardText) or ("unranked " .. boardText))
    .. " · " .. periodText()
  if isMe then
    show(d.title, "Your score: " .. pts .. " points", 14, 10)
    show(d.sub, rankText, 14, 32)
  else
    show(d.title, "#" .. sel.rank .. "  " .. sel.name, 14, 10)
    show(d.sub, pts .. " points · " .. periodText(), 14, 32)
  end
  local y = 56
  for fs, text in pairs({ [d.hActivity] = "Activity", [d.hValue] = "Value", [d.hWeight] = "Weight",
    [d.hPoints] = "Points" }) do
    fs:SetText(text)
    fs:Show()
  end
  d.anchor(d.hActivity, d.hValue, d.hWeight, d.hPoints, y)
  y = y + 16
  for i, line in ipairs(bd.lines) do
    local r = d.table[i]
    if not r then break end
    local def = ns.Activity.Get(line.type)
    r[1]:SetText(def and def.label or line.type)
    r[2]:SetText(fmtValue(line.type, line.value))
    r[3]:SetText("× " .. string.format("%g", line.weight))
    r[4]:SetText(ns.Scoring.FormatPoints(line.points))
    for _, fs in ipairs(r) do fs:Show() end
    d.anchor(r[1], r[2], r[3], r[4], y)
    y = y + 19
  end
  d.totalLabel:SetText("Total")
  d.totalValue:SetText(pts)
  d.totalLabel:Show()
  d.totalValue:Show()
  d.anchor(d.totalLabel, nil, nil, d.totalValue, y + 2)
  y = y + 26
  local n = 0
  local function put(spec, x, rowY)
    n = n + 1
    local line = d.lines[n]
    if not line then return end
    line.toggle = spec.header and spec.key or false
    line.left:SetText(spec.header or spec.date)
    line.mid:SetText(spec.header and "" or spec.what)
    line.right:SetText(spec.value or "")
    local c = spec.gray and GRAY or (spec.header and TAN or { 1, 1, 1 })
    line.left:SetTextColor(c[1], c[2], c[3])
    line.mid:SetTextColor(c[1], c[2], c[3])
    line:SetWidth(spec.header and (7 * #spec.header + 6) or (DETAIL_W - 28))
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", view.detail, "TOPLEFT", x, -rowY)
    line:Show()
    return line
  end
  for _, spec in ipairs(listLines(bd)) do
    if spec.segs then
      local x = 14
      for _, seg in ipairs(spec.segs) do
        put(seg, x, y)
        x = x + 7 * #seg.header + 10
      end
    else
      put(spec, 14, y)
    end
    y = y + LINE_H
  end
end

local function renderTotals(m, sel)
  local d = view.d
  show(d.title, "#" .. sel.rank .. "  " .. sel.name, 14, 12)
  if not sel.hidden and not view.pastMonth then
    d.dot:Show()
    if sel.online then d.dot:SetColorTexture(0.25, 0.82, 0.25) else d.dot:SetColorTexture(0.4, 0.4, 0.4) end
    show(d.status, sel.online and "online" or "offline", 30, 39)
  end
  show(d.big, fmtValue(view.board, sel.value), 14, 66)
  local what = view.board == "overall" and "points" or boardLabel(view.board):lower()
  show(d.bigLabel, what .. " " .. periodText())
  if not view.pastMonth then
    show(d.hint, PRIVATE_TEXT, 14, 124)
    show(d.foot, FOOT_TEXT, 14, DETAIL_H - 62)
  end
end

local function renderDetail(m)
  clearDetail()
  local d = view.d
  local sel = selectedEntry(m)
  if view.pastMonth and m.rec then
    local who = Util.Escape(Util.DisplayName(m.rec.savedBy))
    show(d.saved, "Saved " .. serverDate(m.rec.savedAt, "%Y-%m-%d") .. " by " .. who, 14, DETAIL_H - 34)
    if canRetake() then d.retake:Show() end
  end
  if view.message then show(d.msg, view.message, 14, DETAIL_H - 54) end
  if not sel then return end
  if view.pastMonth then
    renderTotals(m, sel)
  elseif ns.Scoring.CanSeeBreakdown(myId(), sel.profile, isOfficer()) then
    renderBreakdown(m, sel, sel.profile == myId())
  else
    renderTotals(m, sel)
  end
end

-- Headline and buttons -----------------------------------------------------------------

local function renderHeader(m)
  view.headline:SetText("Gold kept in the guild " .. periodText() .. ": " .. fmtGold(m.goldKept))
  for _, b in ipairs(view.periodButtons) do
    if not view.pastMonth and b.key == view.period then b.button:LockHighlight() else b.button:UnlockHighlight() end
  end
  if view.pastMonth then view.pastBtn:LockHighlight() else view.pastBtn:UnlockHighlight() end
  view.boardBtn:SetText("Board: " .. boardLabel(view.board))
  local l = lb()
  if l and l.demo then
    view.demo:SetText("Demo data, not real. /gh lbdemo off")
    view.demo:Show()
  else
    view.demo:Hide()
  end
end

local function boardItems()
  local items = { { label = "Overall", value = "overall" } }
  for _, def in ipairs(ns.Activity.Types()) do
    items[#items + 1] = { label = def.label, value = def.id }
  end
  return items
end

local function monthItems()
  local items = {}
  for _, ym in ipairs(lb().config:Months()) do
    items[#items + 1] = { label = monthLabel(ym), value = ym }
  end
  if #items == 0 then items[1] = { label = "No saved months yet", value = false } end
  return items
end

function View.DoRetake(ym)
  local l = lb()
  if not (l and canRetake()) then return end
  local ok, err = l.config:RetakeMonth(ym, l.ledger)
  if ok then
    view.message = nil
  else
    view.message = "Retake failed: " .. tostring(err or "not accepted")
  end
  View.Refresh()
end

if StaticPopupDialogs then
  StaticPopupDialogs["GUILDHALL_LB_RETAKE"] = {
    text = "Retake %s? This saves the month again from the numbers your client has now, replaces the "
      .. "saved list for everyone, and is logged.",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(_, ym) UI.Try(View.DoRetake, ym) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
end

local function askRetake()
  if not view.pastMonth then return end
  if StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs["GUILDHALL_LB_RETAKE"] then
    StaticPopup_Show("GUILDHALL_LB_RETAKE", monthLabel(view.pastMonth), nil, view.pastMonth)
  end
end

-- Refresh -------------------------------------------------------------------------------

function View.Refresh()
  if not view then return end
  view.lastAt = services() and services().now() or 0
  UI.Try(function()
    if not (lb() and services()) then return end
    local m = model()
    renderHeader(m)
    renderList(m)
    renderDetail(m)
  end)
end

-- Ledger-invalidating events: refresh a visible tab at most once a second, always on the next
-- tick (the ledger's own handlers for the same event may not have run yet). A hidden tab
-- refreshes when it is shown.
local function onDataChanged()
  if not view or view.pending or not view.parent:IsVisible() then return end
  local s = services()
  if not s then return end
  view.pending = true
  local wait = (s.now() - view.lastAt >= DEBOUNCE) and 0 or DEBOUNCE
  s.after(wait, function()
    view.pending = false
    if view.parent:IsVisible() then View.Refresh() end
  end)
end

local function setPeriod(key)
  view.period, view.pastMonth, view.offset, view.message = key, nil, 0, nil
  View.Refresh()
end

-- Build ---------------------------------------------------------------------------------

local function dashes(parent, y)
  local list = {}
  for i = 0, 35 do
    local t = parent:CreateTexture(nil, "ARTWORK")
    list[#list + 1] = t
    t:SetSize(5, 1)
    t:SetPoint("TOPLEFT", 4 + i * 8, y)
    t:SetColorTexture(0.42, 0.35, 0.23, 1)
  end
  return list
end

local function buildDetail(panel)
  local d = { table = {}, lines = {} }
  local huge = _G.GameFontNormalHuge and "GameFontNormalHuge" or "GameFontNormalLarge"
  d.title = UI.Text(panel, "GameFontNormalLarge")
  d.sub = UI.Text(panel, "GameFontNormal")
  d.sub:SetTextColor(TAN[1], TAN[2], TAN[3])
  d.dot = panel:CreateTexture(nil, "ARTWORK")
  d.dot:SetSize(8, 8)
  d.dot:SetPoint("TOPLEFT", 16, -44)
  d.status = UI.Text(panel, "GameFontNormal")
  d.status:SetTextColor(0.7, 0.65, 0.54)
  d.big = UI.Text(panel, huge)
  d.big:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  d.bigLabel = UI.Text(panel, "GameFontNormal")
  d.bigLabel:SetPoint("BOTTOMLEFT", d.big, "BOTTOMRIGHT", 6, 3)
  d.bigLabel:SetTextColor(TAN[1], TAN[2], TAN[3])
  d.hint = UI.Text(panel, "GameFontNormal")
  d.hint:SetWidth(DETAIL_W - 30)
  d.hint:SetTextColor(0.7, 0.65, 0.54)
  d.foot = UI.Text(panel, "GameFontNormalSmall")
  d.foot:SetWidth(DETAIL_W - 30)
  d.foot:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  d.msg = UI.Text(panel, "GameFontNormalSmall")
  d.msg:SetTextColor(1, 0.35, 0.35)
  d.saved = UI.Text(panel, "GameFontNormalSmall")
  d.saved:SetTextColor(GRAY[1], GRAY[2], GRAY[3])

  -- Breakdown table: the activity name at the left, three right-aligned columns at the right.
  local function cell(font, w, offset)
    local fs = UI.Text(panel, font)
    fs:SetWidth(w)
    if offset then fs:SetJustifyH("RIGHT") end
    return fs
  end
  local function columns(font)
    local a = UI.Text(panel, font)
    local v, w, p = cell(font, 60, true), cell(font, 52, true), cell(font, 50, true)
    return a, v, w, p
  end
  d.hActivity, d.hValue, d.hWeight, d.hPoints = columns("GameFontNormalSmall")
  for _, fs in ipairs({ d.hActivity, d.hValue, d.hWeight, d.hPoints }) do
    fs:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  end
  d.totalLabel = UI.Text(panel, "GameFontNormal")
  d.totalValue = UI.Text(panel, "GameFontNormal")
  d.totalValue:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  for i = 1, TABLE_MAX do
    local a, v, w, p = columns("GameFontHighlight")
    w:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
    p:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    d.table[i] = { a, v, w, p }
  end
  -- Right-aligned columns are anchored by their right edge (Points, Weight, Value).
  local function anchorColumns(a, v, w, p, y)
    place(a, 14, y)
    for _, c in ipairs({ { p, -14 }, { w, -64 }, { v, -116 } }) do
      if c[1] then
        c[1]:ClearAllPoints()
        c[1]:SetPoint("TOPRIGHT", panel, "TOPRIGHT", c[2], -y)
      end
    end
  end
  d.anchor = anchorColumns

  for i = 1, LINE_POOL do
    local line = CreateFrame("Button", nil, panel)
    line:SetSize(DETAIL_W - 28, LINE_H)
    line:RegisterForClicks("LeftButtonUp")
    line.toggle = false
    line.left = UI.Text(line, "GameFontNormalSmall")
    line.left:SetPoint("LEFT", 0, 0)
    line.mid = UI.Text(line, "GameFontNormalSmall")
    line.mid:SetPoint("LEFT", 40, 0)
    line.mid:SetWidth(DETAIL_W - 28 - 40 - 56)
    if line.mid.SetWordWrap then line.mid:SetWordWrap(false) end
    line.right = UI.Text(line, "GameFontNormalSmall")
    line.right:SetPoint("RIGHT", 0, 0)
    line.right:SetJustifyH("RIGHT")
    line.right:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    on(line, "OnClick", function(self)
      local key = self.toggle
      if not key then return end
      local open = view.expanded[key]
      if open == nil then open = (key == view.firstKey) end
      view.expanded[key] = not open
      View.Refresh()
    end)
    d.lines[i] = line
  end

  d.retake = UI.Button(panel, "Retake", 80, askRetake)
  d.retake:SetPoint("BOTTOMRIGHT", -14, 12)
  d.retake:Hide()
  return d
end

function View.Build(parent)
  view = { parent = parent, period = "month", board = "overall", offset = 0, rows = {}, expanded = {},
    periodButtons = {}, lastAt = 0 }

  view.headline = UI.Text(parent, "GameFontNormalLarge")
  view.headline:SetPoint("TOPLEFT", 0, 0)
  view.headline:SetTextColor(GOLD[1], GOLD[2], GOLD[3])

  -- Period buttons, right-aligned: Week, Month, All time, Past months.
  view.pastBtn = UI.Button(parent, "Past months", 104, function()
    UI.PickList(view.pastBtn, monthItems(), function(ym)
      if not ym then return end
      view.pastMonth, view.offset, view.message = ym, 0, nil
      View.Refresh()
    end, view.pastMonth)
  end)
  view.pastBtn:SetPoint("TOPRIGHT", 0, 2)
  local prev = view.pastBtn
  for _, p in ipairs({ { "all", "All time", 70 }, { "month", "Month", 60 }, { "week", "Week", 60 } }) do
    local b = { key = p[1] }
    b.button = UI.Button(parent, p[2], p[3], function() setPeriod(p[1]) end)
    b.button:SetPoint("RIGHT", prev, "LEFT", -4, 0)
    prev = b.button
    view.periodButtons[#view.periodButtons + 1] = b
  end

  view.boardBtn = UI.Button(parent, "Board: Overall", 200, function()
    UI.PickList(view.boardBtn, boardItems(), function(id)
      view.board, view.offset = id, 0
      View.Refresh()
    end, view.board)
  end)
  view.boardBtn:SetPoint("TOPLEFT", 0, -26)
  view.demo = UI.Text(parent, "GameFontNormal")
  view.demo:SetPoint("LEFT", view.boardBtn, "RIGHT", 10, 0)
  view.demo:SetTextColor(1, 0.5, 0.2)
  view.demo:Hide()

  -- List panel.
  local list = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  list:SetPoint("TOPLEFT", 0, -LIST_TOP)
  list:SetSize(LIST_W, 352)
  UI.ApplyBackdrop(list, 0.6)
  view.list = list
  local h1 = UI.Text(list, "GameFontNormalSmall", "#")
  h1:SetPoint("TOPLEFT", 8, -5)
  h1:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  local h2 = UI.Text(list, "GameFontNormalSmall", "Player")
  h2:SetPoint("TOPLEFT", 36, -5)
  h2:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  view.unit = UI.Text(list, "GameFontNormalSmall")
  view.unit:SetPoint("TOPRIGHT", -8, -5)
  view.unit:SetJustifyH("RIGHT")
  view.unit:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  for i = 1, ROWS do view.rows[i] = makeRow(list, -ROWS_TOP - (i - 1) * ROW_H, LIST_W - 6) end
  view.dashes = dashes(list, -(ROWS_TOP + ROWS * ROW_H + 4))
  view.pinned = makeRow(list, -(ROWS_TOP + ROWS * ROW_H + 8), LIST_W - 6)
  view.pinned:Hide()
  view.empty = UI.Text(list, "GameFontDisable")
  view.empty:SetPoint("TOPLEFT", 12, -ROWS_TOP - 8)
  view.empty:SetWidth(LIST_W - 28)
  list:EnableMouseWheel(true)
  on(list, "OnMouseWheel", function(_, delta)
    view.offset = view.offset - delta
    View.Refresh()
  end)

  -- Detail pane.
  local det = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  det:SetPoint("TOPLEFT", DETAIL_X, -DETAIL_TOP)
  det:SetSize(DETAIL_W, DETAIL_H)
  UI.ApplyBackdrop(det, 0.6)
  view.detail = det
  view.d = buildDetail(det)

  if ns.Events and not View.listening then
    View.listening = true
    for _, event in ipairs({ "ObservationsChanged", "LeaderboardConfigChanged", "RosterRefreshed", "ProfilesChanged" }) do
      ns.Events:On(event, onDataChanged)
    end
  end

  view.Refresh = function() View.Refresh() end
  view.refresh = view.Refresh
  return view
end
