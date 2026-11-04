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
  print("  /gh names  - show how the game reports character names (for troubleshooting)")
  print("  /gh lbdemo - show fake leaderboard data (only on your screen)")
  print("  /gh help  - show this list")
end

-- Fake leaderboard data, on this screen only. Nothing is saved or sent.
function Launcher.LeaderboardDemo(on)
  local demo = ns.Leaderboard and ns.Leaderboard.Demo
  if not (demo and demo.Set(ns, on)) then
    print("|cffffd200Guildhall|r the Leaderboard isn't running (are you in a guild?).")
  elseif on then
    print("|cffffd200Guildhall|r showing fake leaderboard data. Type /gh lbdemo off to go back.")
  else
    print("|cffffd200Guildhall|r back to the real leaderboard.")
  end
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
    elseif cmd == "names" then
      Launcher.PrintNames()
    elseif cmd == "lbdemo" or cmd == "lbdemo off" then
      Launcher.LeaderboardDemo(cmd == "lbdemo")
    else
      help()
    end
  end)
end

-- Names diagnostic -----------------------------------------------------------
-- WoW Forever names are "Main Secondary" (space-separated) and the client is
-- realmless; this prints what each API actually returns so name handling can
-- be checked against the live client. Values are shown with %q so spaces and
-- separators are visible.

local function show(label, ...)
  local parts = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if issecretvalue and issecretvalue(v) then
      parts[#parts + 1] = "<secret>"
    elseif type(v) == "string" then
      parts[#parts + 1] = string.format("%q", v)
    else
      parts[#parts + 1] = tostring(v)
    end
  end
  print("  " .. label .. ": " .. table.concat(parts, ", "))
end

local function try(label, f, ...)
  if type(f) ~= "function" then return show(label, "(not available)") end
  local r = { pcall(f, ...) }
  if not r[1] then return show(label, "(error)") end
  show(label, unpack(r, 2, math.max(2, #r)))
end

function Launcher.PrintNames()
  print("|cffffd200Guildhall|r name check (please copy this to Dor):")
  try("UnitName", UnitName, "player")
  try("UnitFullName", UnitFullName, "player")
  try("GetUnitName(full)", GetUnitName, "player", true)
  try("GetNormalizedRealmName", GetNormalizedRealmName)
  try("ShouldDisplaySurname", C_PlayerInfo and C_PlayerInfo.ShouldDisplaySurname)
  local guid = UnitGUID and UnitGUID("player")
  if issecretvalue and issecretvalue(guid) then guid = nil end
  local found = false
  if GetNumGuildMembers and GetGuildRosterInfo then
    for i = 1, (GetNumGuildMembers() or 0) do
      local r = { pcall(GetGuildRosterInfo, i) }
      -- r[18] is the 17th return of GetGuildRosterInfo (guid); r[1] is pcall's ok flag.
      local g = r[1] and r[18] or nil
      if issecretvalue and issecretvalue(g) then g = nil end
      if guid and g == guid then
        show("Guild roster (you)", r[2]); found = true; break
      end
    end
  end
  if not found then show("Guild roster (you)", "(not found yet - open the guild window and try again)") end
  local s = ns.services
  show("Guildhall uses", s and s.playerChar or "(not started)")
  local rs = s and s.comm and s.comm.recentSenders or {}
  show("Recent addon senders", #rs > 0 and table.concat(rs, " | ") or "(none yet)")
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
  icon:SetTexture(UI.LOGO)
  icon:SetSize(19, 19)
  icon:SetPoint("TOPLEFT", 6, -6)

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
