local ADDON, ns = ...

-- Guild roster cache + Guild Info tag config. Online status is session-only (never persisted);
-- rank indexes persist in `cache.ranks` so IsOfficer keeps working when the roster is secret.
-- Secret values are never stored: a secret online flag becomes "unknown" (nil).
local Roster = {}
Roster.__index = Roster
ns.Roster = Roster

local DEFAULT_OFFICERS = 2

-- "[Guildhall key=val key2=val]" -> { key = val, ... }. Numbers converted. Never raises.
function Roster.ParseTag(text)
  local out = {}
  if type(text) ~= "string" then return out end
  -- Every [Guildhall ...] tag counts; keys merge (a later tag wins a repeated key).
  for body in text:gmatch("%[Guildhall%s+([^%]]*)%]") do
    body = body:gsub("%s*,%s*(%d)", ",%1") -- "donations=3, 4" reads like "donations=3,4"
    for k, v in body:gmatch("([%w_]+)=(%S+)") do
      v = v:gsub(",+$", "") -- a comma between two settings belongs to neither
      out[k] = tonumber(v) or v
    end
  end
  return out
end

function Roster.new(compat, cache)
  cache.ranks = cache.ranks or {}
  cache.guildConfig = cache.guildConfig or {}
  return setmetatable({ compat = compat, cache = cache, members = {} }, Roster)
end

function Roster:Norm(fullName)
  if type(fullName) ~= "string" or fullName == "" then return nil end
  local player = self.compat:PlayerFullName()
  local realm = type(player) == "string" and player:match("%-(.+)$") or nil
  return ns.Util.FullName(fullName, nil, realm)
end

function Roster:Refresh()
  local compat = self.compat
  compat:RequestRoster()
  local members, ranks, count = {}, {}, 0
  for i = 1, compat:GetNumGuildMembers() do
    local name, rankIndex, isOnline = compat:GetGuildRosterInfo(i)
    if type(name) == "string" and name ~= "" and type(rankIndex) == "number" then
      local key = self:Norm(name)
      local online -- nil = unknown (secret or unreadable)
      if type(isOnline) == "boolean" then online = isOnline end
      members[key] = { online = online }
      ranks[key] = rankIndex
      count = count + 1
    end
  end
  self.members = members -- online status is per-refresh; unreadable roster means unknown
  if count > 0 then self.cache.ranks = ranks end
  if not compat:IsRestricted("Map") then
    local text = compat:GetGuildInfoText()
    if type(text) == "string" then self.cache.guildConfig = Roster.ParseTag(text) end
  end
end

function Roster:IsOnline(fullName)
  local m = self.members[self:Norm(fullName)]
  return m and m.online
end

function Roster:RankIndex(fullName)
  local key = self:Norm(fullName)
  if not key then return nil end
  return self.cache.ranks[key]
end

-- True once a roster has been read (rank cache non-empty).
function Roster:HasRanks()
  return next(self.cache.ranks) ~= nil
end

function Roster:OfficerThreshold()
  local n = self.cache.guildConfig and self.cache.guildConfig.officers
  return type(n) == "number" and n or DEFAULT_OFFICERS
end

-- A tag value as an array of integers: "3,4" -> {3, 4}, 3 -> {3}, missing -> {}.
function Roster:ConfigList(key)
  local v = self.cache.guildConfig and self.cache.guildConfig[key]
  local out = {}
  if type(v) == "number" then
    out[1] = v
  elseif type(v) == "string" then
    for n in v:gmatch("[^,]+") do
      local x = tonumber(n)
      if x and x == math.floor(x) then out[#out + 1] = x end
    end
  end
  return out
end

function Roster:IsOfficer(fullName)
  local rank = self:RankIndex(fullName)
  if rank == nil then return nil end
  return rank < self:OfficerThreshold()
end
