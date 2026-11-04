local ADDON, ns = ...

-- Settings tab, "Permissions" section: which guild ranks may do what. A grid with one row per
-- permission key and one column per guild rank (Roster:RankNames()), plus "Raid leader &
-- assistants" when any key allows it. The Guild Master column is always checked and disabled;
-- every other checkbox is enabled only for the guild master (rank 0), and only while demo mode
-- is off. Reset sets the grid back to guild master only; Save publishes it.
-- Below the grid, the newest 4 change history entries (UI.HistoryView.Lines; for those who may see it).
-- PermissionsView.Build(parent) -> view { refresh, cells, raid, ... }; sets the parent's height.
-- Reads ns.leaderboard.permissions on each refresh (the demo swaps it). No named globals.
local UI = ns.UI
local Util = ns.Util
local PermissionsView = {}
UI.PermissionsView = PermissionsView

local CAPTION = "Only the Guild Master can change these. Ranks come from the game, in rank order."
local RAID_LABEL = "Raid leader & assistants"
local MAX_COLS = 10
local WIDTH = 660
local LABEL_W = 190
local ROW_H = 26
local HEAD_H = 30
local HISTORY_ENTRIES = 4
local HISTORY_LINES = 6

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function perms()
  local l = ns.leaderboard
  return l and l.permissions
end

local function keys() return ns.Permissions and ns.Permissions.KEYS or {} end

