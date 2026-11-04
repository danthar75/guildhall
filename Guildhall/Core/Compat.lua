local ADDON, ns = ...

-- All WoW API touch points live here. Methods only touch `env` (default _G), never _G directly,
-- so specs can pass a fake env and missing APIs (Classic Era, busted) degrade gracefully.
--
-- Send Mail frame names (verified against Gethe/wow-ui-source, branch `forever`,
-- Interface/AddOns/Blizzard_MailFrame/MailFrame.xml and MailFrame.lua):
--   SendMailNameEditBox, SendMailSubjectEditBox, SendMailBodyEditBox (same as Classic);
--   MailFrameTab_OnClick(nil, 2) selects the Send Mail tab (tabID 1 = Inbox, otherwise Send).
local Compat = {}
ns.Compat = Compat
Compat.__index = Compat

-- Enum.SendAddonMessageResult (Forever): Success=0, AddonMessageThrottle=3, ChannelThrottle=8, AddOnMessageLockdown=11
local RES_OK, RES_THROTTLE, RES_CHANNEL_THROTTLE, RES_LOCKDOWN = 0, 3, 8, 11

function Compat.new(env)
  return setmetatable({ env = env or _G, mailboxOpen = false }, Compat)
end

function Compat:Safe(v)
  local env = self.env
  if env.issecretvalue and env.issecretvalue(v) then return nil end
  if env.canaccessvalue and not env.canaccessvalue(v) then return nil end
  return v
end

-- Activating (1) and Active (2) both count as restricted.
function Compat:IsRestricted(kind)
  local env = self.env
  local api = env.C_RestrictedActions
  local types = env.Enum and env.Enum.AddOnRestrictionType
  if not (api and api.GetAddOnRestrictionState and types and types[kind] ~= nil) then return false end
  local state = api.GetAddOnRestrictionState(types[kind])
  return state ~= nil and state ~= 0
end

function Compat:Now()
  return self.env.GetServerTime()
end

function Compat:RegisterPrefix(prefix)
  local ci = self.env.C_ChatInfo
  if ci and ci.RegisterAddonMessagePrefix then ci.RegisterAddonMessagePrefix(prefix) end
end

function Compat:SendAddon(prefix, msg)
  if self:IsRestricted("Chat") then return "lockdown" end
  local ci = self.env.C_ChatInfo
  if not (ci and ci.SendAddonMessage) then return "error" end
  local r = ci.SendAddonMessage(prefix, msg, "GUILD")
  if r == true or r == RES_OK then return "ok" end
  if r == RES_LOCKDOWN then return "lockdown" end
  if r == RES_THROTTLE or r == RES_CHANNEL_THROTTLE then return "throttle" end
  return "error"
end

function Compat:IsTrial()
  local env = self.env
  return (env.IsTrialAccount and env.IsTrialAccount() or env.IsVeteranTrialAccount and env.IsVeteranTrialAccount()) and true or false
end

-- Opens the chat edit box pre-filled. Never sends.
function Compat:OpenChat(text)
  local env = self.env
  if env.ChatFrameUtil and env.ChatFrameUtil.OpenChat then
    env.ChatFrameUtil.OpenChat(text)
  elseif env.ChatFrame_OpenChat then
    env.ChatFrame_OpenChat(text)
  end
end

function Compat:SetMailboxOpen(open) self.mailboxOpen = open and true or false end
function Compat:MailboxOpen() return self.mailboxOpen end

-- Switches to the Send Mail tab and fills the fields. Never clicks Send.
function Compat:FillSendMail(to, subject, body)
  local env = self.env
  local nameBox, subjectBox, bodyBox = env.SendMailNameEditBox, env.SendMailSubjectEditBox, env.SendMailBodyEditBox
  if not (env.MailFrameTab_OnClick and nameBox and subjectBox and bodyBox) then return false end
  env.MailFrameTab_OnClick(nil, 2)
  nameBox:SetText(to or "")
  subjectBox:SetText(subject or "")
  bodyBox:SetText(body or "")
  return true
end

function Compat:PlayerFullName()
  local env = self.env
  local name = env.UnitName and env.UnitName("player") or "Unknown"
  local realm = env.GetNormalizedRealmName and env.GetNormalizedRealmName() or nil
  return ns.Util.FullName(name, nil, realm)
end

function Compat:GuildKey()
  local env = self.env
  if not env.GetGuildInfo then return nil end
  local name, _, _, realm = env.GetGuildInfo("player")
  name = self:Safe(name)
  if name == nil or name == "" then return nil end
  realm = self:Safe(realm)
  local home = env.GetNormalizedRealmName and env.GetNormalizedRealmName() or nil
  return ns.Util.FullName(name, realm, home)
end

function Compat:GetNumGuildMembers()
  local f = self.env.GetNumGuildMembers
  if not f then return 0 end
  local n = self:Safe((f()))
  return type(n) == "number" and n or 0
end

-- Returns only what Roster needs, each already passed through Safe (nil when secret):
-- name, rankIndex, isOnline. Returns nothing when the API is missing.
function Compat:GetGuildRosterInfo(i)
  local f = self.env.GetGuildRosterInfo
  if not f then return nil end
  local name, _, rankIndex, _, _, _, _, _, isOnline = f(i)
  return self:Safe(name), self:Safe(rankIndex), self:Safe(isOnline)
end

-- Asks the server to refresh the roster (results arrive via GUILD_ROSTER_UPDATE).
function Compat:RequestRoster()
  local env = self.env
  if env.C_GuildInfo and env.C_GuildInfo.GuildRoster then
    env.C_GuildInfo.GuildRoster()
  elseif env.GuildRoster then
    env.GuildRoster()
  end
end

-- Guild Information text. Restricted API: nil while Map restriction is active or API missing.
function Compat:GetGuildInfoText()
  local gi = self.env.C_GuildInfo
  if not (gi and gi.GetInfoText) or self:IsRestricted("Map") then return nil end
  return self:Safe((gi.GetInfoText()))
end

ns.compat = Compat.new(_G)
