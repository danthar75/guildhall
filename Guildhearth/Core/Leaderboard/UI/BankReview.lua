local ADDON, ns = ...

-- Bank review: every recorded guild bank deposit and withdrawal, newest first, with a checkbox
-- per entry. Unticking one (after an optional reason) excludes it from its member's score; it
-- still counts toward the guild's bank totals. Ticking it counts it again. Needs the
-- "bankreview" permission (guild master only by default). While /gh lbdemo is on it lists the
-- demo rows read-only.
-- BankReview.Open() -> ok, err. Builds the panel on first use; later opens reuse it.
-- BankReview.Refresh(): re-reads the ledger and exclusions while the panel is shown.
-- BankReview.Filter(rows, filters, exclusions, tz) -> rows matching filters { player, tab,
--   month, excludedOnly } (player = BankReview.PlayerKey(row), tab = number or "money").
-- BankReview.DoExclude(ref, reason) / BankReview.DoInclude(ref): the checkbox actions.
-- Named globals: "GuildhearthBankReview" (so Esc closes it through UISpecialFrames) and the
-- StaticPopupDialogs.GUILDHEARTH_BANK_EXCLUDE entry.
ns.Leaderboard = ns.Leaderboard or {}
local UI = ns.UI
local Util = ns.Util
local BankReview = {}
ns.Leaderboard.BankReview = BankReview

local ROWS, ROW_H = 14, 20
local WIDTH, HEIGHT = 740, 470
local LIST_TOP = 92
local TYPES = { ["bank.gold"] = true, ["bank.items"] = true }
local REFUSED = "Your rank can't review bank contributions. The guild master sets this under Settings > Permissions."
local EMPTY_TEXT = "No guild bank activity recorded yet. Entries appear after someone with Guildhearth opens the guild bank."
local NO_MATCH_TEXT = "No entries match these filters."
local PROMPT_TEXT = "Why doesn't this count? (optional)"
local NOTE_TEXT = "Unticked entries don't count toward the member's score. They still count toward the guild's bank totals."
local DEMO_TEXT = "Demo data is read-only. Turn it off with /gh lbdemo off to review real entries."
local MONTH_NAMES = { "January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December" }
-- x offset and width of each column
local COLS = {
  { key = "date", title = "Date", x = 34, w = 104 },
  { key = "char", title = "Character", x = 140, w = 100 },
  { key = "action", title = "Action", x = 242, w = 66 },
  { key = "amount", title = "Amount", x = 310, w = 176 },
  { key = "tab", title = "Tab", x = 488, w = 54 },
  { key = "status", title = "Status", x = 544, w = 180 },
}

BankReview.REFUSED = REFUSED

local panel -- built on first Open

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function services() return ns.services end
local function lb() return ns.leaderboard end

local function canReview()
  local s, l = services(), lb()
  local p = l and l.permissions
  return s ~= nil and p ~= nil and p:Can(s.playerChar, "bankreview") == true
end

local function isOfficer()
  local s = services()
  return s ~= nil and s.roster ~= nil and s.roster:IsOfficer(s.playerChar) == true
end

local function readOnly()
  local l = lb()
  return l ~= nil and l.demo == true
end

local function profiles()
  local l, s = lb(), services()
  return (l and l.demoProfile) or (s and s.profile)
end

local function tzNow()
  local s, l = services(), lb()
  if not (s and l) then return 0 end
  return ns.Scoring.Clock(l.config, s.compat, s.now()).tz or 0
end

-- Formatting ----------------------------------------------------------------------------

