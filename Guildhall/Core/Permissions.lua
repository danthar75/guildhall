local ADDON, ns = ...

-- Guild-rank permissions: which guild ranks may do what. Only the guild master (rank 0) sets them.
--
-- Permissions.KEYS: ordered { key, label, raidlead = bool }. raidlead means the grant may also
--   cover the raid leader and assistants (the caller passes them in opts.raidLeaders).
-- Permissions.AddKey(def): lets a module add a key (the group finder adds its own).
-- Permissions.new(ctx) -> perms. ctx: config (LbConfig, may be attached later with
--   perms:Attach(config)), roster, profile, now, compat.
-- perms:Grants(key) -> { ranks = { [rankIndex] = true }, raidlead = bool }. Rank 0 is always in.
--   With no record (or no entry for the key) only rank 0 is granted, raidlead false.
-- perms:Can(char, key, opts) -> bool. opts.raidLeaders: a set { [char] = true } or an array.
-- perms:Publish(map) -> ok, err. map: { [key] = { ranks = set or array of rank indexes, raidlead } }.
-- perms:Validate(rec) -> ok, reason, for an incoming "perms" record of core.config.
--
-- The record is id "perms" in core.config: d.grants = { [key] = { ranks = {0, 1, ...}, raidlead } }.
-- It is checked against the roster only when it arrives (the author must be rank 0 then), so a
-- former guild master's record stays until the new one publishes. Unknown keys are kept so a
-- newer client's keys survive an older guild master's save.
local Permissions = {}
ns.Permissions = Permissions

local P = {}
P.__index = P

local RECORD = "perms"
local MAX_KEYS, MAX_KEY_LEN, MAX_LABEL, MAX_RANK = 32, 32, 64, 9
local GM_ONLY = "Only the guild master can change permissions."
Permissions.GM_ONLY = GM_ONLY

Permissions.KEYS = {
  { key = "weights", label = "Edit leaderboard weights", raidlead = false },
  { key = "retake", label = "Retake a month", raidlead = false },
  { key = "bankreview", label = "Review bank contributions", raidlead = false },
}

local function validKeyName(key)
  return type(key) == "string" and #key >= 1 and #key <= MAX_KEY_LEN
end

