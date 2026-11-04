local ADDON, ns = ...

-- Sync: keeps one ReplicatedSet in step across guild members over Comm.
--   REQ {have = digest}  -> peers answer (after a random wait) with the records we lack
--   REC {rs = {records}} -> apply each record; every outcome is reported through onApplied
-- While a reply is pending, records other peers have already sent (same or higher version) are dropped.
local Sync = {}
Sync.__index = Sync

local BATCH = 5

function Sync.new(opts)
  local self = setmetatable({}, Sync)
  self.comm = opts.comm
  self.set = opts.set
  self.module = opts.module
  self.after = opts.after
  self.random = opts.random or function(lo) return lo end
  self.validate = opts.validate
  self.onApplied = opts.onApplied or function() end
  self.playerName = opts.playerName
  self.pending = nil   -- id -> record awaiting a reply; nil when no timer is scheduled
  self.comm:On(self.module, "REQ", function(p, sender) self:_onReq(p, sender) end)
  self.comm:On(self.module, "REC", function(p, sender) self:_onRec(p, sender) end)
  return self
end

function Sync:Start()
  self.comm:Send(self.module, "REQ", { have = self.set:Digest() })
end

function Sync:Publish(rec)
  -- Publish skips validate on purpose: the data is local.
  local status, old = self.set:Apply(rec)
  local reason = status == "invalid" and "malformed" or nil
  self.onApplied(rec, status, old, self.playerName or "self", reason)
  if status == "accepted" then
    self.comm:Send(self.module, "REC", { rs = { rec } })
  end
  return status
end

function Sync:_onReq(p, sender)
  local have = type(p) == "table" and type(p.have) == "table" and p.have or {}
  local missing = self.set:Missing(have)
  if #missing == 0 then return end
  local fresh = self.pending == nil
  if fresh then self.pending = {} end
  local pending = self.pending
  for _, r in ipairs(missing) do
    local cur = pending[r.id]
    if not cur or r.v > cur.v then pending[r.id] = r end
  end
  if fresh then
    self.after(self.random(1, 5), function() self:_flush() end)
  end
end

function Sync:_flush()
  local pending = self.pending
  self.pending = nil
  if not pending then return end
  local ids = {}
  for id in pairs(pending) do ids[#ids + 1] = id end
  table.sort(ids)
  local batch = {}
  for _, id in ipairs(ids) do
    batch[#batch + 1] = pending[id]
    if #batch == BATCH then
      self.comm:Send(self.module, "REC", { rs = batch })
      batch = {}
    end
  end
  if #batch > 0 then self.comm:Send(self.module, "REC", { rs = batch }) end
end

-- Drop our pending copy only if the peer's is Greater or identical on the full (v, t, del, char) tuple.
function Sync:_suppress(r)
  local pending = self.pending
  if not pending or type(r.id) ~= "string" then return end
  local cur = pending[r.id]
  if not cur then return end
  local G = ns.ReplicatedSet.Greater
  local same = r.v == cur.v and r.t == cur.t and (r.del or false) == (cur.del or false) and (r.char or "") == (cur.char or "")
  if same or G(r, cur) then pending[r.id] = nil end
end

function Sync:_onRec(p, sender)
  if type(p) ~= "table" or type(p.rs) ~= "table" then return end
  for _, r in ipairs(p.rs) do
    if type(r) == "table" then
      local status = self:_applyOne(r, sender)
      if status ~= "invalid" then self:_suppress(r) end
    end
  end
end

-- Returns the reported status.
function Sync:_applyOne(r, sender)
  local reason
  if self.validate and type(r.id) == "string" then
    local ok, valid, why = pcall(self.validate, r, self.set:Get(r.id), sender)
    if not ok then
      self.onApplied(r, "invalid", self.set:Get(r.id), sender, "validate error: " .. tostring(valid))
      return "invalid"
    end
    if not valid then
      self.onApplied(r, "invalid", self.set:Get(r.id), sender, why)
      return "invalid"
    end
    reason = why
  end
  local status, old, why = self.set:Apply(r)
  if status == "invalid" then reason = why or "malformed" elseif status ~= "accepted" then reason = nil end
  self.onApplied(r, status, old, sender, reason)
  return status
end

ns.Sync = Sync
