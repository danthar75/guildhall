local ADDON, ns = ...

-- Leaderboard section of the Settings tab: the opt-out checkbox, the privacy note and the
-- activity weights. Officers edit and publish the weights; everyone else sees them read-only.
-- SettingsView.Build(parent) -> section { refresh }; sets the parent's height.
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

-- Task 16 switches this to a rank permission (guild master only by default).
local function canEditWeights()
  local s = services()
  return s ~= nil and s.roster:IsOfficer(s.playerChar) == true
end

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
  local sub = UI.Text(parent, "GameFontDisableSmall", "(officers only · applies to the whole guild)")
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
      section.status:SetText(err == "officers only" and "Only officers can publish weights."
        or ("Couldn't publish the weights: " .. tostring(err) .. "."))
    end
  end)
  section.publish:SetPoint("TOPLEFT", 4, y)
  section.error = UI.Text(parent, "GameFontNormalSmall", "")
  section.error:SetTextColor(1, 0.35, 0.35)
  section.error:SetPoint("LEFT", section.publish, "RIGHT", 10, 0)
  section.error:Hide()
  section.status = UI.Text(parent, "GameFontDisableSmall", "")
  section.status:SetPoint("TOPLEFT", 4, y - 28)
  section.changed = UI.Text(parent, "GameFontDisableSmall", "")
  section.changed:SetPoint("TOPLEFT", 4, y - 44)
  parent:SetHeight(-y + 66)

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
    section.changed:SetText(lastChanged())
  end
  section.refresh()
  return section
end
