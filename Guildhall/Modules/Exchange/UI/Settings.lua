local ADDON, ns = ...

-- Exchange settings section: edits the personal message templates
-- (GuildhallDB.personal.templates, the table ns.services.templates points at).
-- A field equal to the default is stored as nil so future default changes apply.
-- Newlines are shown and typed as "\n" because the edit boxes are single-line.
ns.Exchange = ns.Exchange or {}
local UI = ns.UI
local Board = ns.Exchange.Board or {}
ns.Exchange.Board = Board

local FIELDS = {
  { key = "whisperLF", label = "Whisper (buying listing)" },
  { key = "whisperWTS", label = "Whisper (selling listing)" },
  { key = "mailSubject", label = "Mail subject" },
  { key = "mailBodyLF", label = "Mail body (buying listing)" },
  { key = "mailBodyWTS", label = "Mail body (selling listing)" },
  { key = "discord", label = "Copy for Discord" },
}
local ROW_H = 44
local HINT = "Placeholders: {item} {itemName} {qtySuffix} {kind} {matsWord} {codWord} {noteLine} {char}. Type \\n for a new line."

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function templates()
  local p = UI.Personal()
  if not p then return nil end
  if type(p.templates) ~= "table" then p.templates = {} end
  return p.templates
end

local function default(key) return ns.Exchange.Format.DEFAULTS[key] or "" end
local function toBox(s) return (s:gsub("\n", "\\n")) end
local function fromBox(s) return (s:gsub("\\n", "\n")) end

local function current(key)
  local t = templates()
  local v = t and t[key]
  return type(v) == "string" and v or default(key)
end

local function save(key, text)
  local t = templates()
  if not t then return end
  local v = fromBox(text or "")
  if v == "" or v == default(key) then t[key] = nil else t[key] = v end
end

function Board.BuildSettings(parent)
  local section = { boxes = {} }
  local width = parent:GetWidth()
  if type(width) ~= "number" or width < 200 then width = 680 end

  local hint = UI.Text(parent, "GameFontDisableSmall", HINT)
  hint:SetPoint("TOPLEFT", 0, 0)
  hint:SetWidth(width)

  for i, fld in ipairs(FIELDS) do
    local y = -24 - (i - 1) * ROW_H
    local label = UI.Text(parent, "GameFontNormal", fld.label)
    label:SetPoint("TOPLEFT", 0, y)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width - 110, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(500)
    box:SetPoint("TOPLEFT", 6, y - 16)
    on(box, "OnEnterPressed", function(self) save(fld.key, self:GetText()); self:ClearFocus() end)
    on(box, "OnEditFocusLost", function(self) save(fld.key, self:GetText()) end)
    on(box, "OnEscapePressed", function(self)
      self:SetText(toBox(current(fld.key)))
      self:ClearFocus()
    end)
    local reset = UI.Button(parent, "Reset", 80, function()
      local t = templates()
      if t then t[fld.key] = nil end
      box:SetText(toBox(default(fld.key)))
    end)
    reset:SetPoint("LEFT", box, "RIGHT", 10, 0)
    section.boxes[fld.key] = box
  end
  parent:SetHeight(24 + #FIELDS * ROW_H + 8)

  function section.refresh()
    for key, box in pairs(section.boxes) do
      if not (box.HasFocus and box:HasFocus()) then box:SetText(toBox(current(key))) end
    end
  end
  section.refresh()
  return section
end
