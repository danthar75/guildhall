local ADDON, ns = ...

-- Settings tab, "Groups" sub-tab: the personal group finder options, saved account-wide in
-- GuildhallDB.personal.groups (the table Reminders reads on every check):
--   reminders  "Remind me 15 min before runs I signed up for" (false = off)
--   sound      "Play a sound with reminders" (false = no sound)
--   roles      "My usual roles" { t, h, d }, the defaults for Ready now and Sign up (read through
--              ns.Groups.Details.PersonalRoles). At least one role stays ticked.
-- Missing values are filled by Reminders.Defaults (never by DB.lua's merge, which would add DPS back
-- to a saved choice). Without SavedVariables the boxes show the defaults and save nothing.
-- SettingsView.Build(parent) -> section { refresh, reminders, sound, roles = { t, h, d } }; sets the
-- parent's height. No named globals.
ns.Groups = ns.Groups or {}
local UI = ns.UI
local SettingsView = {}
ns.Groups.SettingsView = SettingsView

local ROLES = { "t", "h", "d" }
local ROLE_NAME = { t = "Tank", h = "Healer", d = "DPS" }
local KEEP_ONE = "Keep at least one role."

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

-- personal.groups with its defaults filled (Reminders.Defaults). Without SavedVariables, a fresh
-- table of the defaults that nothing keeps, so the boxes show the defaults and save nothing.
local function settings()
  local p = UI.Personal()
  return ns.Groups.Reminders.Defaults(type(p) == "table" and p or {})
end

local function current()
  local g = settings()
  return { reminders = g.reminders ~= false, sound = g.sound ~= false, roles = g.roles }
end

local function checkbox(parent, label, x, y)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", x, y)
  local text = UI.Text(parent, "GameFontHighlight", label)
  text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  return cb, text
end

function SettingsView.Build(parent)
  local section = { roles = {} }

  section.reminders = checkbox(parent, "Remind me 15 min before runs I signed up for", 0, 0)
  on(section.reminders, "OnClick", function(self)
    settings().reminders = self:GetChecked() == true
    section.refresh()
  end)

  section.sound, section.soundLabel = checkbox(parent, "Play a sound with reminders", 20, -26)
  on(section.sound, "OnClick", function(self)
    settings().sound = self:GetChecked() == true
  end)

  local head = UI.Text(parent, "GameFontNormal", "My usual roles")
  head:SetPoint("TOPLEFT", 4, -66)
  local sub = UI.Text(parent, "GameFontDisableSmall", "(the defaults for Ready now and Sign up)")
  sub:SetPoint("LEFT", head, "RIGHT", 8, 0)
  for i, r in ipairs(ROLES) do
    local cb = checkbox(parent, ROLE_NAME[r], (i - 1) * 110, -86)
    on(cb, "OnClick", function(self)
      local roles = settings().roles
      local want = self:GetChecked() == true
      local others = 0
      for _, o in ipairs(ROLES) do
        if o ~= r and section.roles[o]:GetChecked() then others = others + 1 end
      end
      if not want and others == 0 then
        self:SetChecked(true)
        section.status:SetText(KEEP_ONE)
        return
      end
      section.status:SetText("")
      roles[r] = want or nil
      section.refresh() -- shows what was kept (nothing, without SavedVariables)
    end)
    section.roles[r] = cb
  end
  section.status = UI.Text(parent, "GameFontDisableSmall", "")
  section.status:SetPoint("TOPLEFT", 4, -116)
  if parent.SetHeight then parent:SetHeight(136) end

  function section.refresh()
    local c = current()
    section.reminders:SetChecked(c.reminders)
    section.sound:SetChecked(c.sound)
    if c.reminders then section.sound:Enable() else section.sound:Disable() end
    if section.soundLabel.SetTextColor then
      local v = c.reminders and 1 or 0.5
      section.soundLabel:SetTextColor(v, v, v)
    end
    for _, r in ipairs(ROLES) do section.roles[r]:SetChecked(c.roles[r] == true) end
  end

  section.refresh()
  return section
end
