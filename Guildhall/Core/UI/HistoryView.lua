local ADDON, ns = ...

-- Settings tab, "Change history" sub-tab: the shared change history kept in core.config (LbConfig
-- history records), newest first. Each row: the time, the author with their rank name in brackets,
-- and a plain-language line (ASCII only). Officers, the guild master (rank 0) and anyone holding a
-- permission see it; other members see NO_ACCESS. The mouse wheel scrolls the list.
-- HistoryView.Describe(e) -> plain-language lines for one history entry.
-- HistoryView.CanSee() -> bool.
-- HistoryView.Lines(max) -> the rendered rows of the newest `max` entries, or nil when not visible.
-- HistoryView.Build(parent) -> view { refresh, lines, rows, offset, note, empty, box }.
-- Reads ns.services, ns.leaderboard and ns.Permissions on each refresh. No named globals.
local UI = ns.UI
local Util = ns.Util
local HistoryView = {}
UI.HistoryView = HistoryView

local NO_ACCESS = "Only officers and the guild master can see the change history."
HistoryView.NO_ACCESS = NO_ACCESS
local CAPTION = "Changes to permissions, checklists, leaderboard weights, month retakes and bank reviews, newest first."
local RAID_LABEL = "Raid leader & assistants"
local MAX_ENTRIES = 200 -- newest entries rendered
local ROWS = 22         -- lines visible at once; the mouse wheel scrolls the rest
local ROW_H = 16
local WIDTH = 680
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December" }

local function services() return ns.services end
local function lb() return ns.leaderboard end

local function can(key)
  local s, l = services(), lb()
  local p = l and l.permissions
  return s ~= nil and p ~= nil and p:Can(s.playerChar, key) == true
end

-- Who sees the change history: officers, the guild master (rank 0) and anyone granted a key.
function HistoryView.CanSee()
  local s = services()
  if s == nil or s.roster == nil then return false end
  if s.roster.IsOfficer and s.roster:IsOfficer(s.playerChar) == true then return true end
  if s.roster.RankIndex ~= nil and s.roster:RankIndex(s.playerChar) == 0 then return true end
  local l = lb()
  if l and l.permissions and ns.Permissions then
    for _, k in ipairs(ns.Permissions.KEYS) do if can(k.key) then return true end end
  end
  return false
end

local function weightLabel(id)
  for _, def in ipairs(ns.Activity and ns.Activity.Types() or {}) do
    if def.id == id then return def.label end
  end
  return tostring(id)
end

local function rankNames()
  local s = services()
  local r = s and s.roster
  return r and r.RankNames and r:RankNames() or {}
end

-- A rank's name for history lines: from the game or the roster cache, else "Rank N".
local function rankName(i)
  return rankNames()[i + 1] or ("Rank " .. tostring(i))
end

local function permLabel(key)
  return ns.Permissions and ns.Permissions.Label(key) or tostring(key)
end

-- One side of a permissions entry as a rank set and a raidlead flag; a missing grant is the
-- default (the guild master only).
local function grantSet(g)
  local set = { [0] = true }
  if type(g) == "table" then
    for _, r in ipairs(type(g.ranks) == "table" and g.ranks or {}) do
      if type(r) == "number" then set[r] = true end
    end
  end
  return set, type(g) == "table" and g.raidlead == true
end

