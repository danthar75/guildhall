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
-- name, rankIndex, isOnline, rankName. Returns nothing when the API is missing.
function Compat:GetGuildRosterInfo(i)
  local f = self.env.GetGuildRosterInfo
  if not f then return nil end
  local name, rankName, rankIndex, _, _, _, _, _, isOnline = f(i)
  return self:Safe(name), self:Safe(rankIndex), self:Safe(isOnline), self:Safe(rankName)
end

-- The guild's rank names in rank order (index 1 is rank 0, the guild master), or nil when the
-- API is missing, there are no ranks, or any value is secret.
function Compat:GuildRanks()
  local env = self.env
  if not (env.GuildControlGetNumRanks and env.GuildControlGetRankName) then return nil end
  local n = self:Safe((env.GuildControlGetNumRanks()))
  if type(n) ~= "number" or n < 1 then return nil end
  local out = {}
  for i = 1, math.min(n, 10) do
    local name = self:Safe((env.GuildControlGetRankName(i)))
    if type(name) ~= "string" or name == "" then return nil end
    out[i] = name
  end
  return out
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

-- One attachment slot: nil = unreadable (abort the whole snapshot), false = empty slot, else
-- { id, n }. A slot is occupied when name, link or id is non-nil, any of name, link, id or count is
-- secret, or count is a number > 0 (a readable count of 0 or nil alone is empty). An occupied slot
-- without a usable id or count aborts. The item id prefers the slot's itemID (works while the link
-- is uncached) and falls back to parsing the link.
function Compat:_attachment(rawName, rawLink, rawId, rawN)
  local n = self:Safe(rawN)
  local occupied = rawName ~= nil or rawLink ~= nil or rawId ~= nil
    or (rawN ~= nil and self:_isSecret(rawN)) or (type(n) == "number" and n > 0)
  if not occupied then return false end
  if self:Safe(rawLink) == nil and self:_isSecret(rawLink) then return nil end
  local link, id = self:Safe(rawLink), self:Safe(rawId)
  if type(id) ~= "number" then
    id = type(link) == "string" and ns.Util.ItemIdFromLink(link) or nil
  end
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

-- Guild bank. The open flag is driven by events (HandleBankEvent); logs are read per tab.
function Compat:SetBankOpen(open) self.bankOpen = open and true or false end
function Compat:BankOpen() return self.bankOpen == true end

