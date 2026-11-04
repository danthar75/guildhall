local ADDON, ns = ...

-- Slash commands (/gh, /guildhall) and the minimap button.
-- Globals: SLASH_GUILDHALL1, SLASH_GUILDHALL2, SlashCmdList.GUILDHALL (required by the slash system).
local UI = ns.UI
local Launcher = {}
UI.Launcher = Launcher

local DEFAULT_ANGLE = 200

local function help()
  print("|cffffd200Guildhall|r commands:")
  print("  /gh  - open or close the Guildhall window")
  print("  /gh log  - open the Log tab")
  print("  /gh help  - show this list")
end

SLASH_GUILDHALL1 = "/gh"
SLASH_GUILDHALL2 = "/guildhall"
SlashCmdList.GUILDHALL = function(msg)
  UI.Try(function()
    local cmd = string.lower(ns.Util.Trim(msg or ""))
    if cmd == "" then
      UI.Window:Toggle()
    elseif cmd == "log" then
      UI.Window:Show("Log")
    else
      help()
    end
  end)
end

-- Minimap button -------------------------------------------------------------

local button

local function place(angle)
  local rad = math.rad(angle)
  local r = (Minimap:GetWidth() / 2) + 10
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

local function cursorAngle()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx, cy = cx / scale, cy / scale
  local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
  return math.deg(atan2(cy - my, cx - mx)) % 360
end

function Launcher:Init()
  if button or not Minimap then return end
  local db = UI.WindowDB()
  button = CreateFrame("Button", nil, Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function() UI.Try(UI.Window.Toggle, UI.Window) end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Guildhall")
    GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      UI.Try(function()
        local a = cursorAngle()
        place(a)
        local w = UI.WindowDB()
        if w then w.minimapAngle = a end
      end)
    end)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

  local angle = db and tonumber(db.minimapAngle) or DEFAULT_ANGLE
  place(angle)
end