local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- "Permission <label>: added <rank>" / "removed <rank>", one line per rank (and the raid leader).
local function describePerms(e, out)
  local before = type(e.before) == "table" and e.before or {}
  local after = type(e.after) == "table" and e.after or {}
  local keys, seen = {}, {}
  for _, map in ipairs({ before, after }) do
    for key in pairs(map) do
      if not seen[key] then seen[key] = true; keys[#keys + 1] = tostring(key) end
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local head = "Permission " .. Util.Escape(permLabel(key)) .. ": "
    local bset, braid = grantSet(before[key])
    local aset, araid = grantSet(after[key])
    for _, r in ipairs(sortedKeys(aset)) do
      if not bset[r] then out[#out + 1] = head .. "added " .. Util.Escape(rankName(r)) end
    end
    for _, r in ipairs(sortedKeys(bset)) do
      if not aset[r] then out[#out + 1] = head .. "removed " .. Util.Escape(rankName(r)) end
    end
    if araid and not braid then out[#out + 1] = head .. "added " .. RAID_LABEL end
    if braid and not araid then out[#out + 1] = head .. "removed " .. RAID_LABEL end
  end
end

-- "Bob, 50g deposit" for a bank contribution ref, from the ledger the client has now; nil once
-- the observation behind it is gone. The ref -> contribution map is rebuilt only when the
-- ledger's cached list changes.
local refCache = { list = nil, map = nil }
local function bankEntryText(ref)
  local l = lb()
  local ledger = l and l.ledger
  if not (ledger and ledger.Contributions) then return nil end
  local ok, list = pcall(ledger.Contributions, ledger)
  if not ok or type(list) ~= "table" then return nil end
  if refCache.list ~= list then
    local map = {}
    for _, c in ipairs(list) do if c.ref ~= nil then map[c.ref] = c end end
    refCache.list, refCache.map = list, map
  end
  local c = refCache.map[ref]
  if not c or type(c.value) ~= "number" then return nil end
  local amount
  if c.type == "bank.gold" then
    local copper = math.abs(c.value)
    if copper >= 10000 then amount = math.floor(copper / 10000) .. "g"
    elseif copper >= 100 then amount = math.floor(copper / 100) .. "s"
    else amount = copper .. "c" end
  else
    local item = c.item
    if type(item) == "string" and Util.IsItemLink(item) then
      amount = item
    else
      amount = "[" .. Util.Escape(Util.ItemName(item or "items")) .. "]"
    end
    amount = amount .. " x" .. math.abs(c.value)
  end
  return Util.Escape(Util.DisplayName(tostring(c.char))) .. ", " .. amount
    .. (c.value < 0 and " withdrawal" or " deposit")
end

local function itemText(id)
  local name = type(GetItemInfo) == "function" and GetItemInfo(id) or nil
  if type(name) == "string" and name ~= "" then return Util.Escape(name) end
  return "item " .. tostring(id)
end

-- Item counts of a checklist side by item id, plus the other lines as "enchants" / "manual: text".
local function checklistLines(side)
  local items, others = {}, {}
  for _, l in ipairs(type(side) == "table" and type(side.lines) == "table" and side.lines or {}) do
    if l.kind == "item" then items[l.item] = l.count
    elseif l.kind == "enchants" then others["enchants"] = true
    elseif l.kind == "manual" then others["note: " .. tostring(l.text)] = true end
  end
  return items, others
end

local function describeChecklist(e, out)
  local b = type(e.before) == "table" and e.before or {}
  local a = type(e.after) == "table" and e.after or {}
  local name = Util.Escape(tostring(a.name or b.name or e.key or "?"))
  if a.deleted == true and b.deleted ~= true then
    out[#out + 1] = "Deleted checklist " .. name
  elseif b.deleted == true and a.deleted == false then
    out[#out + 1] = "Restored checklist " .. name
  end
  if a.default == true and b.default ~= true then
    out[#out + 1] = "Made checklist " .. name .. " the default"
  end
  if a.name ~= nil and b.name ~= nil and a.name ~= b.name then
    out[#out + 1] = "Renamed checklist " .. Util.Escape(b.name) .. " -> " .. Util.Escape(a.name)
  end
  if a.lines ~= nil or b.lines ~= nil then
    local bi, bo = checklistLines(b)
    local ai, ao = checklistLines(a)
    local ids, seen = {}, {}
    for _, map in ipairs({ bi, ai }) do
      for id in pairs(map) do if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      if bi[id] ~= ai[id] then
        out[#out + 1] = "Changed checklist " .. name .. ": " .. itemText(id) .. " "
          .. (bi[id] and tostring(bi[id]) or "none") .. " -> " .. (ai[id] and tostring(ai[id]) or "none")
      end
    end
    local texts, tseen = {}, {}
    for _, map in ipairs({ bo, ao }) do
      for t in pairs(map) do if not tseen[t] then tseen[t] = true; texts[#texts + 1] = t end end
    end
    table.sort(texts)
    for _, t in ipairs(texts) do
      if bo[t] ~= ao[t] then
        out[#out + 1] = "Changed checklist " .. name .. ": " .. Util.Escape(t) .. " " .. (bo[t] and "present" or "none")
          .. " -> " .. (ao[t] and "present" or "none")
      end
    end
  end
end

-- Plain-language lines for one history entry (ASCII only). Nothing for a kind this version
-- doesn't know.
function HistoryView.Describe(e)
  local out = {}
  if type(e) ~= "table" then return out end
  if e.what == "weights" then
    local ids, seen = {}, {}
    for _, map in ipairs({ e.before or {}, e.after or {} }) do
      for id in pairs(map) do
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
      end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local was, now = (e.before or {})[id], (e.after or {})[id]
      if was ~= now then
        out[#out + 1] = "Leaderboard weight " .. Util.Escape(weightLabel(id)) .. ": "
          .. (was ~= nil and tostring(was) or "default") .. " -> " .. (now ~= nil and tostring(now) or "removed")
      end
    end
  elseif e.what == "month" then
    local y, m = tostring(e.key):match("^(%d+)-(%d+)$")
    local name = MONTHS[tonumber(m or 0)]
    if name then out[#out + 1] = "Retook " .. name .. " " .. y .. " top 5" end
  elseif e.what == "perms" then
    describePerms(e, out)
  elseif e.what == "checklist" then
    describeChecklist(e, out)
  elseif e.what == "bank" then
    local a = type(e.after) == "table" and e.after or {}
    local where = " (" .. (bankEntryText(e.key) or Util.Escape(tostring(e.key))) .. ")"
    local reason = type(a.reason) == "string" and (": " .. Util.Escape(a.reason)) or ""
    if a.excluded == true then
      out[#out + 1] = "Excluded a bank entry" .. where .. reason
    elseif a.excluded == false then
      out[#out + 1] = "Counted a bank entry again" .. where
    elseif reason ~= "" then
      out[#out + 1] = "Changed the reason for an excluded bank entry" .. where .. reason
    else
      out[#out + 1] = "Removed the reason for an excluded bank entry" .. where
    end
  end
  return out
end

-- "Dor [Officer]", or just "Dor" when the author's rank is unknown (they left the guild).
local function author(char)
  local s = services()
  local name = Util.Escape(Util.DisplayName(tostring(char)))
  local r = s and s.roster
  local rank = r and r.RankIndex and r:RankIndex(char)
  if type(rank) ~= "number" then return name end
  return name .. " [" .. Util.Escape(rankName(rank)) .. "]"
end

function HistoryView.Lines(max)
  local l = lb()
  local config = l and l.config
  if not (config and config.History and HistoryView.CanSee()) then return nil end
  local tz = config.Tz and config:Tz() or 0
  local entries = config:History()
  local lines = {}
  for i = 1, math.min(max or MAX_ENTRIES, #entries) do
    local e = entries[i]
    local stamp = (date or os.date)("!%Y-%m-%d %H:%M", (tonumber(e.at) or 0) + tz)
    local mark = (config.HistoryAuthorPermitted == nil or config:HistoryAuthorPermitted(e)) and ""
      or " (no permission now)"
    local who = author(e.by)
    for _, text in ipairs(HistoryView.Describe(e)) do
      lines[#lines + 1] = stamp .. "  " .. who .. "  " .. text .. mark
    end
  end
  return lines
end

function HistoryView.Build(parent)
  local view = { lines = {}, rows = {}, offset = 0 }

  view.caption = UI.Text(parent, "GameFontDisableSmall", CAPTION)
  view.caption:SetPoint("TOPLEFT", 4, 0)
  view.caption:SetWidth(WIDTH)

  view.note = UI.Text(parent, "GameFontDisable", NO_ACCESS)
  view.note:SetPoint("TOPLEFT", 4, -24)
  view.note:Hide()
  view.empty = UI.Text(parent, "GameFontDisable", "No changes recorded yet.")
  view.empty:SetPoint("TOPLEFT", 4, -24)
  view.empty:Hide()

  local box = CreateFrame("Frame", nil, parent)
  box:SetSize(WIDTH, ROWS * ROW_H)
  box:SetPoint("TOPLEFT", 4, -24)
  box:EnableMouseWheel(true)
  box:Hide()
  view.box = box
  for i = 1, ROWS do
    local line = UI.Text(box, "GameFontHighlightSmall", "")
    line:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    line:SetWidth(WIDTH)
    line:SetJustifyH("LEFT")
    if line.SetWordWrap then line:SetWordWrap(false) end
    view.rows[i] = line
  end
  if parent.SetHeight then parent:SetHeight(24 + ROWS * ROW_H + 8) end

  local function render()
    local maxOffset = math.max(0, #view.lines - ROWS)
    view.offset = math.max(0, math.min(view.offset, maxOffset))
    for i, line in ipairs(view.rows) do line:SetText(view.lines[view.offset + i] or "") end
  end
  box:SetScript("OnMouseWheel", function(_, delta)
    UI.Try(function()
      view.offset = view.offset - delta
      render()
    end)
  end)

  function view.refresh()
    local lines = HistoryView.Lines(MAX_ENTRIES)
    if lines then
      view.lines = lines
      view.note:Hide()
      box:Show()
      if #lines == 0 then view.empty:Show() else view.empty:Hide() end
    else
      view.lines = {}
      view.note:Show()
      view.empty:Hide()
      box:Hide()
    end
    render()
  end

  return view
end
