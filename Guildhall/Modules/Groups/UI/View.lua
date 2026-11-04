local ADDON, ns = ...

-- Groups tab: the "Ready now" strip, then the Board (posts and calendar raids on the left, the
-- selected one's details on the right, UI/Details.lua) and History ("Mine": your own group credit
-- rows from the ledger, uncounted ones greyed with their reason; "Guild": verified clears).
-- View.Build(parent) -> view {Refresh, refresh}; 736 x 412 inside the tab, the same frame as the
-- Leaderboard tab. Times are server time. Refreshes when shown and, debounced to once a second
-- while visible, on GroupsChanged, ObservationsChanged and the leaderboard's config, roster and
-- profile events.
ns.Groups = ns.Groups or {}
local UI = ns.UI
local Util = ns.Util
local View = ns.Groups.View or {}
ns.Groups.View = View
local D -- ns.Groups.Details (UI/Details.lua loads first)

local TOP, H = 56, 336
local LIST_W, DETAIL_X, DETAIL_W = 300, 310, 426
local ROW_H, ROWS = 22, 14
local HIST_LINES, HIST_H = 16, 18
local READY_SLOTS, SLOT_W = 4, 124
local DEBOUNCE = 1
local GOLD, GRAY, TAN, RED = { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }, { 0.78, 0.73, 0.54 }, { 1, 0.35, 0.35 }

local EMPTY_TEXT = "No runs posted. Post one, or mark yourself Ready now so guildmates know."
local OFF_TEXT = "The group finder starts once the leaderboard is running."
local READY_WINDOWS = { 3600, 7200, 14400 }

-- Ledger and credit reasons, in plain words.
local WHY = {
  ["not verified"] = "no second Guildhall player saw it",
  ["not using Guildhall"] = "that character isn't linked to Guildhall",
  ["not a guild group"] = "not mostly guild members",
  ["waiting for the switch"] = "waiting for the spec switch",
  ["not permitted"] = "asked by someone without permission",
  ["already credited tonight"] = "already counted tonight",
  ["no verified kill yet"] = "no confirmed kill yet",
  ["excluded by an officer"] = "excluded by an officer",
}
local GROUP_TYPES = { "groups.dungeon", "groups.raidboss", "groups.raidclear", "groups.prepared", "groups.flex",
  "groups.signedup" }

local view -- the single built tab

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function services() return ns.services end
local function groups() return ns.groups end

-- Status line -------------------------------------------------------------------------------

local function say(text, isError)
  if not view then return end
  view.status:SetText(text or "")
  local c = isError and RED or TAN
  view.status:SetTextColor(c[1], c[2], c[3])
end

-- Ready now ---------------------------------------------------------------------------------

