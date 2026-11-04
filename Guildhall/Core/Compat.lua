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
  local realm = env.GetNormalizedRealmName and self:Safe(env.GetNormalizedRealmName()) or nil
  return ns.Util.FullName(name, nil, realm)
end

-- The guild's display name, or nil (not in a guild, not loaded yet, or secret).
function Compat:GuildName()
  local env = self.env
  if not env.GetGuildInfo then return nil end
  local name = self:Safe((env.GetGuildInfo("player")))
  if type(name) ~= "string" or name == "" then return nil end
  return name
end

function Compat:GuildKey()
  local env = self.env
  if not env.GetGuildInfo then return nil end
  local name, _, _, realm = env.GetGuildInfo("player")
  name = self:Safe(name)
  if name == nil or name == "" then return nil end
  realm = self:Safe(realm)
  local home = env.GetNormalizedRealmName and self:Safe(env.GetNormalizedRealmName()) or nil
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

-- Server clock offset from UTC in seconds, rounded to 15 minutes; nil when unknown or secret.
function Compat:ServerOffset()
  local dt = self.env.C_DateAndTime
  if not (dt and dt.GetServerTimeLocal) or not self.env.GetServerTime then return nil end
  local localT = self:Safe((dt.GetServerTimeLocal()))
  local utc = self:Safe((self.env.GetServerTime()))
  if type(localT) ~= "number" or type(utc) ~= "number" then return nil end
  return math.floor((localT - utc) / 900 + 0.5) * 900
end

-- Seconds until the weekly reset, or nil when the API is missing or the value is secret.
function Compat:SecondsUntilWeeklyReset()
  local dt = self.env.C_DateAndTime
  if not (dt and dt.GetSecondsUntilWeeklyReset) then return nil end
  local s = self:Safe((dt.GetSecondsUntilWeeklyReset()))
  if type(s) ~= "number" then return nil end
  return s
end

function Compat:_isSecret(v)
  local env = self.env
  if env.issecretvalue and env.issecretvalue(v) then return true end
  return env.canaccessvalue ~= nil and not env.canaccessvalue(v)
end

