local ADDON, ns = ...

-- Settings tab: a row of sub-tabs, General, one per module with a `settings` entry (in module
-- registration order: Exchange, Leaderboard, Groups), Permissions (UI.PermissionsView) and Change
-- history (UI.HistoryView). General holds the core lines (guild key, profile id, officer threshold,
-- linked characters). The builders are looked up when a sub-tab is built. Every sub-tab but Change
-- history (which scrolls its own list) sits in a scroll frame; a section builder may set its
-- parent's height, the default is 120. Only the shown sub-tab refreshes.
-- SettingsView.Build(parent) -> view { refresh, select(key), tabKeys, panes, info, chars }.
-- Named globals: "GuildhallUISettingsScroll" (General) and "GuildhallUISettingsScroll2", 3, ... for
-- the other sub-tabs (the scroll frame template needs a name on some clients).
local UI = ns.UI
local SettingsView = {}
UI.SettingsView = SettingsView

local WIDTH = 690
local SECTION_DEFAULT_HEIGHT = 120
local TAB_H = 28
local GENERAL = "General"

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
  local names = s.profile:GuildChars() -- only this guild's characters

  local charLines = {}
  for _, name in ipairs(names) do
    local inc = chars[name].included
    local state = inc == true and "|cff40ff40linked|r" or inc == false and "|cffaaaaaanot shared|r" or "|cffffd200undecided|r"
    charLines[#charLines + 1] = "  " .. ns.Util.DisplayName(name) .. "  " .. state
  end
  if #charLines == 0 then charLines[1] = "  (none yet)" end
  return table.concat(lines, "\n"), "Characters in this guild:\n" .. table.concat(charLines, "\n")
end

-- A scroll frame filling `pane`, with its content frame.
local function scrollPane(pane, name)
  local scroll = CreateFrame("ScrollFrame", name, pane, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 4, -4)
  scroll:SetPoint("BOTTOMRIGHT", -26, 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH, 400)
  scroll:SetScrollChild(content)
  return content
end

local function buildGeneral(view, content)
  local header = UI.Text(content, "GameFontNormalLarge", "Guildhall")
  header:SetPoint("TOPLEFT", 4, -4)

  local welcome = UI.Button(content, "Show welcome screen", 160, function() UI.Welcome:Show() end)
  welcome:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -4)

  view.info = UI.Text(content, "GameFontHighlight")
  view.info:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
  view.info:SetWidth(WIDTH - 10)
  view.info:SetSpacing(4)

  view.chars = UI.Text(content, "GameFontHighlight")
  view.chars:SetPoint("TOPLEFT", view.info, "BOTTOMLEFT", 0, -10)
  view.chars:SetWidth(WIDTH - 140)
  view.chars:SetSpacing(2)

  view.change = UI.Button(content, "Change...", 100, function()
    if ns.Boot and ns.Boot.ChangeConsent then ns.Boot.ChangeConsent() end
  end)
  -- Single anchor: sets both axes, keeps the fixed 100 px width.
  view.change:SetPoint("TOPLEFT", view.chars, "TOPRIGHT", 20, 2)

  return function()
    local info, chars = coreLines()
    view.info:SetText(info)
    view.chars:SetText(chars)
    if ns.services then view.change:Show() else view.change:Hide() end
    content:SetHeight(math.max(1, 4 + header:GetStringHeight() + 8 + view.info:GetStringHeight() + 10
      + math.max(view.chars:GetStringHeight(), 24) + 24))
  end
end

function SettingsView.Build(parent)
  local view = { panes = {}, tabKeys = {}, tabs = {}, sections = {} }

  -- Sub-tab definitions, in display order.
  local defs = { { key = GENERAL } }
  local used = { [GENERAL] = true, Permissions = true, ["Change history"] = true }
  for _, name in ipairs(ns.Modules()) do
    local def = ns.GetModule(name)
    local st = type(def) == "table" and def.settings
    if type(st) == "table" and type(st.build) == "function" then
      local key = type(st.title) == "string" and st.title or name
      if used[key] then key = name end
      if not used[key] then
        used[key] = true
        defs[#defs + 1] = { key = key, build = st.build }
      end
    end
  end
  defs[#defs + 1] = { key = "Permissions", build = function(p) return UI.PermissionsView.Build(p) end }
  defs[#defs + 1] = { key = "Change history", build = function(p) return UI.HistoryView.Build(p) end, noScroll = true }

  -- A section that fails to build (e.g. before guild data exists) is rebuilt in a fresh frame
  -- on a later refresh once ns.services exists.
  local function buildSection(sec)
    if sec.frame then sec.frame:Hide() end
    local section = CreateFrame("Frame", nil, sec.host)
    section:SetSize(WIDTH - 10, SECTION_DEFAULT_HEIGHT)
    section:SetPoint("TOPLEFT", sec.host, "TOPLEFT", 4, -4)
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

  local x = 4
  for i, d in ipairs(defs) do
    local key = d.key
    view.tabKeys[i] = key
    local width = math.max(80, 24 + 7 * #key)
    local btn = UI.Button(parent, key, width, function() view.select(key) end)
    btn:SetPoint("TOPLEFT", x, -2)
    x = x + width + 4
    view.tabs[key] = btn

    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", 0, -TAB_H)
    pane:SetPoint("BOTTOMRIGHT", 0, 0)
    pane:Hide()
    view.panes[key] = pane

    if key == GENERAL then
      view.refreshGeneral = buildGeneral(view, scrollPane(pane, "GuildhallUISettingsScroll"))
    else
      local sec = { key = key, build = d.build }
      if d.noScroll then
        sec.host = pane
      else
        sec.host = scrollPane(pane, "GuildhallUISettingsScroll" .. i)
        sec.content = sec.host
      end
      buildSection(sec)
      view.sections[key] = sec
    end
  end

  local function refreshSection(sec)
    -- Retry once services exist (only if the earlier failure happened without them).
    if sec.failed and not sec.failedWithServices and ns.services then buildSection(sec) end
    local obj = sec.obj
    if type(obj) == "table" and type(obj.refresh) == "function" then UI.Try(obj.refresh, obj) end
    if sec.content then sec.content:SetHeight(math.max(1, (sec.frame:GetHeight() or SECTION_DEFAULT_HEIGHT) + 12)) end
  end

  function view.refresh()
    if view.current == GENERAL then
      view.refreshGeneral()
    elseif view.sections[view.current] then
      refreshSection(view.sections[view.current])
    end
  end

  function view.select(key)
    if not view.panes[key] then key = GENERAL end
    view.current = key
    for k, pane in pairs(view.panes) do
      if k == key then pane:Show(); view.tabs[k]:LockHighlight()
      else pane:Hide(); view.tabs[k]:UnlockHighlight() end
    end
    view.refresh()
  end

  view.select(GENERAL)
  return view
end
