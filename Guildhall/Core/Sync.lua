local ADDON, ns = ...

-- Sync: keeps one ReplicatedSet in step across guild members over Comm.
--   REQ {have, after, to} -> peers answer (after a random wait) with the records we lack whose
--                            id is in (after, to]; nil bounds are open. Start pages the digest
--                            into sorted id ranges of PAGE entries so a large set never exceeds
--                            Comm's chunk cap. A REQ with no bounds (older peers) covers every id.
--   REC {rs = {records}} -> apply each record; every outcome is reported through onApplied
-- While a reply is pending, records other peers have already sent (same or higher version) are dropped.
local Sync = {}
Sync.__index = Sync

local BATCH = 5
local PAGE = 50          -- digest entries per REQ (about 2 KB, under 10 chunks)
local MIN_INTERVAL = 60  -- seconds between Start() runs per set; extra calls coalesce into one later run

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
  self.now = opts.now or (opts.set and opts.set.now) or function() return 0 end
  self.minInterval = opts.minInterval or MIN_INTERVAL
  self.lastStart = nil
  self.startQueued = false
  self.pending = nil   -- id -> record awaiting a reply; nil when no timer is scheduled
  self.comm:On(self.module, "REQ", function(p, sender) self:_onReq(p, sender) end)
  self.comm:On(self.module, "REC", function(p, sender) self:_onRec(p, sender) end)
  return self
end

-- Asks peers for what we lack. Returns true when REQs were sent, false when rate-limited
-- (a single trailing run is then scheduled for when the interval ends).
function Sync:Start()
  local now = self.now()
  if self.lastStart and now - self.lastStart < self.minInterval then
    if not self.startQueued then
      self.startQueued = true
      self.after(self.lastStart + self.minInterval - now, function()
        self.startQueued = false
        self:Start()
      end)
    end
    return false
  end
  self.lastStart = now
  self.set:Purge()
  local digest = self.set:Digest()
  local ids = {}
  for id in pairs(digest) do ids[#ids + 1] = id end
  table.sort(ids)
  local i, after = 1, nil
  repeat
    local have, last = {}, nil
    for j = i, math.min(i + PAGE - 1, #ids) do
      have[ids[j]] = digest[ids[j]]
      last = ids[j]
    end
    i = i + PAGE
    local to = i <= #ids and last or nil -- the last page is open-ended
    self.comm:Send(self.module, "REQ", { have = have, after = after, to = to })
    after = last
  until i > #ids
  return true
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
  if type(p) ~= "table" then p = {} end
  local have = type(p.have) == "table" and p.have or {}
  local lo = type(p.after) == "string" and p.after or nil
  local hi = type(p.to) == "string" and p.to or nil
  local missing = self.set:Missing(have, lo, hi)
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