-- Both sides of the open trade window: { give = {{id,n}}, get = {{id,n}}, giveCopper, getCopper },
-- or nil when the APIs are missing or ANY value is secret (an incomplete snapshot is never kept).
-- Slots 1-6 are the tradable ones (slot 7 is the will-not-be-traded slot).
function Compat:TradeSnapshot()
  local env = self.env
  if not (env.GetPlayerTradeMoney and env.GetTargetTradeMoney) then return nil end
  local function side(linkFn, infoFn)
    if not (linkFn and infoFn) then return nil end
    local out = {}
    for i = 1, 6 do
      local rawLink = linkFn(i)
      if self:Safe(rawLink) == nil and self:_isSecret(rawLink) then return nil end
      local link = self:Safe(rawLink)
      -- An empty slot has no link (skipped); a link with no readable count aborts the snapshot.
      if link ~= nil then
        local _, _, n = infoFn(i)
        n = self:Safe(n)
        if n == nil then return nil end
        local id = type(link) == "string" and ns.Util.ItemIdFromLink(link) or nil
        if id and type(n) == "number" and n > 0 then out[#out + 1] = { id = id, n = n } end
      end
    end
    return out
  end
  local give = side(env.GetTradePlayerItemLink, env.GetTradePlayerItemInfo)
  local get = side(env.GetTradeTargetItemLink, env.GetTradeTargetItemInfo)
  local giveCopper, getCopper = self:Safe(env.GetPlayerTradeMoney()), self:Safe(env.GetTargetTradeMoney())
  if not give or not get or type(giveCopper) ~= "number" or type(getCopper) ~= "number" then return nil end
  return { give = give, get = get, giveCopper = giveCopper, getCopper = getCopper }
end

-- One attachment slot: nil = unreadable (abort the whole snapshot), false = empty slot (every raw
-- field nil), else { id, n }. A slot with ANY non-nil field (name, link, id, count; secret counts)
-- is occupied, and an occupied slot without a usable id aborts. The item id prefers the slot's
-- itemID (works while the link is uncached) and falls back to parsing the link.
function Compat:_attachment(rawName, rawLink, rawId, rawN)
  if rawName == nil and rawLink == nil and rawId == nil and rawN == nil then return false end
  if self:Safe(rawLink) == nil and self:_isSecret(rawLink) then return nil end
  local link, id = self:Safe(rawLink), self:Safe(rawId)
  if type(id) ~= "number" then
    id = type(link) == "string" and ns.Util.ItemIdFromLink(link) or nil
  end
  local n = self:Safe(rawN)
  if not id or type(n) ~= "number" or n <= 0 then return nil end
  return { id = id, n = n }
end

function Compat:Money()
  local env = self.env
  if not env.GetMoney then return nil end
  local m = self:Safe((env.GetMoney()))
  return type(m) == "number" and m or nil
end

-- Reads the filled-in Send Mail fields: { to, cod, items = {{id,n}} }, or nil when the CoD is 0,
-- the APIs/fields are missing, or ANY value is secret / unreadable.
function Compat:SendMailSnapshot()
  local env = self.env
  local box = env.SendMailNameEditBox
  if not (box and box.GetText and env.GetSendMailCOD and env.GetSendMailItemLink and env.GetSendMailItem) then return nil end
  local to = self:Safe(box:GetText())
  local cod = self:Safe(env.GetSendMailCOD())
  if type(to) ~= "string" or to == "" or type(cod) ~= "number" or cod <= 0 then return nil end
  local items = {}
  for i = 1, env.ATTACHMENTS_MAX_SEND or 12 do
    local rawName, rawId, _, rawN = env.GetSendMailItem(i)
    local a = self:_attachment(rawName, env.GetSendMailItemLink(i), rawId, rawN)
    if a == nil then return nil end
    if a then items[#items + 1] = a end
  end
  if #items == 0 then return nil end
  return { to = to, cod = cod, items = items }
end

function Compat:InboxCount()
  local env = self.env
  if not env.GetInboxNumItems then return 0 end
  local n = self:Safe((env.GetInboxNumItems()))
  return type(n) == "number" and n or 0
end

-- A CoD mail in the inbox: { sender, cod, items = {{id,n}} }, or nil (no CoD, missing API, any secret).
function Compat:InboxCod(index)
  local env = self.env
  if not (env.GetInboxHeaderInfo and env.GetInboxItemLink and env.GetInboxItem) then return nil end
  local _, _, rawSender, _, _, rawCod = env.GetInboxHeaderInfo(index)
  local sender, cod = self:Safe(rawSender), self:Safe(rawCod)
  if type(sender) ~= "string" or sender == "" or type(cod) ~= "number" or cod <= 0 then return nil end
  local items = {}
  for i = 1, env.ATTACHMENTS_MAX_RECEIVE or 16 do
    local rawName, rawId, _, rawN = env.GetInboxItem(index, i)
    local a = self:_attachment(rawName, env.GetInboxItemLink(index, i), rawId, rawN)
    if a == nil then return nil end
    if a then items[#items + 1] = a end
  end
  if #items == 0 then return nil end
  return { sender = sender, cod = cod, items = items }
end

-- The trade partner's full name, or nil (no trade, API missing or secret).
function Compat:TradePartner()
  local env = self.env
  if not env.UnitName then return nil end
  local name, realm = env.UnitName("NPC")
  name, realm = self:Safe(name), self:Safe(realm)
  if type(name) ~= "string" or name == "" then return nil end
  local home = env.GetNormalizedRealmName and self:Safe(env.GetNormalizedRealmName()) or nil
  return ns.Util.FullName(name, type(realm) == "string" and realm or nil, home)
end

ns.compat = Compat.new(_G)
