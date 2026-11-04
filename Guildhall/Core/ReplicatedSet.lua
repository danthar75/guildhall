local ADDON, ns = ...

local ReplicatedSet = {}
ns.ReplicatedSet = ReplicatedSet

local Set = {}
Set.__index = Set

local function copy(rec)
  if ns.Util and ns.Util.DeepCopy then return ns.Util.DeepCopy(rec) end
  local out = {}
  for k, v in pairs(rec) do out[k] = v end
  return out
end

-- Tuple (v, t, del, char), compared left to right. Returns true if a > b.
local function greater(a, b)
  if a.v ~= b.v then return a.v > b.v end
  if a.t ~= b.t then return a.t > b.t end
  local ad, bd = a.del and 1 or 0, b.del and 1 or 0
  if ad ~= bd then return ad > bd end
  return (a.char or "") > (b.char or "")
end

ReplicatedSet.Greater = greater

local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

function ReplicatedSet.new(name, store, opts)
  opts = opts or {}
  local self = setmetatable({}, Set)
  self.name = name
  self.store = store
  self.now = opts.now or function() return 0 end
  self.maxFuture = opts.maxFuture or 86400
  self.onChange = opts.onChange
  self.validate = opts.validate
  return self
end

function Set:Get(id)
  return self.store[id]
end

function Set:List(includeDeleted)
  local out = {}
  for _, rec in pairs(self.store) do
    if includeDeleted or not rec.del then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.id < b.id
  end)
  return out
end

function Set:Apply(rec)
  if type(rec) ~= "table" or type(rec.id) ~= "string" or rec.id == ""
    or not finite(rec.v) or not finite(rec.t) or not finite(rec.exp)
    or (rec.char ~= nil and type(rec.char) ~= "string")
    or (rec.del ~= nil and type(rec.del) ~= "boolean") then
    return "invalid"
  end
  if self.validate then
    local ok = self.validate(rec)
    if not ok then return "invalid" end
  end
  local now = self.now()
  if rec.exp <= now then return "expired", self.store[rec.id] end
  if rec.t > now + self.maxFuture then return "future", self.store[rec.id] end
  local old = self.store[rec.id]
  if old and not greater(rec, old) then return "stale", old end
  local stored = copy(rec)
  self.store[rec.id] = stored
  if self.onChange then self.onChange(stored, old) end
  return "accepted", old
end

function Set:Purge()
  local now, n = self.now(), 0
  local dead = {}
  for id, rec in pairs(self.store) do
    if rec.exp <= now then dead[#dead + 1] = id end
  end
  for _, id in ipairs(dead) do
    self.store[id] = nil
    n = n + 1
  end
  return n
end

-- Digest: id -> {v, t}. Missing compares (v, t) so same-version divergent copies still converge.
function Set:Digest()
  local d = {}
  for id, rec in pairs(self.store) do d[id] = { rec.v, rec.t } end
  return d
end

-- after/to (optional strings) limit the result to ids in (after, to].
function Set:Missing(digest, after, to)
  local now, out = self.now(), {}
  if type(digest) ~= "table" then digest = {} end
  for id, rec in pairs(self.store) do
    local inRange = (after == nil or id > after) and (to == nil or id <= to)
    local e = digest[id]
    local pv, pt
    if type(e) == "table" and finite(e[1]) and finite(e[2]) then pv, pt = e[1], e[2] end
    if inRange and rec.exp > now and (pv == nil or rec.v > pv or (rec.v == pv and rec.t > pt)) then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function Set:NextVersion(id)
  local rec = self.store[id]
  return rec and (rec.v + 1) or 1
end
