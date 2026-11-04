local ADDON, ns = ...

-- Consent dialog: one checkbox per character (checked = share/link). Never sends anything;
-- the caller decides what to do with the excluded list.
-- Consent:Show(chars, onDone(excludedArray), initiallyExcluded?, guildKey?) where initiallyExcluded
-- is a set {name = true} used to pre-uncheck boxes (e.g. when changing an earlier choice) and
-- guildKey names the guild that will see the linked characters.
local UI = ns.UI
local Consent = {}
UI.Consent = Consent

local ROW = 24
local TEXT = "Guildhall links your characters so guildmates can reach you on whichever one is online. Uncheck any you don't want shared."
local GUILD_TEXT = "Guildhall links your characters in %s so guildmates there can reach you on whichever one is online. Only characters in %s are listed. Uncheck any you don't want shared."

local frame, rows, onDone, names

local function build()
  if frame then return end
  frame = UI.CreatePanel(nil, 420, 200, "Guildhall: link your characters")
  frame.close:Hide() -- only OK finishes the dialog
  frame:SetFrameStrata("FULLSCREEN_DIALOG")

  local text = UI.Text(frame, "GameFontHighlight", TEXT)
  text:SetPoint("TOPLEFT", 16, -40)
  text:SetWidth(388)
  frame.text = text

  frame.list = CreateFrame("Frame", nil, frame)
  frame.list:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -10)
  frame.list:SetSize(388, ROW)

  rows = {}

  local ok = UI.Button(frame, "OK", 100, function()
    local excluded = {}
    for i, name in ipairs(names or {}) do
      if not rows[i].check:GetChecked() then excluded[#excluded + 1] = name end
    end
    local cb = onDone
    onDone = nil
    frame:Hide()
    if cb then cb(excluded) end
  end)
  ok:SetPoint("BOTTOM", 0, 14)
end

local function row(i)
  local r = rows[i]
  if r then return r end
  r = {}
  r.check = CreateFrame("CheckButton", nil, frame.list, "UICheckButtonTemplate")
  r.check:SetSize(24, 24)
  r.check:SetPoint("TOPLEFT", 0, -(i - 1) * ROW)
  r.label = UI.Text(frame.list, "GameFontHighlight")
  r.label:SetPoint("LEFT", r.check, "RIGHT", 4, 0)
  rows[i] = r
  return r
end

function Consent:Show(chars, done, initiallyExcluded, guildKey)
  build()
  if type(guildKey) == "string" and guildKey ~= "" then
    local g = (ns.Util.DisplayName(guildKey):gsub("|", "||"))
    frame.text:SetText(string.format(GUILD_TEXT, g, g))
  else
    frame.text:SetText(TEXT)
  end
  names = {}
  for _, n in ipairs(chars or {}) do
    if type(n) == "string" then names[#names + 1] = n end
  end
  onDone = done
  local ex = type(initiallyExcluded) == "table" and initiallyExcluded or {}
  for i, name in ipairs(names) do
    local r = row(i)
    r.label:SetText(ns.Util.DisplayName(name))
    r.check:SetChecked(not ex[name])
    r.check:Show()
    r.label:Show()
  end
  for i = #names + 1, #rows do
    rows[i].check:Hide()
    rows[i].label:Hide()
  end
  local listHeight = math.max(1, #names) * ROW
  frame.list:SetHeight(listHeight)
  frame:SetHeight(40 + (frame.text:GetStringHeight() or 30) + 10 + listHeight + 56)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER")
  frame:Show()
end

function Consent:IsShown()
  return frame ~= nil and frame:IsShown()
end
