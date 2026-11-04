local ADDON, ns = ...

-- Settings tab, "Groups" sub-tab: the personal group finder options, saved account-wide in
-- GuildhearthDB.personal.groups (the table Reminders reads on every check):
--   reminders  "Remind me 15 min before runs I signed up for" (false = off)
--   sound      "Play a sound with reminders" (false = no sound)
--   roles      "My usual roles" { t, h, d }, the defaults for Ready now and Sign up (read through
--              ns.Groups.Details.PersonalRoles). At least one role stays ticked.
-- Missing values are filled by Reminders.Defaults (never by DB.lua's merge, which would add DPS back
-- to a saved choice). Without SavedVariables the boxes show the defaults and save nothing.
-- Below them, the guild settings (Ruling U1b, ns.Groups.Credit.Settings / SetSetting on the real
-- Leaderboard config): two checkboxes for the guild master, the current state as text for everyone
-- else.
-- SettingsView.Build(parent) -> section { refresh, reminders, sound, roles = { t, h, d }, calendar,
-- other }; sets the parent's height. No named globals.
ns.Groups = ns.Groups or {}
local UI = ns.UI
local SettingsView = {}
ns.Groups.SettingsView = SettingsView

local ROLES = { "t", "h", "d" }
local ROLE_NAME = { t = "Tank", h = "Healer", d = "DPS" }
local KEEP_ONE = "Keep at least one role."
local GUILD_ONLY = "Only the guild master can change this."
local NOT_SAVED = "Couldn't save that. Try again."
local GUILD_KEYS = {
  { key = "calendar", box = "Raids on the guild calendar count with non-guild players",
    text = "Raids on the guild calendar with non-guild players: " },
  { key = "other", box = "Other runs count with non-guild players",
    text = "Other runs with non-guild players: " },
}

local function guildConfig()
  local l = ns.leaderboard
  return l and (l.realConfig or l.config) or nil
end

local function guildSettings()
  local C = ns.Groups.Credit
  if C and C.Settings then return C.Settings(guildConfig()) end
  return { calendar = true, other = false }
end

local function canSetGuild()
  local C, cfg = ns.Groups.Credit, guildConfig()
  return cfg ~= nil and C ~= nil and C.CanSetSettings ~= nil and C.CanSetSettings(cfg) == true
end

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

  -- Guild settings
  section.guildHead = UI.Text(parent, "GameFontNormal", "Guild settings")
  section.guildHead:SetPoint("TOPLEFT", 4, -140)
  section.guildRows = {}
  for i, g in ipairs(GUILD_KEYS) do
    local y = -160 - (i - 1) * 26
    local cb, label = checkbox(parent, g.box, 0, y)
    local state = UI.Text(parent, "GameFontHighlight", "")
    state:SetPoint("TOPLEFT", 4, y - 5)
    on(cb, "OnClick", function(self)
      local ok, err = ns.Groups.Credit.SetSetting(guildConfig(), g.key, self:GetChecked() == true)
      section.guildStatus:SetText(ok and "" or (err == "no permission" and GUILD_ONLY or NOT_SAVED))
      section.refresh()
    end)
    section[g.key] = cb
    section.guildRows[i] = { cb = cb, label = label, state = state, def = g }
  end
  section.guildStatus = UI.Text(parent, "GameFontDisableSmall", "")
  section.guildStatus:SetPoint("TOPLEFT", 4, -214)
  if parent.SetHeight then parent:SetHeight(234) end

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
    local gs, gm = guildSettings(), canSetGuild()
    section.guildHead:SetText(gm and "Guild settings (guild master)" or "Guild settings")
    for _, row in ipairs(section.guildRows) do
      local v = gs[row.def.key] == true
      if gm then
        row.cb:SetChecked(v)
        row.cb:Show(); row.label:Show(); row.state:Hide()
      else
        row.cb:Hide(); row.label:Hide()
        row.state:SetText(row.def.text .. (v and "count" or "don't count"))
        row.state:Show()
      end
    end
  end

  section.refresh()
  return section
end
