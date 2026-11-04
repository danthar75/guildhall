local ADDON, ns = ...

-- Log tab: filter box, scrolling read-only text of Log:Export lines, Export button.
-- Named global: "GuildhallUILogScroll" (scroll frame template needs a name on some clients).
local UI = ns.UI
local LogView = {}
UI.LogView = LogView

local MAX_SHOWN = 500 -- entries rendered in the tab; Export always includes every match

local function matches(e, needle)
  if needle == "" then return true end
  for _, k in ipairs({ "id", "author", "authorChar", "relayer" }) do
    local v = e[k]
    if v ~= nil and string.find(string.lower(tostring(v)), needle, 1, true) then return true end
  end
  return false
end

local function filtered(view)
  local s = ns.services
  if not (s and s.log) then return nil end
  local needle = string.lower(ns.Util.Trim(view.filter:GetText() or ""))
  local out = {}
  for _, e in ipairs(s.log:Query()) do
    if type(e) == "table" and matches(e, needle) then out[#out + 1] = e end
  end
  return out
end

function LogView.Build(parent)
  local view = {}

  local label = UI.Text(parent, "GameFontNormal", "Filter:")
  label:SetPoint("TOPLEFT", 4, -6)

  view.filter = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  view.filter:SetSize(260, 20)
  view.filter:SetAutoFocus(false)
  view.filter:SetPoint("LEFT", label, "RIGHT", 10, 0)
  view.filter:SetScript("OnTextChanged", function() UI.Try(view.refresh, view) end)
  view.filter:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  view.filter:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  local help = UI.Text(parent, "GameFontDisableSmall", "Listing ID, profile or character")
  help:SetPoint("LEFT", view.filter, "RIGHT", 10, 0)

  local export = UI.Button(parent, "Export", 90, function()
    local list = filtered(view) or {}
    UI.CopyBox:Show("Guildhall log", ns.services.log:Export(list))
  end)
  export:SetPoint("TOPRIGHT", -4, -2)

  view.count = UI.Text(parent, "GameFontDisableSmall")
  view.count:SetPoint("BOTTOMLEFT", 4, 2)

  local scroll
  scroll, view.edit = UI.ScrollText(parent, "GuildhallUILogScroll")
  scroll:SetPoint("TOPLEFT", 4, -34)
  scroll:SetPoint("BOTTOMRIGHT", -26, 18)

  function view.refresh()
    local list = filtered(view)
    if not list then
      UI.SetReadOnlyText(view.edit, UI.NO_GUILD_TEXT)
      view.count:SetText("")
      return
    end
    local shown = list
    if #list > MAX_SHOWN then
      shown = {}
      for i = 1, MAX_SHOWN do shown[i] = list[i] end
    end
    local text = ns.services.log:Export(shown)
    if text == "" then text = "No log entries." end
    UI.SetReadOnlyText(view.edit, text)
    if #list > MAX_SHOWN then
      view.count:SetText(string.format("Showing newest %d of %d entries. Export includes all.", MAX_SHOWN, #list))
    else
      view.count:SetText(string.format("%d entries", #list))
    end
  end

  return view
end