local function renderReady()
  local list = groups().svc:Ready()
  local now = D.Now()
  for i, slot in ipairs(view.ready.slots) do
    local e = list[i]
    if e then
      local hours = math.max(1, math.ceil((e.exp - now) / 3600))
      slot.text:SetText(D.NameOf(e.profile) .. " (" .. D.RoleText(e.roles) .. ") · " .. hours .. " h")
      D.Dot(slot.dot, D.Online(e.profile))
      slot.dot:Show()
      slot.text:Show()
    else
      slot.text:SetText("")
      slot.dot:Hide()
    end
  end
  view.ready.more:SetText(#list > READY_SLOTS and ("+" .. (#list - READY_SLOTS) .. " more") or "")
  view.ready.none:SetText(#list == 0 and "Nobody yet" or "")
end

local function myReady()
  local me = D.MyId()
  for _, e in ipairs(groups().svc:Ready()) do
    if e.profile == me then return e end
  end
end

local function readyItems()
  local items = {}
  for _, it in ipairs(D.RoleItems()) do items[#items + 1] = { label = it.label, value = { roles = it.value } } end
  for _, secs in ipairs(READY_WINDOWS) do
    items[#items + 1] = { label = "Free for " .. (secs / 3600) .. " h", value = { secs = secs } }
  end
  items[#items + 1] = { label = "Not ready", value = { clear = true } }
  return items
end

local function setReady(choice)
  local g, s = groups(), services()
  if not (g and s) then return end
  if choice.clear then
    local ok, err = g.svc:ClearReady()
    if ok or err == "not ready" then say("You're no longer marked ready.") else say(D.ErrorText(err), true) end
    View.Refresh()
    return
  end
  local mine = myReady()
  if choice.secs then view.readyFor = choice.secs end
  local roles = choice.roles or (mine and mine.roles) or D.PersonalRoles()
  local level = s.compat and s.compat.PlayerLevel and s.compat:PlayerLevel() or nil
  if not level then
    say("Your level can't be read right now. Try again in a moment.", true)
    return
  end
  local ok, err = g.svc:SetReady(roles, level, view.readyFor)
  if ok then
    say("Marked ready as " .. D.RoleText(roles) .. " for " .. math.floor(view.readyFor / 3600) .. " h.")
  else
    say(D.ErrorText(err), true)
  end
  View.Refresh()
end

-- Board -------------------------------------------------------------------------------------

-- Section headers and entries: Now posts (the service's order), then scheduled posts and calendar
-- events by start.
local function boardEntries()
  local g = groups()
  local now, sched = {}, {}
  for _, post in ipairs(g.svc:Posts()) do
    if type(post.d) == "table" and ns.Instances.Get(post.d.instance) then
      local e = { kind = "post", key = post.id, post = post, start = post.d.start }
      if post.d.start == nil then now[#now + 1] = e else sched[#sched + 1] = e end
    end
  end
  for _, ev in ipairs(g.calendar and g.calendar:Events() or {}) do
    if type(ev.title) == "string" and type(ev.start) == "number" then
      sched[#sched + 1] = { kind = "calendar", key = "cal|" .. ev.title .. "|" .. ev.start, ev = ev, start = ev.start }
    end
  end
  table.sort(sched, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.key < b.key
  end)
  local out = {}
  if #now > 0 then
    out[#out + 1] = { header = "NOW" }
    for _, e in ipairs(now) do out[#out + 1] = e end
  end
  if #sched > 0 then
    out[#out + 1] = { header = "SCHEDULED" }
    for _, e in ipairs(sched) do out[#out + 1] = e end
  end
  return out
end

local function rowText(e)
  if e.kind == "calendar" then
    return Util.Escape(e.ev.title) .. " · " .. D.ServerDate(e.start, "%a %H:%M"), "|cff9d9d9dCalendar|r"
  end
  local post = e.post
  local name = Util.Escape(ns.Instances.Get(post.d.instance).name)
  local tags = D.Tags(post, groups().svc:Filled(post))
  if e.start == nil then return name .. " · " .. D.NameOf(post.by), tags end
  return name .. " · " .. D.ServerDate(e.start, "%a %H:%M"), tags
end

local function selectedEntry(list)
  local first
  for _, e in ipairs(list) do
    if not e.header then
      if e.key == view.selected then return e end
      first = first or e
    end
  end
  return first
end

local function renderBoard()
  local list = boardEntries()
  view.offset = math.max(0, math.min(view.offset, #list - ROWS))
  local sel = selectedEntry(list)
  view.selected = sel and sel.key or nil
  for i, row in ipairs(view.rows) do
    local e = list[view.offset + i]
    row.entry = e and not e.header and e or false
    if not e then
      row:Hide()
    else
      if e.header then
        row.name:SetText(e.header)
        row.name:SetTextColor(TAN[1], TAN[2], TAN[3])
        row.tags:SetText("")
        row.sel:Hide()
      else
        local name, tags = rowText(e)
        row.name:SetText(name)
        row.name:SetTextColor(1, 1, 1)
        row.tags:SetText(tags)
        if e == sel then row.sel:Show() else row.sel:Hide() end
      end
      row:Show()
    end
  end
  if #list == 0 then view.empty:SetText(EMPTY_TEXT); view.empty:Show() else view.empty:Hide() end
  D.Show(sel)
end

-- History -----------------------------------------------------------------------------------

local function refInstance(ref)
  if type(ref) ~= "string" then return nil end
  local key = ref:match("^kill:([^:]+):") or ref:match("^prepared:([^:]+):") or ref:match("^signup:[^:]+:([^:]+):")
  return key and ns.Instances.Get(key) or nil
end

local function describe(row, inst, n)
  local short = inst and Util.Escape(inst.short) or "a run"
  local t = row.type
  if t == "groups.dungeon" then return "Cleared " .. short end
  if t == "groups.raidclear" then return "Full clear of " .. short end
  if t == "groups.raidboss" then return short .. ": " .. n .. (n == 1 and " boss" or " bosses") .. " killed" end
  if t == "groups.prepared" then return "Prepared for " .. short end
  if t == "groups.flex" then return "Switched spec when asked" end
  if t == "groups.signedup" then return "Signed up and showed up: " .. short end
  return short
end

-- Your own group credit rows, newest first; raid boss rows of one night are one line.
local function mineLines()
  local l, me = ns.leaderboard, D.MyId()
  local ledger = l and (l.realLedger or l.ledger)
  if not (ledger and me) then return {} end
  local types = {}
  for _, t in ipairs(GROUP_TYPES) do types[t] = true end
  local res = ledger:Query({ types = types, includeUncounted = true })
  local tz, lines, bosses = D.Tz(), {}, {}
  for _, row in ipairs(res.rows or {}) do
    if row.profile == me and types[row.type] then
      local inst = refInstance(row.ref)
      if row.type == "groups.raidboss" then
        local key = tostring(inst and inst.key) .. "|" .. ns.Scoring.DayKey(row.at, tz) .. "|"
          .. tostring(row.counted) .. "|" .. tostring(row.why)
        local line = bosses[key]
        if line then
          line.n = line.n + 1
          line.at = math.max(line.at, row.at)
        else
          line = { row = row, inst = inst, n = 1, at = row.at }
          bosses[key] = line
          lines[#lines + 1] = line
        end
      else
        lines[#lines + 1] = { row = row, inst = inst, n = 1, at = row.at }
      end
    end
  end
  table.sort(lines, function(a, b) return a.at > b.at end)
  local out = {}
  for _, line in ipairs(lines) do
    local row = line.row
    local text = describe(row, line.inst, line.n)
    if not row.counted then text = text .. ", " .. (WHY[row.why] or "not counted") end
    out[#out + 1] = { at = line.at, text = text, gray = not row.counted }
  end
  return out
end

local function namesText(chars)
  local names = {}
  for i, ch in ipairs(chars) do names[i] = Util.Escape(Util.DisplayName(ch)) end
  if #names == 0 then return "the guild" end
  if #names == 1 then return names[1] end
  if #names == 2 then return names[1] .. " and " .. names[2] end
  return names[1] .. ", " .. names[2] .. " and " .. (#names - 2) .. " more"
end

-- Verified clears with a guild majority, newest first.
local function guildLines()
  local l, s = ns.leaderboard, services()
  local obs = l and l.observations
  if not obs then return {} end
  local out = {}
  for _, c in ipairs(ns.Groups.Credit.Clears(obs:List("kill"), s and s.roster)) do
    local inst = ns.Instances.Get(c.instance)
    local text = Util.Escape(inst.short) .. " cleared by " .. namesText(c.names)
    if c.dur then text = text .. ", " .. math.floor(c.dur / 60 + 0.5) .. " min" end
    out[#out + 1] = { at = c.at, text = text }
  end
  return out
end

local function renderHistory()
  local mine = view.hist.which == "mine"
  view.hist.title:SetText(mine and "Your last runs" or "Recent guild clears")
  local lines = mine and mineLines() or guildLines()
  for i, line in ipairs(view.hist.lines) do
    local e = lines[i]
    if e then
      line.date:SetText(D.ServerDate(e.at, "%m-%d %H:%M"))
      line.text:SetText(e.text)
      local c = e.gray and GRAY or { 1, 1, 1 }
      line.text:SetTextColor(c[1], c[2], c[3])
      line:Show()
    else
      line:Hide()
    end
  end
  if #lines == 0 then
    view.hist.empty:SetText(mine and "No runs yet. Finished runs, raid nights and spec switches show here."
      or "No verified clears yet.")
    view.hist.empty:Show()
  else
    view.hist.empty:Hide()
  end
  if mine then view.mineBtn:LockHighlight(); view.guildBtn:UnlockHighlight()
  else view.guildBtn:LockHighlight(); view.mineBtn:UnlockHighlight() end
end

-- Refresh -----------------------------------------------------------------------------------

local function showTab()
  local board = view.tab == "board"
  for _, w in ipairs({ view.list, view.detail }) do if board then w:Show() else w:Hide() end end
  for _, w in ipairs({ view.hist.panel, view.mineBtn, view.guildBtn }) do if board then w:Hide() else w:Show() end end
  if board then view.boardBtn:LockHighlight(); view.historyBtn:UnlockHighlight()
  else view.historyBtn:LockHighlight(); view.boardBtn:UnlockHighlight() end
end

function View.Refresh()
  if not view then return end
  local s = services()
  view.lastAt = s and s.now() or 0
  UI.Try(function()
    showTab()
    if not (groups() and s) then
      view.off:SetText(OFF_TEXT)
      view.off:Show()
      view.list:Hide(); view.detail:Hide(); view.hist.panel:Hide()
      return
    end
    view.off:Hide()
    renderReady()
    if view.tab == "board" then renderBoard() else renderHistory() end
  end)
end

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

-- Build -------------------------------------------------------------------------------------

local function makeRow(parent, i)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(LIST_W - 6, ROW_H)
  row:SetPoint("TOPLEFT", 3, -4 - (i - 1) * ROW_H)
  row:RegisterForClicks("LeftButtonUp")
  row.entry = false
  row.sel = row:CreateTexture(nil, "BACKGROUND")
  row.sel:SetAllPoints(row)
  row.sel:SetColorTexture(0.23, 0.18, 0.10, 0.9)
  row.sel:Hide()
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(row)
  hl:SetColorTexture(1, 1, 1, 0.08)
  row.name = UI.Text(row, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", 6, 0)
  row.name:SetWidth(178)
  row.name:SetJustifyH("LEFT")
  if row.name.SetWordWrap then row.name:SetWordWrap(false) end
  row.tags = UI.Text(row, "GameFontNormalSmall")
  row.tags:SetPoint("RIGHT", -4, 0)
  row.tags:SetWidth(100)
  row.tags:SetJustifyH("RIGHT")
  if row.tags.SetWordWrap then row.tags:SetWordWrap(false) end
  on(row, "OnClick", function(self)
    if not self.entry then return end
    view.selected = self.entry.key
    view.rosterOffset = 0
    say(nil)
    View.Refresh()
  end)
  row:Hide()
  return row
end

local function setTab(tab)
  view.tab = tab
  say(nil)
  View.Refresh()
end

local function buildReady(parent)
  local r = { slots = {} }
  local label = UI.Text(parent, "GameFontNormal", "Ready now:")
  label:SetPoint("TOPLEFT", 0, -4)
  label:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  for i = 1, READY_SLOTS do
    local x = 76 + (i - 1) * SLOT_W
    local slot = {}
    slot.dot = parent:CreateTexture(nil, "ARTWORK")
    slot.dot:SetSize(8, 8)
    slot.dot:SetPoint("TOPLEFT", x, -8)
    slot.dot:Hide()
    slot.text = UI.Text(parent, "GameFontHighlightSmall")
    slot.text:SetPoint("TOPLEFT", x + 12, -6)
    slot.text:SetWidth(SLOT_W - 16)
    slot.text:SetJustifyH("LEFT")
    if slot.text.SetWordWrap then slot.text:SetWordWrap(false) end
    r.slots[i] = slot
  end
  r.none = UI.Text(parent, "GameFontDisableSmall")
  r.none:SetPoint("TOPLEFT", 76, -6)
  r.more = UI.Text(parent, "GameFontNormalSmall")
  r.more:SetPoint("TOPLEFT", 76 + READY_SLOTS * SLOT_W, -6)
  r.more:SetWidth(50)
  r.more:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
  return r
end

function View.Build(parent)
  D = ns.Groups.Details
  view = { parent = parent, tab = "board", offset = 0, rows = {}, lastAt = 0, readyFor = 7200,
    rosterOffset = 0, clPick = {}, ticks = {} }

  view.ready = buildReady(parent)
  view.readyBtn = UI.Button(parent, "I'm ready now", 110, function()
    local mine = myReady()
    UI.PickList(view.readyBtn, readyItems(), function(choice) setReady(choice) end)
  end)
  view.readyBtn:SetPoint("TOPRIGHT", 0, 0)

  view.boardBtn = UI.Button(parent, "Board", 70, function() setTab("board") end)
  view.boardBtn:SetPoint("TOPLEFT", 0, -28)
  view.historyBtn = UI.Button(parent, "History", 70, function() setTab("history") end)
  view.historyBtn:SetPoint("TOPLEFT", 74, -28)
  view.mineBtn = UI.Button(parent, "Mine", 60, function() view.hist.which = "mine"; View.Refresh() end)
  view.mineBtn:SetPoint("TOPLEFT", 170, -28)
  view.guildBtn = UI.Button(parent, "Guild", 60, function() view.hist.which = "guild"; View.Refresh() end)
  view.guildBtn:SetPoint("TOPLEFT", 234, -28)
  local new = UI.Button(parent, "+ New post", 100, function()
    local form = ns.Groups.Form
    if form and form.Open then form.Open() else say("The post form isn't available in this version.", true) end
  end)
  new:SetPoint("TOPRIGHT", 0, -28)

  -- Board: the list on the left.
  local list = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  list:SetPoint("TOPLEFT", 0, -TOP)
  list:SetSize(LIST_W, H)
  UI.ApplyBackdrop(list, 0.6)
  view.list = list
  for i = 1, ROWS do view.rows[i] = makeRow(list, i) end
  view.empty = UI.Text(list, "GameFontDisable")
  view.empty:SetPoint("TOPLEFT", 12, -12)
  view.empty:SetWidth(LIST_W - 24)
  view.empty:Hide()
  list:EnableMouseWheel(true)
  on(list, "OnMouseWheel", function(_, delta)
    view.offset = view.offset - delta
    View.Refresh()
  end)

  -- Board: details on the right.
  local det = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  det:SetPoint("TOPLEFT", DETAIL_X, -TOP)
  det:SetSize(DETAIL_W, H)
  UI.ApplyBackdrop(det, 0.6)
  view.detail = det
  view.say = say
  view.refresh = function() View.Refresh() end
  D.Build(view, det, DETAIL_W)

  -- History: one full-width panel.
  local hist = { which = "mine", lines = {} }
  hist.panel = CreateFrame("Frame", nil, parent, UI.BACKDROP_TEMPLATE)
  hist.panel:SetPoint("TOPLEFT", 0, -TOP)
  hist.panel:SetSize(736, H)
  UI.ApplyBackdrop(hist.panel, 0.6)
  hist.title = UI.Text(hist.panel, "GameFontNormal")
  hist.title:SetPoint("TOPLEFT", 12, -10)
  hist.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  for i = 1, HIST_LINES do
    local line = CreateFrame("Frame", nil, hist.panel)
    line:SetSize(712, HIST_H)
    line:SetPoint("TOPLEFT", 12, -32 - (i - 1) * HIST_H)
    line.date = UI.Text(line, "GameFontNormalSmall")
    line.date:SetPoint("LEFT", 0, 0)
    line.date:SetWidth(84)
    line.date:SetJustifyH("LEFT")
    line.date:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
    line.text = UI.Text(line, "GameFontHighlightSmall")
    line.text:SetPoint("LEFT", 90, 0)
    line.text:SetWidth(620)
    line.text:SetJustifyH("LEFT")
    if line.text.SetWordWrap then line.text:SetWordWrap(false) end
    line:Hide()
    hist.lines[i] = line
  end
  hist.empty = UI.Text(hist.panel, "GameFontDisable")
  hist.empty:SetPoint("TOPLEFT", 12, -34)
  hist.empty:SetWidth(700)
  hist.panel:Hide()
  view.hist = hist

  view.off = UI.Text(parent, "GameFontDisable")
  view.off:SetPoint("TOPLEFT", 12, -TOP - 12)
  view.off:Hide()
  view.status = UI.Text(parent, "GameFontNormalSmall")
  view.status:SetPoint("TOPLEFT", 2, -(TOP + H + 4))
  view.status:SetWidth(730)
  view.status:SetJustifyH("LEFT")

  if ns.Events and not View.listening then
    View.listening = true
    for _, event in ipairs({ "GroupsChanged", "ObservationsChanged", "LeaderboardConfigChanged", "RosterRefreshed",
      "ProfilesChanged" }) do
      ns.Events:On(event, onDataChanged)
    end
  end

  view.Refresh = function() View.Refresh() end
  view.refresh = view.Refresh
  return view
end
