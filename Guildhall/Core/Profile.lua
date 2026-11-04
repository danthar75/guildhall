local ADDON, ns = ...

-- Player identity: a random id per WoW account plus the characters the player
-- has consented to link. Per-character decisions live in the account-wide
-- personal.profile.chars[fullName] = { guild = guildKey, included = true|false };
-- an entry with included == nil is "seen but undecided" (pending).
-- A Profile is bound to one guild (opts.guildKey): only entries whose guild matches
-- are asked about, published or claimed, so an alt in another guild never leaks into
-- this guild's profile. An entry with no guild (saved before guild scoping) belongs to
-- no guild; when that character next logs in, SeeCharacter stamps it with the current
-- guild and makes it pending, so it is re-asked once with the guild known. The same
-- happens when a character turns up in a different guild.
-- personal.profile.excluded is an array of excluded names (all guilds);
-- personal.profile.consented means "consented at least once".
local Profile = {}
ns.Profile = Profile
Profile.__index = Profile

local TTL = 2592000

function Profile.new(opts)
  local self = setmetatable({}, Profile)
  self.personal = opts.personal
  self.set = opts.set
  self.roster = opts.roster
  self.now = opts.now or function() return 0 end
  self.random = opts.random or math.random
  self.playerChar = opts.playerChar
  self.defaultRealm = opts.defaultRealm
  self.guildKey = opts.guildKey
  local p = self.personal
  p.profile = p.profile or {}
  p = p.profile
  p.excluded = p.excluded or {}
  p.chars = p.chars or {}
  if p.consented == nil then p.consented = false end
  self.p = p
  return self
end

function Profile:_norm(name)
  if type(name) ~= "string" or name == "" then return nil end
  return ns.Util.FullName(name, nil, self.defaultRealm)
end

function Profile:Id()
  if not self.p.id then
    local t = {}
    for i = 1, 12 do t[i] = string.format("%x", self.random(0, 15)) end
    self.p.id = table.concat(t)
  end
  return self.p.id
end

-- Records that fullName is logged in with this guild (see the header for migration).
function Profile:SeeCharacter(fullName)
  local n = self:_norm(fullName)
  if not n or self.guildKey == nil then return end
  local e = self.p.chars[n]
  if type(e) ~= "table" then
    self.p.chars[n] = { guild = self.guildKey }
  elseif e.guild ~= self.guildKey then
    e.guild, e.included = self.guildKey, nil
  end
end

function Profile:_inGuild(e)
  return type(e) == "table" and e.guild ~= nil and e.guild == self.guildKey
end

function Profile:_names(pred)
  local out = {}
  for name, e in pairs(self.p.chars) do
    if self:_inGuild(e) and pred(e) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- Every known character in this guild, decided or not (Settings, "Change...").
function Profile:GuildChars()
  return self:_names(function() return true end)
end

function Profile:PendingChars()
  return self:_names(function(e) return e.included == nil end)
end

function Profile:NeedsConsent()
  return #self:PendingChars() > 0
end

function Profile:Consent(excludedArray)
  local ex = {}
  for _, n in ipairs(excludedArray or {}) do
    local nn = self:_norm(n)
    if nn then ex[nn] = true end
  end
  for _, name in ipairs(self:PendingChars()) do
    self.p.chars[name].included = not ex[name]
  end
  local list = {}
  for name, e in pairs(self.p.chars) do
    if type(e) == "table" and e.included == false then list[#list + 1] = name end
  end
  table.sort(list)
  self.p.excluded = list
  self.p.consented = true
end

-- True when the player chose not to link fullName in this guild.
function Profile:IsExcluded(fullName)
  local n = self:_norm(fullName)
  local e = n and self.p.chars[n]
  return self:_inGuild(e) and e.included == false or false
end

function Profile:_included()
  return self:_names(function(e) return e.included == true end)
end

function Profile:Record()
  if not self.p.consented then return nil end
  local id = self:Id()
  local now = self.now()
  return {
    id = id,
    v = self.set:NextVersion(id),
    t = now,
    by = id,
    char = self.playerChar,
    exp = now + TTL,
    d = { chars = self:_included() },
  }
end

-- Valid, normalized chars of a peer record (tolerates malformed payloads).
function Profile:_recChars(rec)
  local out = {}
  local d = type(rec) == "table" and rec.d
  local chars = type(d) == "table" and d.chars
  if type(chars) ~= "table" then return out end
  for _, c in ipairs(chars) do
    local n = self:_norm(c)
    if n then out[#out + 1] = n end
  end
  return out
end

function Profile:OwnerOf(fullName)
  local target = self:_norm(fullName)
  if not target then return nil end
  local now = self.now()
  local best -- {t, id}
  local function consider(t, id)
    if type(t) ~= "number" or type(id) ~= "string" then return end
    if not best or t > best.t or (t == best.t and id > best.id) then
      best = { t = t, id = id }
    end
  end
  local myId = self.p.id
  local myRecListsIt = false
  for _, rec in ipairs(self.set:List(false)) do
    if type(rec.exp) == "number" and rec.exp > now then
      for _, c in ipairs(self:_recChars(rec)) do
        if c == target then
          consider(rec.t, rec.id)
          if rec.id == myId then myRecListsIt = true end
          break
        end
      end
    end
  end
  -- Our own locally included chars count before we publish.
  if not myRecListsIt and self.p.consented then
    local c = self.p.chars[target]
    if self:_inGuild(c) and c.included == true then consider(now, self:Id()) end
  end
  return best and best.id or nil
end

function Profile:IsMine(profileId)
  return profileId ~= nil and profileId == self:Id()
end

function Profile:CharsOf(profileId)
  if self:IsMine(profileId) then return self:_included() end
  local rec = self.set:Get(profileId)
  if not rec or rec.del then return {} end
  local out = {}
  local d = type(rec.d) == "table" and rec.d
  local chars = d and d.chars
  if type(chars) ~= "table" then return out end
  for _, c in ipairs(chars) do
    if type(c) == "string" then out[#out + 1] = c end
  end
  return out
end

function Profile:OnlineChar(profileId)
  for _, c in ipairs(self:CharsOf(profileId)) do
    if self.roster and self.roster:IsOnline(c) == true then return c end
  end
  return nil
end
