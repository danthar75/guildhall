local ADDON, ns = ...

-- One frame, two modes:
--   Show(title, text):      read-only text, highlighted and focused, for Ctrl+C.
--   Paste(title, onSubmit): empty editable box, OK calls onSubmit(text) then hides.
-- Named globals: "GuildhearthUICopyBox" (UISpecialFrames needs a name for ESC to close it)
-- and "GuildhearthUICopyBoxScroll" (scroll frame template needs a name on some clients).
local UI = ns.UI
local CopyBox = {}
UI.CopyBox = CopyBox

local frame, edit, hint, okButton

local function build()
  if frame then return end
  frame = UI.CreatePanel("GuildhearthUICopyBox", 560, 380, "")
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhearthUICopyBox") end

  hint = UI.Text(frame, "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 16, 18)

  local scroll
  scroll, edit = UI.ScrollText(frame, "GuildhearthUICopyBoxScroll")
  scroll:SetPoint("TOPLEFT", 16, -40)
  scroll:SetPoint("BOTTOMRIGHT", -34, 46)
  edit:SetScript("OnEscapePressed", function() frame:Hide() end)

  okButton = UI.Button(frame, "OK", 90, function()
    local cb = frame.onSubmit
    local text = edit:GetText()
    frame.onSubmit = nil
    frame:Hide()
    if cb then cb(text) end
  end)
  okButton:SetPoint("BOTTOMRIGHT", -16, 12)

  frame:SetScript("OnHide", function()
    edit:ClearFocus()
    frame.onSubmit = nil
  end)
end

function CopyBox:Show(title, text)
  build()
  frame.title:SetText(title or "Copy")
  hint:SetText("Press Ctrl+C to copy")
  okButton:Hide()
  frame.onSubmit = nil
  edit.highlightOnRevert = true
  UI.SetReadOnlyText(edit, text or "")
  frame:Show()
  edit:SetFocus()
  edit:HighlightText()
end

function CopyBox:Paste(title, onSubmit)
  build()
  frame.title:SetText(title or "Paste")
  hint:SetText("Press Ctrl+V to paste")
  okButton:Show()
  edit.readOnlyText = nil
  edit.highlightOnRevert = nil
  edit:SetText("")
  frame:Show()
  frame.onSubmit = onSubmit
  edit:SetFocus()
end

function CopyBox:Hide()
  if frame then frame:Hide() end
end
