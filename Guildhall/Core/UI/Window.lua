local ADDON, ns = ...

-- Main window plus small shared UI helpers used by the other Core/UI files.
-- Named globals: "GuildhallMainFrame" (required so ESC can close it via UISpecialFrames).
local UI = ns.UI or {}
ns.UI = UI

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
UI.BACKDROP_TEMPLATE = BACKDROP_TEMPLATE

local BACKDROP = {
  bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 16,
  insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

UI.NO_GUILD_TEXT = "Join a guild to use Guildhall"

-- Helpers ------------------------------------------------------------------

-- Runs fn in pcall, routing errors to ns.OnError. Returns fn's first result on success.
function UI.Try(fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then ns.OnError(res); return nil end
  return res
end

function UI.Personal()
  local sv = GuildhallDB
  if type(sv) ~= "table" or type(sv.personal) ~= "table" then return nil end
  return sv.personal
end

function UI.WindowDB()
  local p = UI.Personal()
  if not p then return nil end
  if type(p.window) ~= "table" then p.window = {} end
  return p.window
end

function UI.ApplyBackdrop(f, alpha)
  if not f.SetBackdrop then return end
  f:SetBackdrop(BACKDROP)
  f:SetBackdropColor(0.06, 0.06, 0.08, alpha or 0.95)
  local b = ns.Theme.Get("border") or { 0.5, 0.5, 0.5 }
  f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
end

function UI.Text(parent, font, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  if text then fs:SetText(text) end
  return fs
end

function UI.Button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 100, 22)
  b:SetText(text)
  if onClick then
    b:SetScript("OnClick", function(self, ...) UI.Try(onClick, self, ...) end)
  end
  return b
end

-- A movable dialog-style panel with a title and close button. `name` is optional.
function UI.CreatePanel(name, width, height, title)
  local f = CreateFrame("Frame", name, UIParent, BACKDROP_TEMPLATE)
  f:SetSize(width, height)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  UI.ApplyBackdrop(f)
  -- The dialog background texture is partly transparent; panels open on top of the main
  -- window, so give them a solid fill underneath or the board shows through.
  if f.CreateTexture then
    local fill = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    fill:SetPoint("TOPLEFT", 4, -4)
    fill:SetPoint("BOTTOMRIGHT", -4, 4)
    if fill.SetColorTexture then fill:SetColorTexture(0.06, 0.06, 0.08, 1) end
  end
  f.title = UI.Text(f, "GameFontNormalLarge", title or "")
  f.title:SetPoint("TOPLEFT", 14, -12)
  local accent = ns.Theme.Get("accent")
  if accent then f.title:SetTextColor(accent[1], accent[2], accent[3]) end
  f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  f.close:SetPoint("TOPRIGHT", -2, -2)
  f:Hide()
  return f
end

-- Scrolling multi-line EditBox. `name` is required on some clients by
-- UIPanelScrollFrameTemplate (its scrollbar is looked up by "$parentScrollBar").
function UI.ScrollText(parent, name)
  local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
  local edit = CreateFrame("EditBox", nil, scroll)
  edit:SetMultiLine(true)
  edit:SetAutoFocus(false)
  edit:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
  edit:SetMaxLetters(0)
  edit:SetWidth(300)
  edit:SetHeight(50)
  edit:SetTextInsets(4, 4, 4, 4)
  edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if ScrollingEdit_OnCursorChanged and ScrollingEdit_OnUpdate then
    edit:SetScript("OnCursorChanged", ScrollingEdit_OnCursorChanged)
    edit:SetScript("OnUpdate", function(self, elapsed) ScrollingEdit_OnUpdate(self, elapsed, scroll) end)
  end
  -- Read-only mode: user edits are reverted (EditBox has no native read-only flag).
  edit:SetScript("OnTextChanged", function(self, userInput)
    if userInput and self.readOnlyText then
      self:SetText(self.readOnlyText)
      if self.highlightOnRevert then self:HighlightText() end
    end
  end)
  scroll:SetScrollChild(edit)
  scroll:SetScript("OnSizeChanged", function(self, w) if w and w > 0 then edit:SetWidth(w) end end)
  scroll:EnableMouse(true)
  scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
  return scroll, edit
end

function UI.SetReadOnlyText(edit, text)
  edit.readOnlyText = text or ""
  edit:SetText(edit.readOnlyText)
  edit:SetCursorPosition(0)
end

-- Window -------------------------------------------------------------------

local Window = {}
UI.Window = Window

local WIDTH, HEIGHT = 760, 500
local frame, tabs, current, titleText

local function collectTabs()
  local list = {}
  for _, name in ipairs(ns.Modules()) do
    local def = ns.GetModule(name)
    if type(def) == "table" and type(def.tab) == "table" and type(def.tab.build) == "function" then
      list[#list + 1] = { key = name, title = def.tab.title or name, build = def.tab.build, isModule = true }
    end
  end
  list[#list + 1] = { key = "Log", title = "Log", build = function(p) return UI.LogView.Build(p) end }
  list[#list + 1] = { key = "Settings", title = "Settings", build = function(p) return UI.SettingsView.Build(p) end }
  return list
end

local function savePosition()
  local db = UI.WindowDB()
  if not db then return end
  local point, _, relPoint, x, y = frame:GetPoint(1)
  db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function restorePosition()
  local db = UI.WindowDB()
  frame:ClearAllPoints()
  if db and type(db.point) == "string" and type(db.x) == "number" and type(db.y) == "number" then
    frame:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x, db.y)
  else
    frame:SetPoint("CENTER")
  end
end

local function setMessage(tab, text)
  if not tab.message then
    tab.message = UI.Text(tab.container, "GameFontNormal")
    tab.message:SetPoint("CENTER")
    tab.message:SetJustifyH("CENTER")
    tab.message:SetWidth(WIDTH - 80)
  end
  tab.message:SetText(text)
  tab.message:Show()
end

local function buildTab(tab)
  if tab.built then return end
  -- Module tabs (and the Log) need a guild; show a hint until services exist.
  if tab.key ~= "Settings" and not ns.services then
    tab.waitingForGuild = true
    setMessage(tab, UI.NO_GUILD_TEXT)
    return
  end
  tab.waitingForGuild = nil
  if tab.message then tab.message:Hide() end
  tab.built = true
  local ok, obj = pcall(tab.build, tab.container)
  if ok then
    tab.obj = obj
  else
    ns.OnError(obj)
    setMessage(tab, "This tab could not be loaded yet.\n\n" .. tostring(obj))
  end
end

local function refreshTab(tab)
  local obj = tab.obj
  if type(obj) == "table" and type(obj.refresh) == "function" then
    -- Called with obj as first arg so both obj:refresh() and obj.refresh() styles work.
    UI.Try(obj.refresh, obj)
  end
end

local function selectTab(key)
  local target
  for _, tab in ipairs(tabs) do
    if tab.key == key or tab.title == key then target = tab end
  end
  target = target or tabs[1]
  current = target
  for _, tab in ipairs(tabs) do
    if tab == target then
      tab.button:LockHighlight()
      tab.container:Show()
    else
      tab.button:UnlockHighlight()
      tab.container:Hide()
    end
  end
  buildTab(target)
  refreshTab(target)
end

local function build()
  if frame then return end
  frame = CreateFrame("Frame", "GuildhallMainFrame", UIParent, BACKDROP_TEMPLATE)
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    UI.Try(savePosition)
  end)
  UI.ApplyBackdrop(frame)
  frame:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhallMainFrame") end

  titleText = UI.Text(frame, "GameFontNormalLarge")
  titleText:SetPoint("TOPLEFT", 16, -14)

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local content = CreateFrame("Frame", nil, frame)
  content:SetPoint("TOPLEFT", 12, -70)
  content:SetPoint("BOTTOMRIGHT", -12, 12)

  -- Accent rule under the tab row.
  local rule = frame:CreateTexture(nil, "ARTWORK")
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", 12, -66)
  rule:SetPoint("TOPRIGHT", -12, -66)
  local b = ns.Theme.Get("border") or { 0.5, 0.5, 0.5 }
  rule:SetColorTexture(b[1], b[2], b[3], 0.9)

  tabs = collectTabs()
  local x = 14
  for _, tab in ipairs(tabs) do
    local width = math.max(80, 20 + 7 * #tab.title)
    tab.button = UI.Button(frame, tab.title, width, function() selectTab(tab.key) end)
    tab.button:SetPoint("TOPLEFT", x, -40)
    x = x + width + 4
    tab.container = CreateFrame("Frame", nil, content)
    tab.container:SetAllPoints(content)
    tab.container:Hide()
  end

  frame:SetScript("OnShow", function() UI.Try(Window.Refresh, Window) end)
  restorePosition()
end

function Window:Show(tabName)
  build()
  frame:Show()
  selectTab(tabName or (current and current.key) or tabs[1].key)
end

function Window:Toggle()
  if frame and frame:IsShown() then frame:Hide() else self:Show() end
end

function Window:IsShown()
  return frame ~= nil and frame:IsShown()
end

local function applyTitle()
  titleText:SetText(ns.Theme.Get("title") or "Guildhall")
  local accent = ns.Theme.Get("accent")
  if accent then titleText:SetTextColor(accent[1], accent[2], accent[3]) end
end

function Window:Refresh()
  if not (frame and frame:IsShown()) then return end
  applyTitle() -- before the current-tab guard so the first Show (OnShow fires pre-select) has a title
  if not current then return end
  -- A tab that was waiting for guild data can build now.
  if current.waitingForGuild and ns.services then buildTab(current) end
  -- Hidden tabs refresh when selected, so only the visible one needs it now.
  refreshTab(current)
end