-- Mainline: PLAYER_INTERACTION_MANAGER_FRAME_SHOW/_HIDE with Enum.PlayerInteractionType.GuildBanker.
-- Classic: GUILDBANKFRAME_OPENED/_CLOSED. Returns true when the event was a bank open/close.
function Compat:HandleBankEvent(event, interactionType)
  local env = self.env
  if event == "GUILDBANKFRAME_OPENED" then self:SetBankOpen(true); return true end
  if event == "GUILDBANKFRAME_CLOSED" then self:SetBankOpen(false); return true end
  if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    local kinds = env.Enum and env.Enum.PlayerInteractionType
    local t = self:Safe(interactionType)
    if kinds and kinds.GuildBanker ~= nil and t == kinds.GuildBanker then
      self:SetBankOpen(event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
      return true
    end
  end
  return false
end

function Compat:BankTabCount()
  local f = self.env.GetNumGuildBankTabs
  if not f then return 0 end
  local n = self:Safe((f()))
  return type(n) == "number" and n or 0
end

-- The pseudo-tab that holds the money log (MAX_GUILDBANK_TABS + 1; 9 when the constant is absent).
function Compat:BankMoneyTab()
  local max = self:Safe(self.env.MAX_GUILDBANK_TABS)
  return (type(max) == "number" and max or 8) + 1
end

function Compat:QueryBankLog(tab)
  local f = self.env.QueryGuildBankLog
  if f then f(tab) end
end

-- Seconds since an entry, from the game's years/months/days/hours-ago (month 30 d, year 365 d).
local function agoSeconds(y, mo, d, h)
  if type(y) ~= "number" or type(mo) ~= "number" or type(d) ~= "number" or type(h) ~= "number" then return nil end
  return ((y * 365 + mo * 30 + d) * 24 + h) * 3600
end

-- Item log of one tab: array of { type, name, item, count, tab, ago }, or nil when the API is
-- missing or the entry count is secret. An entry with any secret/unknown field is dropped alone.
function Compat:BankLog(tab)
  local env = self.env
  if not (env.GetNumGuildBankTransactions and env.GetGuildBankTransaction) then return nil end
  local n = self:Safe((env.GetNumGuildBankTransactions(tab)))
  if type(n) ~= "number" then return nil end
  local out = {}
  for i = 1, n do
    local rType, name, link, count, _, _, y, mo, d, h = env.GetGuildBankTransaction(tab, i)
    rType, name, link, count = self:Safe(rType), self:Safe(name), self:Safe(link), self:Safe(count)
    y, mo, d, h = self:Safe(y), self:Safe(mo), self:Safe(d), self:Safe(h)
    local ago = agoSeconds(y, mo, d, h)
    local id = type(link) == "string" and ns.Util.ItemIdFromLink(link) or nil
    if type(rType) == "string" and type(name) == "string" and name ~= "" and id
        and type(count) == "number" and ago then
      out[#out + 1] = { type = rType, name = name, item = id, count = count, tab = tab, ago = ago }
    end
  end
  return out
end

-- Money log: array of { type, name, copper, ago }, or nil (same rules as BankLog).
function Compat:BankMoneyLog()
  local env = self.env
  if not (env.GetNumGuildBankMoneyTransactions and env.GetGuildBankMoneyTransaction) then return nil end
  local n = self:Safe((env.GetNumGuildBankMoneyTransactions()))
  if type(n) ~= "number" then return nil end
  local out = {}
  for i = 1, n do
    local rType, name, amount, y, mo, d, h = env.GetGuildBankMoneyTransaction(i)
    rType, name, amount = self:Safe(rType), self:Safe(name), self:Safe(amount)
    local ago = agoSeconds(self:Safe(y), self:Safe(mo), self:Safe(d), self:Safe(h))
    if type(rType) == "string" and type(name) == "string" and name ~= "" and type(amount) == "number" and ago then
      out[#out + 1] = { type = rType, name = name, copper = amount, ago = ago }
    end
  end
  return out
end

-- A unit's name and realm as Name-Realm, or nil when the name is missing or secret.
function Compat:_fullName(name, realm)
  name, realm = self:Safe(name), self:Safe(realm)
  if type(name) ~= "string" or name == "" then return nil end
  local home = self.env.GetNormalizedRealmName and self:Safe(self.env.GetNormalizedRealmName()) or nil
  return ns.Util.FullName(name, type(realm) == "string" and realm or nil, type(home) == "string" and home or nil)
end

-- The current group: { members = {fullName...}, leader = fullName|nil, assists = {fullName...}, size },
-- or nil when not grouped, the size is unreadable, or fewer than 2 names can be read. Secret or nil
-- names are left out; a secret rank or leader flag makes that member neither leader nor assist.
-- In a raid the rank comes from GetRaidRosterInfo (2 leader, 1 assistant); in a party, from
-- UnitIsGroupLeader (a party has no assistants). A raid that cannot be read as one (IsInRaid
-- secret or missing with more than 5 members, or no GetRaidRosterInfo) gives nil, never a partial
-- snapshot with the wrong size.
function Compat:GroupSnapshot()
  local env = self.env
  if not (env.GetNumGroupMembers and env.UnitName) then return nil end
  local n = self:Safe((env.GetNumGroupMembers()))
  if type(n) ~= "number" or n < 2 then return nil end
  local members, assists, leader = {}, {}, nil
  local inRaid = env.IsInRaid and self:Safe((env.IsInRaid()))
  if type(inRaid) ~= "boolean" then
    if n > 5 then return nil end
    inRaid = false
  end
  if inRaid and not env.GetRaidRosterInfo then return nil end
  if inRaid then
    for i = 1, math.min(n, 40) do
      local rawName, rawRank = env.GetRaidRosterInfo(i)
      local name = self:_fullName(rawName)
      if name then
        members[#members + 1] = name
        local rank = self:Safe(rawRank)
        if rank == 2 then
          leader = name
        elseif rank == 1 then
          assists[#assists + 1] = name
        end
      end
    end
  else
    for i = 0, math.min(n, 5) - 1 do
      local unit = i == 0 and "player" or ("party" .. i)
      local name = self:_fullName(env.UnitName(unit))
      if name then
        members[#members + 1] = name
        if env.UnitIsGroupLeader and self:Safe((env.UnitIsGroupLeader(unit))) == true then leader = name end
      end
    end
  end
  if #members < 2 then return nil end
  return { members = members, leader = leader, assists = assists, size = n }
end

-- The current instance's id (GetInstanceInfo return 8, the Map ID), or nil when missing or secret.
function Compat:InstanceKey()
  local env = self.env
  if not env.GetInstanceInfo then return nil end
  local id = self:Safe((select(8, env.GetInstanceInfo())))
  return type(id) == "number" and id or nil
end

-- Guild calendar events from the day of fromT through the day of toT (epoch seconds, at most 15 days):
-- { { title, start (epoch), instance = keyOrNil, myStatus = "accepted"|"signedup"|"tentative"|"declined"|nil } },
-- ordered by (start, title). Guild events only. nil inside an instance, while chat is restricted, when the
-- calendar API is missing or when ANY value read is secret (a partial list is never returned).
-- Calendar times are server wall-clock; they are shifted by ServerOffset to epoch. The calendar is
-- asked to load (OpenCalendar, a read request) once per session.
local CAL_STATUS = { [3] = "accepted", [6] = "signedup", [8] = "tentative", [2] = "declined", [4] = "declined" }

local function civilDays(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function wordAt(lower, needle)
  local from = 1
  while true do
    local a, b = lower:find(needle, from, true)
    if not a then return false end
    local before, after = lower:sub(a - 1, a - 1), lower:sub(b + 1, b + 1)
    if not before:match("%w") and not after:match("%w") then return true end
    from = a + 1
  end
end

-- The Instances key a calendar title names (longest whole-word match of a name or short), or nil.
function Compat:_instanceFromTitle(title)
  local I = ns.Instances
  if not (I and I.LIST) or type(title) ~= "string" then return nil end
  local lower, best, bestLen = title:lower(), nil, 0
  for _, e in ipairs(I.LIST) do
    for _, w in ipairs({ e.name, e.short }) do
      local n = w:lower()
      if #n > bestLen and wordAt(lower, n) then best, bestLen = e.key, #n end
    end
  end
  return best
end

function Compat:GuildEvents(fromT, toT)
  local env = self.env
  local cal = env.C_Calendar
  if not (cal and cal.GetNumDayEvents and cal.GetDayEvent) or type(fromT) ~= "number" or type(toT) ~= "number" then
    return nil
  end
  if self:InstanceKey() ~= nil or self:IsRestricted("Chat") then return nil end
  local dateFn = env.date or os.date
  if not self.calOpened and cal.OpenCalendar then
    self.calOpened = true
    cal.OpenCalendar()
  end
  -- Event times use the real realm offset (ServerOffset), not cfg:Tz: the calendar reports realm
  -- wall-clock, which is what the offset converts to epoch; cfg:Tz is only the guild's chosen
  -- day boundary and may differ. An unknown offset means the times can't be trusted: read nothing.
  local offset = self:ServerOffset()
  if offset == nil then return nil end
  local cur = dateFn("!*t", fromT + offset)
  local statusMap = CAL_STATUS
  local enum = env.Enum and env.Enum.CalendarStatus
  if type(enum) == "table" then
    statusMap = {}
    for name, key in pairs({ Confirmed = "accepted", Signedup = "signedup", Tentative = "tentative",
        Declined = "declined", Out = "declined" }) do
      if type(enum[name]) == "number" then statusMap[enum[name]] = key end
    end
  end
  local out, seen = {}, {}
  local days = math.min(15, math.floor((toT - fromT) / 86400) + 1)
  for i = 0, days - 1 do
    local d = dateFn("!*t", fromT + offset + i * 86400)
    local monthOffset = (d.year - cur.year) * 12 + d.month - cur.month
    local n = cal.GetNumDayEvents(monthOffset, d.day)
    if self:_isSecret(n) then return nil end
    for idx = 1, type(n) == "number" and n or 0 do
      local info = cal.GetDayEvent(monthOffset, d.day, idx)
      if info ~= nil then
        if type(info) ~= "table" or self:_isSecret(info) then return nil end
        local title, ctype, st, status, iid = info.title, info.calendarType, info.startTime, info.inviteStatus,
          info.instanceID
        for _, v in ipairs({ title or false, ctype or false, status or false, iid or false }) do
          if v ~= false and self:_isSecret(v) then return nil end
        end
        if st ~= nil and (type(st) ~= "table" or self:_isSecret(st)) then return nil end
        local t
        if type(st) == "table" then
          for _, k in ipairs({ "year", "month", "monthDay", "hour", "minute" }) do
            if st[k] ~= nil and self:_isSecret(st[k]) then return nil end
          end
          if type(st.year) == "number" and type(st.month) == "number" and type(st.monthDay) == "number" then
            t = civilDays(st.year, st.month, st.monthDay) * 86400 + (tonumber(st.hour) or 0) * 3600
              + (tonumber(st.minute) or 0) * 60 - offset
          end
        end
        if ctype == "GUILD_EVENT" and type(title) == "string" and t then
          local key = title .. "|" .. t
          if not seen[key] then
            seen[key] = true
            local inst
            if type(iid) == "number" and ns.Instances and ns.Instances.LIST then
              for _, e in ipairs(ns.Instances.LIST) do
                if e.kind == "raid" and e.instanceId == iid then inst = e.key; break end
              end
            end
            out[#out + 1] = { title = title, start = t, instance = inst or self:_instanceFromTitle(title),
              myStatus = statusMap[status] }
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return a.title < b.title
  end)
  return out
end

-- The active talent group (1 or 2), or nil when there is no dual spec (API missing, one group) or
-- the value is secret.
function Compat:ActiveSpecGroup()
  local env = self.env
  if env.GetNumTalentGroups then
    local groups = self:Safe((env.GetNumTalentGroups()))
    if type(groups) == "number" and groups < 2 then return nil end
  end
  local g
  if env.GetActiveTalentGroup then
    g = self:Safe((env.GetActiveTalentGroup()))
  elseif env.C_SpecializationInfo and env.C_SpecializationInfo.GetActiveSpecGroup then
    g = self:Safe((env.C_SpecializationInfo.GetActiveSpecGroup()))
  end
  if g == 1 or g == 2 then return g end
  return nil
end

-- How many of an item the player carries, or nil when the API is missing or the count is secret.
function Compat:ItemCount(itemId)
  local env = self.env
  local f = env.C_Item and env.C_Item.GetItemCount or env.GetItemCount
  if not f then return nil end
  local n = self:Safe((f(itemId)))
  return type(n) == "number" and n or nil
end

-- Enchantable slots, in scan order. The off hand counts only for a weapon or shield.
local ENCHANT_SLOTS = {
  { 1, "Head" }, { 3, "Shoulder" }, { 5, "Chest" }, { 7, "Legs" }, { 8, "Feet" }, { 9, "Wrist" },
  { 10, "Hands" }, { 15, "Back" }, { 16, "Main hand" }, { 17, "Off hand" },
}
local OFF_HAND = 17
local CLASS_WEAPON, CLASS_ARMOR, SUBCLASS_SHIELD = 2, 4, 6

-- Names of the equipped enchantable slots without an enchant, or nil when the API is missing or
-- any link is secret (a partial answer could wrongly say "all enchanted"). Empty slots are
-- skipped. The enchant id is the third ':' field of the item string; 0 or empty is unenchanted.
-- A bare "item:123" link (no enchant field at all) is treated as unknown and not reported.
function Compat:UnenchantedSlots()
  local env = self.env
  if not env.GetInventoryItemLink then return nil end
  local out = {}
  for _, s in ipairs(ENCHANT_SLOTS) do
    local slot, label = s[1], s[2]
    local raw = env.GetInventoryItemLink("player", slot)
    if raw ~= nil and self:_isSecret(raw) then return nil end
    local link = self:Safe(raw)
    if type(link) == "string" then
      local enchant = link:match("item:[^:|]*:([^:|]*)")
      local counts = true
      if slot == OFF_HAND then
        local classId, subclassId
        if env.GetItemInfoInstant then
          local _, _, _, _, _, c, sc = env.GetItemInfoInstant(link)
          classId, subclassId = self:Safe(c), self:Safe(sc)
        end
        counts = classId == CLASS_WEAPON or (classId == CLASS_ARMOR and subclassId == SUBCLASS_SHIELD)
      end
      if counts and enchant ~= nil and (enchant == "" or tonumber(enchant) == 0) then
        out[#out + 1] = label
      end
    end
  end
  return out
end

ns.compat = Compat.new(_G)
