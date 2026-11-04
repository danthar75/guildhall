local ADDON, ns = ...

-- Leaderboard section of the Settings tab: the opt-out checkbox, the privacy note and the
-- activity weights. Ranks granted "weights" (guild master only by default) edit and publish the
-- weights; everyone else sees them read-only. Officers, the guild master and anyone holding a
-- permission also see the shared change history (newest 20 entries, wheel scrolls). Ranks granted
-- "bankreview" get a "Bank review" button that opens ns.Leaderboard.BankReview.
-- SettingsView.Build(parent) -> section { refresh }; sets the parent's height.
-- SettingsView.Describe(e) -> plain-language lines for one history entry (PermissionsView uses it).
-- SettingsView.CanSeeHistory() -> bool.
-- No named globals.
ns.Leaderboard = ns.Leaderboard or {}
local UI = ns.UI
local Util = ns.Util
local SettingsView = {}
ns.Leaderboard.SettingsView = SettingsView

local MAX_WEIGHT = 1000 -- the same limit the Config validator applies
local ROW_H = 26
local WIDTH = 660
local PRIVACY_TEXT = "When this is off, your name isn't listed, but your deals and donations still count toward the guild total. "
  .. "Guildhall only shows totals to members, and each breakdown only to its player and officers. "
  .. "The records still travel between guildmates' clients so deals can be checked, so someone reading their "
  .. "own SavedVariables file could see them."
local BAD_WEIGHT_TEXT = "Use a number from 0 to 1000."
local GOLD, WHITE = { 1, 0.82, 0 }, { 1, 1, 1 }

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function services() return ns.services end
local function lb() return ns.leaderboard end

local function perms()
  local l = lb()
  return l and l.permissions
end

local function can(key)
  local s, p = services(), perms()
  return s ~= nil and p ~= nil and p:Can(s.playerChar, key) == true
end

local function canEditWeights() return can("weights") end

-- Who sees the change history: officers, the guild master (rank 0) and anyone granted a key.
local function canSeeHistory()
  local s = services()
  if s == nil then return false end
  if s.roster:IsOfficer(s.playerChar) == true then return true end
  if s.roster.RankIndex ~= nil and s.roster:RankIndex(s.playerChar) == 0 then return true end
  if perms() and ns.Permissions then
    for _, k in ipairs(ns.Permissions.KEYS) do if can(k.key) then return true end end
  end
  return false
end
SettingsView.CanSeeHistory = canSeeHistory

local HISTORY_ENTRIES = 20 -- newest entries shown
local HISTORY_ROWS = 8     -- lines visible at once; the mouse wheel scrolls the rest
local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
  "September", "October", "November", "December" }

local function weightLabel(id)
  for _, def in ipairs(ns.Activity.Types()) do
    if def.id == id then return def.label end
  end
  return tostring(id)
end

-- A rank's name for history lines: from the game or the roster cache, else "Rank N".
local function rankName(i)
  local s = services()
  local names = s and s.roster and s.roster.RankNames and s.roster:RankNames() or {}
  return names[i + 1] or ("Rank " .. tostring(i))
end