local function commas(n)
  local s = string.format("%d", math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

local function money(copper)
  copper = math.floor(math.abs(copper))
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = commas(g) .. " g" end
  if s > 0 then parts[#parts + 1] = s .. " s" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. " c" end
  return table.concat(parts, " ")
end

local function itemText(item)
  if item == nil then return "items" end
  if type(item) == "string" and Util.IsItemLink(item) then return item end
  return "[" .. Util.Escape(Util.ItemName(item)) .. "]"
end

local function monthLabel(ym)
  local y, m = tostring(ym):match("^(%d+)-(%d+)$")
  local name = MONTH_NAMES[tonumber(m) or 0]
  if not name then return tostring(ym) end
  return name .. " " .. y
end

local function tabLabel(tab)
  if tab == nil or tab == "money" then return "Money" end
  return "Tab " .. tostring(tab)
end

-- Who a row belongs to: its profile when the character is linked to one, else the character.
function BankReview.PlayerKey(row)
  if row.profile ~= nil then return "p:" .. tostring(row.profile) end
  return "c:" .. tostring(row.char)
end

local function playerLabel(key)
  local kind, id = key:match("^(%a):(.*)$")
  if kind == "p" and ns.LbConfig and profiles() then
    return Util.Escape(ns.LbConfig._displayName(profiles(), id))
  end
  return Util.Escape(Util.DisplayName(id))
end

local function statusText(row, ex)
  local text
  if row.counted then
    text = "counted"
  elseif row.why == "unpaired" then
    text = "not verified yet"
  elseif row.why == "excluded by an officer" then
    text = "excluded"
  else
    text = tostring(row.why or "not counted")
  end
  if ex and row.why ~= "excluded by an officer" then text = text .. ", excluded" end
  if ex and type(ex.reason) == "string" then text = text .. ": " .. Util.Escape(ex.reason) end
  return text
end

-- Data ----------------------------------------------------------------------------------

local function exclusions()
  local l = lb()
  local c = l and l.config
  if not (c and c.Exclusions) then return {} end
  return c:Exclusions() or {}
end

local function allRows()
  local l = lb()
  if not (l and l.ledger) then return {} end
  local rows = l.ledger:Query({ includeUncounted = true, types = TYPES }).rows or {}
  table.sort(rows, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return tostring(a.ref) < tostring(b.ref)
  end)
  return rows
end

function BankReview.Filter(rows, f, excl, tz)
  local out = {}
  f, excl = f or {}, excl or {}
  for _, row in ipairs(rows) do
    local ok = true
    if f.player and BankReview.PlayerKey(row) ~= f.player then ok = false end
    if ok and f.tab ~= nil then
      if f.tab == "money" then ok = row.tab == nil else ok = row.tab == f.tab end
    end
    if ok and f.month and ns.Scoring.MonthKey(row.at, tz) ~= f.month then ok = false end
    if ok and f.excludedOnly and not excl[row.ref] then ok = false end
    if ok then out[#out + 1] = row end
  end
  return out
end

local function playerItems(rows)
  local keys, seen = {}, {}
  for _, row in ipairs(rows) do
    local k = BankReview.PlayerKey(row)
    if not seen[k] then seen[k] = true; keys[#keys + 1] = { value = k, label = playerLabel(k) } end
  end
  table.sort(keys, function(a, b)
    if a.label ~= b.label then return a.label < b.label end
    return a.value < b.value
  end)
  table.insert(keys, 1, { value = false, label = "All players" })
  return keys
end

local function tabItems(rows)
  local tabs, seen, money_ = {}, {}, false
  for _, row in ipairs(rows) do
    if row.tab == nil then money_ = true
    elseif not seen[row.tab] then seen[row.tab] = true; tabs[#tabs + 1] = row.tab end
  end
  table.sort(tabs, function(a, b) return tostring(a) < tostring(b) end)
  local items = { { value = false, label = "All tabs" } }
  if money_ then items[#items + 1] = { value = "money", label = "Money" } end
  for _, t in ipairs(tabs) do items[#items + 1] = { value = t, label = tabLabel(t) } end
  return items
end

local function monthItems(rows, tz)
  local months, seen = {}, {}
  for _, row in ipairs(rows) do
    local ym = ns.Scoring.MonthKey(row.at, tz)
    if not seen[ym] then seen[ym] = true; months[#months + 1] = ym end
  end
  table.sort(months, function(a, b) return a > b end)
  local items = { { value = false, label = "All months" } }
  for _, ym in ipairs(months) do items[#items + 1] = { value = ym, label = monthLabel(ym) } end
  return items
end

-- Actions -------------------------------------------------------------------------------

local function setStatus(text)
  if panel then panel.status:SetText(text or "") end
end

local function apply(ref, excluded, reason)
  local l = lb()
  if not (l and canReview()) or readOnly() then
    setStatus(readOnly() and DEMO_TEXT or REFUSED)
    BankReview.Refresh()
    return false
  end
  local ok, err = l.config:SetExcluded(ref, excluded, reason)
  if ok then
    setStatus(excluded and "Entry excluded. It no longer counts toward the member's score."
      or "Entry counted again.")
  elseif err == "no permission" then
    setStatus(REFUSED)
  else
    setStatus("Couldn't save the change: " .. tostring(err or "not accepted") .. ".")
  end
  BankReview.Refresh()
  return ok
end

function BankReview.DoExclude(ref, reason) return apply(ref, true, reason) end
function BankReview.DoInclude(ref) return apply(ref, false) end

local function editBoxOf(dialog)
  if not dialog then return nil end
  return dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox()) or nil
end

if StaticPopupDialogs then
  StaticPopupDialogs["GUILDHEARTH_BANK_EXCLUDE"] = {
    text = PROMPT_TEXT,
    button1 = OKAY or "OK", button2 = CANCEL or "Cancel",
    hasEditBox = 1, maxLetters = 80,
    OnShow = function(self)
      UI.Try(function()
        local eb = editBoxOf(self)
        if eb then eb:SetText(""); eb:SetFocus() end
      end)
    end,
    OnAccept = function(self, ref)
      local eb = editBoxOf(self)
      UI.Try(BankReview.DoExclude, ref, eb and eb:GetText() or nil)
    end,
    EditBoxOnEnterPressed = function(eb, ref)
      local dialog = eb:GetParent()
      UI.Try(BankReview.DoExclude, ref, eb:GetText())
      if dialog then dialog:Hide() end
    end,
    EditBoxOnEscapePressed = function(eb)
      local dialog = eb:GetParent()
      if dialog then dialog:Hide() end
    end,
    OnCancel = function() UI.Try(BankReview.Refresh) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
  }
end

-- Unticking asks for a reason first; the box stays ticked until the prompt is accepted.
local function askExclude(ref)
  if StaticPopup_Show and StaticPopupDialogs and StaticPopupDialogs["GUILDHEARTH_BANK_EXCLUDE"] then
    StaticPopup_Show("GUILDHEARTH_BANK_EXCLUDE", nil, nil, ref)
  else
    BankReview.DoExclude(ref, nil)
  end
end

-- Panel ---------------------------------------------------------------------------------

local function render()
  local p = panel
  local maxOffset = math.max(0, #p.shown - ROWS)
  p.offset = math.max(0, math.min(p.offset, maxOffset))
  local tz, officer, ro = p.tz, isOfficer(), readOnly()
  for i, line in ipairs(p.lines) do
    local row = p.shown[p.offset + i]
    line.row = row
    if row then
      local ex = p.excl[row.ref]
      line.check:SetChecked(ex == nil)
      if ro then line.check:Disable() else line.check:Enable() end
      line.cells.date:SetText((date or os.date)("!%Y-%m-%d %H:%M", row.at + tz))
      line.cells.char:SetText(Util.Escape(Util.DisplayName(tostring(row.char))))
      line.cells.action:SetText(row.value < 0 and "withdrew" or "deposited")
      if row.type == "bank.gold" then
        line.cells.amount:SetText(money(row.value))
      else
        line.cells.amount:SetText(itemText(row.item) .. " x" .. commas(math.abs(row.value)))
      end
      line.cells.tab:SetText(tabLabel(row.tab))
      local status = statusText(row, ex)
      if ex and officer and type(ex.by) == "string" then
        status = status .. " (" .. Util.Escape(Util.DisplayName(ex.by)) .. ")"
      end
      line.cells.status:SetText(status)
      line:Show()
      line.check:Show()
    else
      line:Hide()
      line.check:Hide()
    end
  end
  if #p.rows == 0 then
    p.empty:SetText(EMPTY_TEXT); p.empty:Show()
  elseif #p.shown == 0 then
    p.empty:SetText(NO_MATCH_TEXT); p.empty:Show()
  else
    p.empty:Hide()
  end
  if #p.shown > ROWS then
    p.count:SetText(string.format("%d-%d of %d entries (scroll for more)", p.offset + 1,
      math.min(p.offset + ROWS, #p.shown), #p.shown))
  else
    p.count:SetText(string.format("%d entries", #p.shown))
  end
end

local function filterLabels()
  local p, f = panel, panel.filters
  p.playerBtn:SetText(f.player and playerLabel(f.player) or "All players")
  p.tabBtn:SetText(f.tab ~= nil and tabLabel(f.tab) or "All tabs")
  p.monthBtn:SetText(f.month and monthLabel(f.month) or "All months")
  p.excludedOnly:SetChecked(f.excludedOnly == true)
end

function BankReview.Refresh()
  local p = panel
  if not p then return end
  UI.Try(function()
    p.tz = tzNow()
    p.excl = exclusions()
    p.rows = allRows()
    p.shown = BankReview.Filter(p.rows, p.filters, p.excl, p.tz)
    filterLabels()
    if readOnly() then p.note:SetText(DEMO_TEXT) else p.note:SetText(NOTE_TEXT) end
    render()
  end)
end

local function onDataChanged()
  local p, s = panel, services()
  if not (p and s) or p.pending or not p.frame:IsShown() then return end
  p.pending = true
  s.after(0, function()
    p.pending = false
    if p.frame:IsShown() then BankReview.Refresh() end
  end)
end

local function makeLine(parent, i)
  local y = -LIST_TOP - (i - 1) * ROW_H
  local line = CreateFrame("Frame", nil, parent)
  line:SetPoint("TOPLEFT", 8, y)
  line:SetSize(WIDTH - 24, ROW_H)
  line:EnableMouse(true)
  line.cells = {}
  for _, c in ipairs(COLS) do
    local fs = UI.Text(line, "GameFontHighlightSmall", "")
    fs:SetPoint("LEFT", c.x - 8, 0)
    fs:SetWidth(c.w)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    line.cells[c.key] = fs
  end
  -- The full reason (and, for officers, who excluded it) in a tooltip: the column is narrow.
  on(line, "OnEnter", function(self)
    local row = self.row
    local ex = row and panel.excl[row.ref]
    if not (ex and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Excluded from the member's score")
    if type(ex.reason) == "string" then GameTooltip:AddLine(Util.Escape(ex.reason), 1, 1, 1, true) end
    if isOfficer() and type(ex.by) == "string" then
      GameTooltip:AddLine("By " .. Util.Escape(Util.DisplayName(ex.by)), 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
  end)
  on(line, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  check:SetSize(22, 22)
  check:SetPoint("TOPLEFT", 8, y + 1)
  on(check, "OnClick", function(self)
    local row = line.row
    if not row or readOnly() then BankReview.Refresh(); return end
    if self:GetChecked() then
      BankReview.DoInclude(row.ref)
    else
      self:SetChecked(true)
      askExclude(row.ref)
    end
  end)
  line.check = check
  return line
end

local function build()
  local f = UI.CreatePanel("GuildhearthBankReview", WIDTH, HEIGHT, "Bank review")
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhearthBankReview") end
  local p = { frame = f, filters = {}, offset = 0, lines = {}, rows = {}, shown = {}, excl = {}, tz = 0 }
  panel = p

  local function pickButton(label, x, w, items, set)
    local b
    b = UI.Button(f, label, w, function()
      UI.PickList(b, items(), function(v)
        set(v or nil)
        p.offset = 0
        BankReview.Refresh()
      end)
    end)
    b:SetPoint("TOPLEFT", x, -40)
    return b
  end
  p.playerBtn = pickButton("All players", 14, 150, function() return playerItems(p.rows) end,
    function(v) p.filters.player = v end)
  p.tabBtn = pickButton("All tabs", 170, 100, function() return tabItems(p.rows) end,
    function(v) p.filters.tab = v end)
  p.monthBtn = pickButton("All months", 276, 130, function() return monthItems(p.rows, p.tz) end,
    function(v) p.filters.month = v end)
  p.excludedOnly = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  p.excludedOnly:SetSize(24, 24)
  p.excludedOnly:SetPoint("TOPLEFT", 416, -39)
  local exLabel = UI.Text(f, "GameFontHighlightSmall", "Show excluded only")
  exLabel:SetPoint("LEFT", p.excludedOnly, "RIGHT", 2, 0)
  on(p.excludedOnly, "OnClick", function(self)
    p.filters.excludedOnly = self:GetChecked() == true or nil
    p.offset = 0
    BankReview.Refresh()
  end)

  for _, c in ipairs(COLS) do
    UI.Text(f, "GameFontNormalSmall", c.title):SetPoint("TOPLEFT", c.x + 8, -LIST_TOP + 16)
  end
  local counts = UI.Text(f, "GameFontNormalSmall", "Counts")
  counts:SetPoint("TOPLEFT", 6, -LIST_TOP + 16)

  local list = CreateFrame("Frame", nil, f)
  list:SetPoint("TOPLEFT", 8, -LIST_TOP)
  list:SetSize(WIDTH - 16, ROWS * ROW_H)
  list:EnableMouseWheel(true)
  on(list, "OnMouseWheel", function(_, delta)
    p.offset = p.offset - delta
    render()
  end)
  p.list = list
  for i = 1, ROWS do p.lines[i] = makeLine(f, i) end
  -- each row catches the wheel too, so scrolling works with the pointer over a row
  for _, line in ipairs(p.lines) do
    line:EnableMouseWheel(true)
    on(line, "OnMouseWheel", function(_, delta)
      p.offset = p.offset - delta
      render()
    end)
  end

  p.empty = UI.Text(f, "GameFontDisable", EMPTY_TEXT)
  p.empty:SetPoint("TOPLEFT", 14, -LIST_TOP - 8)
  p.empty:SetWidth(WIDTH - 40)
  p.empty:Hide()

  local bottom = -LIST_TOP - ROWS * ROW_H - 8
  p.count = UI.Text(f, "GameFontDisableSmall", "")
  p.count:SetPoint("TOPLEFT", 14, bottom)
  p.note = UI.Text(f, "GameFontDisableSmall", NOTE_TEXT)
  p.note:SetPoint("TOPLEFT", 14, bottom - 18)
  p.note:SetWidth(WIDTH - 40)
  p.status = UI.Text(f, "GameFontHighlightSmall", "")
  p.status:SetPoint("TOPLEFT", 14, bottom - 36)
  p.status:SetWidth(WIDTH - 40)

  if ns.Events then
    for _, event in ipairs({ "ObservationsChanged", "LeaderboardConfigChanged", "RosterRefreshed", "ProfilesChanged" }) do
      ns.Events:On(event, onDataChanged)
    end
  end
  return p
end

function BankReview.Open()
  if not (services() and lb()) then return false, UI.NO_GUILD_TEXT or "Join a guild to use Guildhearth" end
  if not canReview() then return false, REFUSED end
  if not panel then build() end
  panel.status:SetText("")
  panel.frame:Show()
  BankReview.Refresh()
  return true
end

-- For specs: the built panel, or nil.
function BankReview._panel() return panel end
