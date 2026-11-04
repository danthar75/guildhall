local ADDON, ns = ...

-- Settings tab: a core section (guild key, profile id, officer threshold, linked characters)
-- followed by each module's settings.build(parent) section, stacked in a scroll frame.
-- A module section builder may set its parent's height; the default is 120.
-- Named global: "GuildhallUISettingsScroll" (scroll frame template needs a name on some clients).
local UI = ns.UI
local SettingsView = {}
UI.SettingsView = SettingsView

local WIDTH = 690
local SECTION_DEFAULT_HEIGHT = 120

local function coreLines()
  local s = ns.services
  local lines = {}
  if not s then
    lines[#lines + 1] = "Guild: not in a guild. " .. UI.NO_GUILD_TEXT .. "."
    return table.concat(lines, "\n"), ""
  end
  lines[#lines + 1] = "Guild key: " .. tostring(s.guildKey)
  lines[#lines + 1] = "Profile id: " .. tostring(s.profile:Id())
  local n = s.roster:OfficerThreshold()
  lines[#lines + 1] = "Officer ranks: rank index below " .. tostring(n)
    .. "  |cff888888(Set by officers in Guild Info: [Guildhall officers=N])|r"

  local p = UI.Personal()
  local chars = p and p.profile and p.profile.chars or {}
  local names = {}
  for name in pairs(chars) do names[#names + 1] = name end
  table.sort(names)
  local charLines = {}
  for _, name in ipairs(names) do
    local inc = chars[name].included
    local state = inc == true and "|cff40ff40linked|r" or inc == false and "|cffaaaaaanot shared|r" or "|cffffd200undecided|r"
    charLines[#charLines + 1] = "  " .. ns.Util.DisplayName(name) .. "  " .. state
  end
  if #charLines == 0 then charLines[1] = "  (none yet)" end
  return table.concat(lines, "\n"), "Characters:\n" .. table.concat(charLines, "\n")
end

function SettingsView.Build(parent)
  local view = {}

  local scroll = CreateFrame("ScrollFrame", "GuildhallUISettingsScroll", parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 4, -4)
  scroll:SetPoint("BOTTOMRIGHT", -26, 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH, 400)
  scroll:SetScrollChild(content)

  local header = UI.Text(content, "GameFontNormalLarge", "Guildhall")
  header:SetPoint("TOPLEFT", 4, -4)

  view.info = UI.Text(content, "GameFontHighlight")
  view.info:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
  view.info:SetWidth(WIDTH - 10)
  view.info:SetSpacing(4)

  view.chars = UI.Text(content, "GameFontHighlight")
  view.chars:SetPoint("TOPLEFT", view.info, "BOTTOMLEFT", 0, -10)
  view.chars:SetWidth(WIDTH - 140)
  view.chars:SetSpacing(2)

  view.change = UI.Button(content, "Change…", 100, function()
    if ns.Boot and ns.Boot.ChangeConsent then ns.Boot.ChangeConsent() end
  end)
  -- Single anchor: sets both axes, keeps the fixed 100 px width.
  view.change:SetPoint("TOPLEFT", view.chars, "TOPRIGHT", 20, 2)

  -- Module sections. A section that fails to build (e.g. before guild data exists) is
  -- rebuilt in a fresh frame on a later refresh once ns.services exists.
  local function buildSection(sec)
    if sec.frame then sec.frame:Hide() end
    local section = CreateFrame("Frame", nil, content)
    section:SetSize(WIDTH - 10, SECTION_DEFAULT_HEIGHT)
    sec.frame = section
    local ok, obj = pcall(sec.build, section)
    if ok then
      sec.obj, sec.failed, sec.failedWithServices = obj, nil, nil
    else
      ns.OnError(obj)
      local msg = UI.Text(section, "GameFontDisable", "These settings could not be loaded yet.")
      msg:SetPoint("TOPLEFT", 0, 0)
      sec.obj, sec.failed, sec.failedWithServices = nil, true, ns.services ~= nil
    end
  end

  view.sections = {}
  for _, name in ipairs(ns.Modules()) do
    local def = ns.GetModule(name)
    local st = type(def) == "table" and def.settings
    if type(st) == "table" and type(st.build) == "function" then
      local sec = { title = UI.Text(content, "GameFontNormalLarge", st.title or name), build = st.build }
      buildSection(sec)
      view.sections[#view.sections + 1] = sec
    end
  end

  local function layout()
    local y = -4 - header:GetStringHeight() - 8 - view.info:GetStringHeight() - 10
      - math.max(view.chars:GetStringHeight(), 24) - 24
    for _, sec in ipairs(view.sections) do
      sec.title:ClearAllPoints()
      sec.title:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
      y = y - sec.title:GetStringHeight() - 6
      sec.frame:ClearAllPoints()
      sec.frame:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
      y = y - sec.frame:GetHeight() - 20
    end
    content:SetHeight(math.max(1, -y))
  end

  function view.refresh()
    local info, chars = coreLines()
    view.info:SetText(info)
    view.chars:SetText(chars)
    if ns.services then view.change:Show() else view.change:Hide() end
    for _, sec in ipairs(view.sections) do
      -- Retry once services exist (only if the earlier failure happened without them).
      if sec.failed and not sec.failedWithServices and ns.services then buildSection(sec) end
      local obj = sec.obj
      if type(obj) == "table" and type(obj.refresh) == "function" then UI.Try(obj.refresh, obj) end
    end
    layout()
  end

  return view
end