-- "Guild Master, Officer" (plus the raid leader column) for one stored grant.
local function grantText(g)
  if type(g) ~= "table" then return "default" end
  local parts = {}
  for _, r in ipairs(type(g.ranks) == "table" and g.ranks or {}) do parts[#parts + 1] = Util.Escape(rankName(r)) end
  if g.raidlead == true then parts[#parts + 1] = "Raid leader & assistants" end
  if #parts == 0 then return "nobody" end
  return table.concat(parts, ", ")
end

local function permLabel(key)
  return ns.Permissions and ns.Permissions.Label(key) or tostring(key)
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

-- Plain-language lines for one history entry (ASCII only): one per changed weight, one for a
-- month retake, or one per changed permission. Nothing for a kind this version doesn't know.
local function describe(e)
  local out = {}
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
    local keys, seen = {}, {}
    for _, map in ipairs({ e.before or {}, e.after or {} }) do
      for key in pairs(map) do
        if not seen[key] then seen[key] = true; keys[#keys + 1] = key end
      end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      out[#out + 1] = "Changed " .. Util.Escape(permLabel(key)) .. ": "
        .. grantText((e.before or {})[key]) .. " -> " .. grantText((e.after or {})[key])
    end
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
SettingsView.Describe = describe

-- A weight box accepts a plain decimal from 0 to 1000. Returns the number, or nil.
local function parseWeight(text)
  local t = Util.Trim(text or "")
  if not (t:match("^%d+%.?%d*$") or t:match("^%.%d+$")) then return nil end
  local n = tonumber(t)
  if n == nil or n < 0 or n > MAX_WEIGHT then return nil end
  return n
end

local function unitSuffix(def)
  if def.unit == "gold" then return " (per g)" end
  if def.unit == "items" then return " (per item)" end
  return ""
end

local function sameNumber(a, b) return math.abs(a - b) < 1e-9 end

local function lastChanged()
  local l = lb()
  local info = l and l.config:WeightsInfo()
  if not info then return "Weights are at their defaults." end
  local stamp = (date or os.date)("!%Y-%m-%d", info.at + (l.config:Tz() or 0))
  return "Last changed by " .. Util.Escape(Util.DisplayName(info.char)) .. ", " .. stamp
end

function SettingsView.Build(parent)
  local section = { boxes = {}, rows = {}, dirty = {} }
  local s = services()
  if not s then error("no guild services yet") end

  -- Opt-out ---------------------------------------------------------------------------
  local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  check:SetPoint("TOPLEFT", 0, 0)
  local checkLabel = UI.Text(parent, "GameFontHighlight", "Show me on the leaderboard")
  checkLabel:SetPoint("LEFT", check, "RIGHT", 4, 0)
  on(check, "OnClick", function(self)
    local svc = services()
    if not svc then return end
    svc.profile:SetHidden(not self:GetChecked())
    if ns.Boot and ns.Boot.PublishProfile then ns.Boot.PublishProfile() end
    if ns.Events and ns.Events.Fire then ns.Events:Fire("ProfilesChanged") end
  end)
  section.check = check

  local note = UI.Text(parent, "GameFontDisableSmall", PRIVACY_TEXT)
  note:SetPoint("TOPLEFT", 4, -32)
  note:SetWidth(WIDTH)
  note:SetJustifyH("LEFT")
  note:SetSpacing(2)

  -- Weights ---------------------------------------------------------------------------
  local y = -96
  local head = UI.Text(parent, "GameFontNormal", "Activity weights")
  head:SetPoint("TOPLEFT", 4, y)
  local sub = UI.Text(parent, "GameFontDisableSmall", "(set under Permissions · applies to the whole guild)")
  sub:SetPoint("LEFT", head, "RIGHT", 8, 0)
  y = y - 22
  for _, h in ipairs({ { "Activity", 4 }, { "Weight", 270 }, { "Default", 350 } }) do
    UI.Text(parent, "GameFontNormalSmall", h[1]):SetPoint("TOPLEFT", h[2], y)
  end
  y = y - 18

  local types = ns.Activity.Types()
  -- A box is dirty (an unpublished edit) while its value differs from the published weight.
  local function markDirty(def)
    local published = lb() and lb().config:Weights()[def.id] or def.weight
    local n = parseWeight(section.boxes[def.id]:GetText())
    section.dirty[def.id] = (n == nil or not sameNumber(n, published)) or nil
  end
  -- Does nothing for a non-officer: the boxes are hidden, and setting their text must not
  -- bring the Reset buttons back.
  local function recheck()
    if not canEditWeights() then return end
    local bad = false
    for _, def in ipairs(types) do
      local box, row = section.boxes[def.id], section.rows[def.id]
      local n = parseWeight(box:GetText())
      if n == nil then bad = true end
      local color = (n ~= nil and not sameNumber(n, def.weight)) and GOLD or WHITE
      box:SetTextColor(color[1], color[2], color[3])
      if row.reset then if n ~= nil and sameNumber(n, def.weight) then row.reset:Hide() else row.reset:Show() end end
    end
    if bad then section.error:SetText(BAD_WEIGHT_TEXT); section.error:Show() else section.error:SetText(""); section.error:Hide() end
    section.invalid = bad
    if section.publish then
      if bad then section.publish:Disable() else section.publish:Enable() end
    end
  end

  for i, def in ipairs(types) do
    local ry = y - (i - 1) * ROW_H
    local row = {}
    row.label = UI.Text(parent, "GameFontHighlight", def.label .. unitSuffix(def))
    row.label:SetPoint("TOPLEFT", 4, ry - 3)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(60, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(8)
    box:SetPoint("TOPLEFT", 270, ry)
    -- OnTextChanged also fires for our own SetText; only a user edit (second argument) is dirty.
    on(box, "OnTextChanged", function(_, userInput)
      if userInput then markDirty(def) end
      recheck()
    end)
    on(box, "OnEnterPressed", function(self) self:ClearFocus() end)
    on(box, "OnEscapePressed", function(self) self:ClearFocus() end)
    section.boxes[def.id] = box
    row.value = UI.Text(parent, "GameFontHighlight")
    row.value:SetPoint("TOPLEFT", 276, ry - 3)
    row.default = UI.Text(parent, "GameFontDisableSmall", "default " .. tostring(def.weight))
    row.default:SetPoint("TOPLEFT", 350, ry - 4)
    row.reset = UI.Button(parent, "Reset", 60, function()
      if not canEditWeights() then return end
      box:SetText(tostring(def.weight))
      markDirty(def)
    end)
    row.reset:SetPoint("TOPLEFT", 440, ry + 1)
    section.rows[def.id] = row
  end
  y = y - #types * ROW_H - 6

  local help = UI.Text(parent, "GameFontDisableSmall",
    "Weight 0 removes an activity from the overall score; its own board still shows.\n"
    .. "Changes reach every member's client and apply to all periods, including past ones.\n"
    .. "Bank rules come from Guild Info: [Guildhall donations=3,4] and [Guildhall bankexclude=0,1].")
  help:SetPoint("TOPLEFT", 4, y)
  help:SetWidth(WIDTH)
  help:SetJustifyH("LEFT")
  help:SetSpacing(2)
  y = y - 52

  section.publish = UI.Button(parent, "Publish weights", 130, function()
    if not canEditWeights() or section.invalid then return end
    local map = {}
    for _, def in ipairs(types) do map[def.id] = parseWeight(section.boxes[def.id]:GetText()) end
    local ok, err = lb().config:PublishWeights(map)
    if ok then
      section.dirty = {}
      section.status:SetText("Weights published.")
      section.refresh()
    else
      section.status:SetText(lb().demo and tostring(err) or err == "no permission" and "You don't have permission to publish weights."
        or ("Couldn't publish the weights: " .. tostring(err) .. "."))
    end
  end)
  section.publish:SetPoint("TOPLEFT", 4, y)
  section.bankReview = UI.Button(parent, "Bank review", 120, function()
    local br = ns.Leaderboard.BankReview
    if not br then return end
    local ok, err = br.Open()
    if not ok then section.status:SetText(tostring(err)) end
  end)
  section.bankReview:SetPoint("TOPLEFT", WIDTH - 120, y)
  section.bankReview:Hide()
  section.error = UI.Text(parent, "GameFontNormalSmall", "")
  section.error:SetTextColor(1, 0.35, 0.35)
  section.error:SetPoint("LEFT", section.publish, "RIGHT", 10, 0)
  section.error:Hide()
  section.status = UI.Text(parent, "GameFontDisableSmall", "")
  section.status:SetPoint("TOPLEFT", 4, y - 28)
  section.changed = UI.Text(parent, "GameFontDisableSmall", "")
  section.changed:SetPoint("TOPLEFT", 4, y - 44)

  -- Change history (officers and the guild master) ---------------------------------------
  y = y - 70
  section.historyHead = UI.Text(parent, "GameFontNormal", "Change history")
  section.historyHead:SetPoint("TOPLEFT", 4, y)
  section.historyHead:Hide()
  section.historyEmpty = UI.Text(parent, "GameFontDisableSmall", "No changes recorded yet.")
  section.historyEmpty:SetPoint("TOPLEFT", 4, y - 20)
  section.historyEmpty:Hide()
  section.historyLines, section.historyOffset = {}, 0
  local box = CreateFrame("Frame", nil, parent)
  box:SetSize(WIDTH, HISTORY_ROWS * 16)
  box:SetPoint("TOPLEFT", 4, y - 20)
  box:EnableMouseWheel(true)
  box:Hide()
  section.historyBox, section.historyRows = box, {}
  for i = 1, HISTORY_ROWS do
    local line = UI.Text(box, "GameFontHighlightSmall", "")
    line:SetPoint("TOPLEFT", 0, -(i - 1) * 16)
    line:SetWidth(WIDTH)
    line:SetJustifyH("LEFT")
    section.historyRows[i] = line
  end
  local function renderHistory()
    local maxOffset = math.max(0, #section.historyLines - HISTORY_ROWS)
    section.historyOffset = math.max(0, math.min(section.historyOffset, maxOffset))
    for i, line in ipairs(section.historyRows) do
      line:SetText(section.historyLines[section.historyOffset + i] or "")
    end
  end
  on(box, "OnMouseWheel", function(_, delta)
    section.historyOffset = section.historyOffset - delta
    renderHistory()
  end)
  y = y - 20 - HISTORY_ROWS * 16
  parent:SetHeight(-y + 66)

  local function refreshHistory()
    local l = lb()
    section.historyLines = {}
    if canSeeHistory() and l then
      local tz = l.config:Tz() or 0
      local entries = l.config:History()
      for i = 1, math.min(HISTORY_ENTRIES, #entries) do
        local e = entries[i]
        local stamp = (date or os.date)("!%Y-%m-%d %H:%M", e.at + tz)
        local mark = l.config:HistoryAuthorPermitted(e) and "" or " (no permission now)"
        for _, text in ipairs(describe(e)) do
          section.historyLines[#section.historyLines + 1] = stamp .. "  "
            .. Util.Escape(Util.DisplayName(e.by)) .. "  " .. text .. mark
        end
      end
      section.historyHead:Show()
      if #section.historyLines == 0 then section.historyEmpty:Show() else section.historyEmpty:Hide() end
      box:Show()
    else
      section.historyHead:Hide(); section.historyEmpty:Hide(); box:Hide()
    end
    renderHistory()
  end

  function section.refresh()
    local svc = services()
    if not svc then return end
    check:SetChecked(not svc.profile:IsHidden(svc.profile:Id()))
    local editable = canEditWeights()
    local weights = lb() and lb().config:Weights() or {}
    for _, def in ipairs(types) do
      local box, row = section.boxes[def.id], section.rows[def.id]
      local w = weights[def.id] or def.weight
      if not section.dirty[def.id] and not (box.HasFocus and box:HasFocus()) then box:SetText(tostring(w)) end
      row.value:SetText(tostring(w))
      local c = sameNumber(w, def.weight) and WHITE or GOLD
      row.value:SetTextColor(c[1], c[2], c[3])
      if editable then box:Show(); row.value:Hide() else box:Hide(); row.value:Show(); row.reset:Hide() end
    end
    if editable then section.publish:Show() else section.publish:Hide(); section.error:Hide() end
    if editable then recheck() end
    if can("bankreview") then section.bankReview:Show() else section.bankReview:Hide() end
    section.changed:SetText(lastChanged())
    refreshHistory()
  end
  section.refresh()
  return section
end