local function rankNames()
  local s = ns.services
  local names = s and s.roster and s.roster.RankNames and s.roster:RankNames() or {}
  local out = {}
  for i = 1, math.min(#names, MAX_COLS) do out[i] = names[i] end
  if #out == 0 then out[1] = "Guild Master" end
  return out
end

local function defaultGrant() return { ranks = { [0] = true }, raidlead = false } end

function PermissionsView.Build(parent)
  if not ns.services then error("no guild services yet") end
  local view = { cells = {}, raid = {}, heads = {}, dirty = false }

  local caption = UI.Text(parent, "GameFontDisableSmall", CAPTION)
  caption:SetPoint("TOPLEFT", 4, 0)
  caption:SetWidth(WIDTH)

  local top = -20
  local gridTop = top - HEAD_H
  view.labels = {}
  -- A key's row (label and checkbox list), made the first time it is needed, so a key added
  -- with Permissions.AddKey after Build still gets one on the next refresh.
  local function ensureRow(i, def)
    if not view.cells[def.key] then
      local label = UI.Text(parent, "GameFontHighlight", def.label)
      label:SetWidth(LABEL_W - 8)
      view.labels[def.key] = label
      view.cells[def.key] = {}
    end
    local label = view.labels[def.key]
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", 4, gridTop - (i - 1) * ROW_H - 5)
    return view.cells[def.key]
  end
  for i, def in ipairs(keys()) do ensureRow(i, def) end

  local function markDirty() view.dirty = true end

  local function head(c)
    local h = view.heads[c]
    if not h then
      h = UI.Text(parent, "GameFontNormalSmall", "")
      h:SetJustifyH("CENTER")
      view.heads[c] = h
    end
    return h
  end

  local function checkbox()
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    on(cb, "OnClick", markDirty)
    return cb
  end

  local function cell(key, c)
    local row = view.cells[key]
    if not row[c] then row[c] = checkbox() end
    return row[c]
  end

  view.reset = UI.Button(parent, "Reset to guild master only", 190, function()
    local p = perms()
    if not (p and p:Editable()) then return end
    for i, def in ipairs(keys()) do
      for c, cb in pairs(ensureRow(i, def)) do cb:SetChecked(c == 1) end
      if view.raid[def.key] then view.raid[def.key]:SetChecked(false) end
    end
    view.dirty = true
    view.status:SetText("Press Save to apply.")
  end)
  view.save = UI.Button(parent, "Save", 80, function() view.doSave() end)
  view.status = UI.Text(parent, "GameFontDisableSmall", "")
  view.historyHead = UI.Text(parent, "GameFontNormal", "Recent changes")
  view.historyNote = UI.Text(parent, "GameFontDisableSmall", "(full list under Change history)")
  view.historyNote:SetPoint("LEFT", view.historyHead, "RIGHT", 8, 0)
  view.historyRows = {}
  for i = 1, HISTORY_LINES do
    local line = UI.Text(parent, "GameFontHighlightSmall", "")
    line:SetWidth(WIDTH)
    view.historyRows[i] = line
  end

  -- Everything below the grid moves down as rows are added; sets the parent's height.
  local function layoutBelow()
    local y = gridTop - #keys() * ROW_H - 8
    view.reset:ClearAllPoints(); view.reset:SetPoint("TOPLEFT", 4, y)
    view.save:ClearAllPoints(); view.save:SetPoint("TOPLEFT", 204, y)
    view.status:ClearAllPoints(); view.status:SetPoint("TOPLEFT", 4, y - 28)
    y = y - 52
    view.historyHead:ClearAllPoints(); view.historyHead:SetPoint("TOPLEFT", 4, y)
    for i, line in ipairs(view.historyRows) do
      line:ClearAllPoints(); line:SetPoint("TOPLEFT", 4, y - 20 - (i - 1) * 16)
    end
    parent:SetHeight(-(y - 20 - HISTORY_LINES * 16) + 8)
  end

  -- The map Publish takes, from the ticked boxes. Stored ranks that have no column (a rank the
  -- game no longer lists, or one past the shown names) are kept as they are.
  function view.collect()
    local map = {}
    local p = perms()
    local shown = #rankNames()
    for i, def in ipairs(keys()) do
      local ranks = {}
      for c, cb in pairs(ensureRow(i, def)) do
        if c <= shown and cb:IsShown() and cb:GetChecked() then ranks[c - 1] = true end
      end
      local stored = p and p:Grants(def.key) or defaultGrant()
      for r in pairs(stored.ranks) do
        if r >= shown then ranks[r] = true end
      end
      ranks[0] = true
      local raid = view.raid[def.key]
      map[def.key] = { ranks = ranks, raidlead = def.raidlead == true and raid ~= nil and raid:GetChecked() == true }
    end
    return map
  end

  function view.doSave()
    local p = perms()
    if not (p and p:Editable()) then return end
    local ok, err = p:Publish(view.collect())
    if ok then
      view.dirty = false
      view.status:SetText("Permissions saved.")
      view.refresh()
    else
      local l = ns.leaderboard
      local known = (l and l.demo) or (ns.Permissions and err == ns.Permissions.GM_ONLY)
      view.status:SetText(known and tostring(err) or ("Couldn't save the permissions: " .. tostring(err) .. "."))
    end
  end

  local function refreshHistory()
    local hv = UI.HistoryView
    local lines = hv and hv.Lines(HISTORY_ENTRIES)
    if lines then
      if #lines == 0 then lines[1] = "No changes recorded yet." end
      view.historyHead:Show(); view.historyNote:Show()
    else
      lines = {}
      view.historyHead:Hide(); view.historyNote:Hide()
    end
    view.historyLines = lines
    for i, row in ipairs(view.historyRows) do row:SetText(lines[i] or "") end
  end

  function view.refresh()
    local p = perms()
    local editable = p ~= nil and p:Editable() == true
    local names = rankNames()
    local raidCol = ns.Permissions and ns.Permissions.AnyRaidLead() or false
    local cols = #names + (raidCol and 1 or 0)
    local colW = math.max(40, math.min(90, math.floor((WIDTH - LABEL_W) / cols)))
    local function colX(c) return LABEL_W + (c - 1) * colW end

    for c = 1, math.max(#names + 1, #view.heads) do
      local h = view.heads[c]
      if c <= #names then
        h = head(c)
        h:SetText(Util.Escape(names[c]))
      elseif c == #names + 1 and raidCol then
        h = head(c)
        h:SetText(RAID_LABEL)
      end
      if h then
        if c <= cols then
          h:ClearAllPoints()
          h:SetPoint("TOPLEFT", colX(c), top)
          h:SetWidth(colW - 4)
          h:Show()
        else
          h:Hide()
        end
      end
    end

    for i, def in ipairs(keys()) do
      ensureRow(i, def)
      local g = p and p:Grants(def.key) or defaultGrant()
      local ry = gridTop - (i - 1) * ROW_H
      for c = 1, math.max(#names, MAX_COLS) do
        local cb = view.cells[def.key][c]
        if c <= #names then
          cb = cell(def.key, c)
          cb:ClearAllPoints()
          cb:SetPoint("TOPLEFT", colX(c) + math.floor((colW - 24) / 2), ry)
          cb:Show()
          if c == 1 then
            cb:SetChecked(true) -- the guild master always holds every permission
            cb:Disable()
          else
            if not view.dirty then cb:SetChecked(g.ranks[c - 1] == true) end
            if editable then cb:Enable() else cb:Disable() end
          end
        elseif cb then
          cb:Hide()
        end
      end
      local raid = view.raid[def.key]
      if raidCol and def.raidlead then
        if not raid then raid = checkbox(); view.raid[def.key] = raid end
        raid:ClearAllPoints()
        raid:SetPoint("TOPLEFT", colX(#names + 1) + math.floor((colW - 24) / 2), ry)
        raid:Show()
        if not view.dirty then raid:SetChecked(g.raidlead == true) end
        if editable then raid:Enable() else raid:Disable() end
      elseif raid then
        raid:Hide()
      end
    end

    if editable then view.reset:Show(); view.save:Show() else view.reset:Hide(); view.save:Hide() end
    if not editable then view.dirty = false end
    layoutBelow()
    refreshHistory()
  end

  view.refresh()
  return view
end