-- Adds a key at the end. Returns false for a bad or repeated key, or when the list is full.
function Permissions.AddKey(def)
  if type(def) ~= "table" or not validKeyName(def.key) then return false end
  if type(def.label) ~= "string" or #def.label > MAX_LABEL then return false end
  if #Permissions.KEYS >= MAX_KEYS then return false end
  for _, k in ipairs(Permissions.KEYS) do if k.key == def.key then return false end end
  Permissions.KEYS[#Permissions.KEYS + 1] = { key = def.key, label = def.label, raidlead = def.raidlead == true }
  return true
end

function Permissions.Label(key)
  for _, k in ipairs(Permissions.KEYS) do if k.key == key then return k.label end end
  return tostring(key)
end

function Permissions.AnyRaidLead()
  for _, k in ipairs(Permissions.KEYS) do if k.raidlead then return true end end
  return false
end

local function isRank(x)
  return type(x) == "number" and x == math.floor(x) and x >= 0 and x <= MAX_RANK
end

-- One stored grant: { ranks = array of distinct ints 0..9, raidlead = bool }.
local function validGrant(g)
  if type(g) ~= "table" or type(g.raidlead) ~= "boolean" or type(g.ranks) ~= "table" then return false end
  local n, seen = 0, {}
  for _ in pairs(g.ranks) do n = n + 1 end
  if n ~= #g.ranks or n > MAX_RANK + 1 then return false end
  for _, r in ipairs(g.ranks) do
    if not isRank(r) or seen[r] then return false end
    seen[r] = true
  end
  return true
end

-- A map of grants: at most 32 keys, each a valid grant. Used for the record and for history.
function Permissions.ValidGrants(map)
  if type(map) ~= "table" then return false, "bad grants" end
  local n = 0
  for key, g in pairs(map) do
    n = n + 1
    if n > MAX_KEYS then return false, "too many permission keys" end
    if not validKeyName(key) then return false, "bad permission key" end
    if not validGrant(g) then return false, "bad grant" end
  end
  return true
end

-- A grant in its stored form, rank 0 always in, ranks sorted. ranks may be a set
-- ({ [1] = true }) or an array ({ 0, 1 }). Returns nil for a rank out of range.
local function normalize(g)
  local set = { [0] = true }
  if type(g) == "table" and type(g.ranks) == "table" then
    for k, v in pairs(g.ranks) do
      local r
      if v == true then r = k elseif type(v) == "number" then r = v end
      if r ~= nil then
        if not isRank(r) then return nil end
        set[r] = true
      end
    end
  end
  local ranks = {}
  for r in pairs(set) do ranks[#ranks + 1] = r end
  table.sort(ranks)
  return { ranks = ranks, raidlead = type(g) == "table" and g.raidlead == true }
end

local function sameGrant(a, b)
  if a.raidlead ~= b.raidlead or #a.ranks ~= #b.ranks then return false end
  for i, r in ipairs(a.ranks) do if b.ranks[i] ~= r then return false end end
  return true
end

function Permissions.new(ctx)
  ctx = ctx or {}
  return setmetatable({ config = ctx.config, roster = ctx.roster, profile = ctx.profile, now = ctx.now,
    compat = ctx.compat, playerChar = ctx.playerChar }, P)
end

function P:Attach(config) self.config = config end

function P:_player() return self.playerChar or (self.config and self.config.playerChar) end

function P:_rank(char)
  local r = self.roster
  if type(char) ~= "string" or r == nil or r.RankIndex == nil then return nil end
  local rank = r:RankIndex(char)
  return type(rank) == "number" and rank or nil
end

-- The stored grants map, or nil while no record exists.
function P:_grants()
  local set = self.config and self.config.set
  local rec = set and set:Get(RECORD)
  if rec and not rec.del and type(rec.d) == "table" and type(rec.d.grants) == "table" then return rec.d.grants end
  return nil
end

function P:Grants(key)
  local stored = self:_grants()
  local g = normalize(stored and stored[key]) or normalize(nil)
  local ranks = {}
  for _, r in ipairs(g.ranks) do ranks[r] = true end
  return { ranks = ranks, raidlead = g.raidlead }
end

local function inLeaders(list, char)
  if type(list) ~= "table" then return false end
  if list[char] == true then return true end
  for _, c in ipairs(list) do if c == char then return true end end
  return false
end

function P:Can(char, key, opts)
  local rank = self:_rank(char)
  if rank == nil then return false end
  local g = self:Grants(key)
  if g.ranks[rank] then return true end
  return g.raidlead and type(opts) == "table" and inLeaders(opts.raidLeaders, char) or false
end

function P:IsGuildMaster(char) return self:_rank(char) == 0 end

-- Whether the local player may change permissions (the grid's checkboxes are enabled).
function P:Editable() return self:IsGuildMaster(self:_player()) end

-- Effective (normalized) grant of every key that is listed, stored or in `extra`.
function P:_effective(extra)
  local out, stored = {}, self:_grants() or {}
  local function add(key) if out[key] == nil then out[key] = normalize(stored[key]) or normalize(nil) end end
  for _, k in ipairs(Permissions.KEYS) do add(k.key) end
  for key in pairs(stored) do add(key) end
  for key in pairs(extra or {}) do add(key) end
  return out
end

function P:Publish(map)
  if not self:Editable() then return false, GM_ONLY end
  local config = self.config
  if not config then return false, "not available" end
  if type(map) ~= "table" then return false, "bad grants" end
  local grants = {}
  for key, g in pairs(self:_grants() or {}) do grants[key] = ns.Util.DeepCopy(g) end -- keeps unknown keys
  for key, g in pairs(map) do
    if not validKeyName(key) or type(g) ~= "table" then return false, "bad permission key" end
    local n = normalize(g)
    if not n then return false, "bad rank" end
    grants[key] = n
  end
  local ok, err = Permissions.ValidGrants(grants)
  if not ok then return false, err end
  local before = self:_effective(map)
  local good = config:_publish(RECORD, { grants = grants })
  if good then
    local after = self:_effective(map)
    local b, a = {}, {}
    for key, g in pairs(after) do
      if not sameGrant(before[key], g) then b[key], a[key] = before[key], g end
    end
    config:_safeLogHistory("perms", nil, b, a)
  end
  return good, (not good) and "not accepted" or nil
end

-- Incoming record: accepted only while the roster says its author is rank 0. An unknown roster
-- (or an author it doesn't list) rejects it for now; the next sync offers it again.
function P:Validate(rec)
  local r = self.roster
  if r == nil or r.RankIndex == nil or (r.HasRanks and r:HasRanks() ~= true) then return false, "roster unknown" end
  local rank = self:_rank(rec.char)
  if rank == nil then return false, "roster unknown" end
  if rank ~= 0 then return false, "author not the guild master" end
  if type(rec.d) ~= "table" then return false, "not a table" end
  return Permissions.ValidGrants(rec.d.grants)
end
