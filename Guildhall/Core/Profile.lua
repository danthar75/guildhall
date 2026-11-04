local ADDON, ns = ...

-- Player identity: a random id per WoW account plus the characters the player
-- has consented to link. Per-character decisions live in
-- personal.profile.chars[fullName] = { included = true|false }; an entry with
-- included == nil is "seen but undecided" (pending). personal.profile.excluded
-- is an array of excluded names; personal.profile.consented means "consented
-- at least once".
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

function Profile:SeeCharacter(fullName)
  local n = self:_norm(fullName)
  if n and not self.p.chars[n] then self.p.chars[n] = {} end
end

local function sortedNames(chars, pred)
  local out = {}
  for name, e in pairs(chars) do
    if type(e) == "table" and pred(e) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

function Profile:PendingChars()
  return sortedNames(self.p.chars, function(e) return e.included == nil end)
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
  local list = sortedNames(self.p.chars, function(e) return e.included == false end)
  self.p.excluded = list
  self.p.consented = true
end

function Profile:_included()
  return sortedNames(self.p.chars, function(e) return e.included == true end)
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
    if c and c.included == true then consider(now, self:Id()) end
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
