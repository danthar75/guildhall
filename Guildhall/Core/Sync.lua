local ADDON, ns = ...

-- Sync: keeps one ReplicatedSet in step across guild members over Comm.
--   REQ {have, after, to} -> peers answer (after a random wait) with the records we lack whose
--                            id is in (after, to]; nil bounds are open. Start pages the digest
--                            into sorted id ranges of PAGE entries so a large set never exceeds
--                            Comm's chunk cap. A REQ with no bounds (older peers) covers every id.
--   REC {rs = {records}} -> apply each record; every outcome is reported through onApplied
-- While a reply is pending, records other peers have already sent (same or higher version) are dropped.
--
-- Day buckets (opts.bucket = function(rec) -> day key string), for large sets:
--   DAYS {h = {[day] = hash}, after, to} -> Start sends these instead of paged REQs, at most
--                            DAYS_PAGE days each over sorted day ranges (after, to] (nil = open).
--                            A day's hash is Util.Hash of the sorted "id:v:t;" entries of the live
--                            records in it. A peer answers each day in range:
--                              - the sender lacks it: queue our records for it straight into the
--                                pending reply (random wait, suppressed by other peers' copies);
--                              - both hold it, or only the sender does, with different hashes:
--                                after a random wait, send our digest of it, unless another peer's
--                                REQ with the same digest of that day is heard first:
--   REQ {have, days, after, to} -> a digest of just those days. Several small days share one REQ
--                            (at most PAGE ids); a day over PAGE ids is paged into id ranges alone.
--                            Peers answer with the records in those days the sender lacks, and when
--                            the sender's have lists versions they lack, send their own REQ for those
--                            days (at most once per day per minInterval).
-- Without a bucket none of this is registered and the wire format above is unchanged.
local Sync = {}
Sync.__index = Sync

local BATCH = 5
local PAGE = 50          -- digest entries per REQ (about 2 KB, under 10 chunks)
local DAYS_PAGE = 200    -- day hashes per DAYS message
local MIN_INTERVAL = 60  -- seconds between Start() runs per set; extra calls coalesce into one later run

local function sortedKeys(t)
  local ids = {}
  for id in pairs(t) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

-- Integers as "%d", anything else as "%.17g", so every client hashes the same text.
local function num(x)
  if x == math.floor(x) and math.abs(x) < 2 ^ 53 then return string.format("%d", x) end
  return string.format("%.17g", x)
end

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
  self.bucket = opts.bucket
  self.counterAt = {}  -- day -> time of our last counter-REQ for it
  self.dayWant = nil   -- day -> true awaiting our delayed digest REQ; nil when no timer is scheduled
  self.comm:On(self.module, "REQ", function(p, sender) self:_onReq(p, sender) end)
  self.comm:On(self.module, "REC", function(p, sender) self:_onRec(p, sender) end)
  if self.bucket then
    self.comm:On(self.module, "DAYS", function(p, sender) self:_onDays(p, sender) end)
  end
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
  if self.bucket then
    local byDay = self:_days()
    local days = sortedKeys(byDay)
    local i, after, ok = 1, nil, true
    repeat
      local h, last = {}, nil
      for j = i, math.min(i + DAYS_PAGE - 1, #days) do
        h[days[j]] = self:_dayHash(byDay[days[j]])
        last = days[j]
      end
      i = i + DAYS_PAGE
      local to = i <= #days and last or nil -- the last page is open-ended
      if not self.comm:Send(self.module, "DAYS", { h = h, after = after, to = to }) then ok = false end
      after = last
    until i > #days
    return ok
  end
  self:_sendPaged(self.set:Digest(), nil)
  return true
end

-- Sends digest as REQs of at most PAGE entries over sorted id ranges (after, to]; the last page
-- is open-ended. days (optional) is copied onto every page.
function Sync:_sendPaged(digest, days)
  local ids = sortedKeys(digest)
  local i, after = 1, nil
  repeat
    local have, last = {}, nil
    for j = i, math.min(i + PAGE - 1, #ids) do
      have[ids[j]] = digest[ids[j]]
      last = ids[j]
    end
    i = i + PAGE
    local to = i <= #ids and last or nil -- the last page is open-ended
    self.comm:Send(self.module, "REQ", { have = have, after = after, to = to, days = days })
    after = last
  until i > #ids
end

-- Day key of a record, or nil when the bucket function fails or returns a non-string.
function Sync:_dayOf(rec)
  local ok, day = pcall(self.bucket, rec)
  if ok and type(day) == "string" then return day end
  return nil
end

-- day -> {id -> {v, t}} over live records.
function Sync:_days()
  local now, out = self.now(), {}
  for _, rec in ipairs(self.set:List(true)) do
    if rec.exp > now then
      local day = self:_dayOf(rec)
      if day then
        local d = out[day]
        if not d then d = {}; out[day] = d end
        d[rec.id] = { rec.v, rec.t }
      end
    end
  end
  return out
end

function Sync:_dayHash(entries)
  local parts = {}
  for _, id in ipairs(sortedKeys(entries)) do
    local e = entries[id]
    parts[#parts + 1] = id .. ":" .. num(e[1]) .. ":" .. num(e[2]) .. ";"
  end
  return ns.Util.Hash(table.concat(parts))
end

-- REQs carrying our digest of the given days (a sorted list).
function Sync:_sendDays(days)
  local byDay = self:_days()
  local group, have, n = {}, {}, 0
  local function flush()
    if #group == 0 then return end
    self.comm:Send(self.module, "REQ", { have = have, days = group })
    group, have, n = {}, {}, 0
  end
  for _, day in ipairs(days) do
    local entries = byDay[day] or {}
    local count = 0
    for _ in pairs(entries) do count = count + 1 end
    if count > PAGE then
      flush()
      self:_sendPaged(entries, { day })
    else
      if n + count > PAGE or #group >= PAGE then flush() end
      group[#group + 1] = day
      for id, e in pairs(entries) do have[id] = e end
      n = n + count
    end
  end
  flush()
end

function Sync:_onDays(p, sender)
  if type(p) ~= "table" or type(p.h) ~= "table" then return end
  local theirs = {}
  for day, hash in pairs(p.h) do
    if type(day) == "string" and type(hash) == "number" then theirs[day] = hash end
  end
  local lo = type(p.after) == "string" and p.after or nil
  local hi = type(p.to) == "string" and p.to or nil
  local function inRange(day) return (lo == nil or day > lo) and (hi == nil or day <= hi) end
  self.set:Purge()
  local byDay = self:_days()
  local lacks, differ = {}, {}
  for day, entries in pairs(byDay) do
    if inRange(day) then
      if theirs[day] == nil then lacks[day] = true
      elseif theirs[day] ~= self:_dayHash(entries) then differ[day] = true end
    end
  end
  for day in pairs(theirs) do
    if not byDay[day] and inRange(day) then differ[day] = true end
  end
  if next(lacks) then
    local recs = {}
    for _, rec in ipairs(self.set:List(true)) do
      if rec.exp > self.now() and lacks[self:_dayOf(rec) or false] then recs[#recs + 1] = rec end
    end
    self:_queue(recs)
  end
  if next(differ) then
    local fresh = self.dayWant == nil
    if fresh then self.dayWant = {} end
    for day in pairs(differ) do self.dayWant[day] = true end
    if fresh then
      self.after(self.random(1, 5), function() self:_flushDays() end)
    end
  end
end

function Sync:_flushDays()
  local want = self.dayWant
  self.dayWant = nil
  if not want then return end
  local days = sortedKeys(want)
  if #days > 0 then self:_sendDays(days) end
end

-- Another peer's unpaged REQ whose have equals our digest of its days already asks for
-- everything ours would: drop those days from our delayed REQ.
function Sync:_seeDaysReq(have, days, lo, hi)
  if not self.dayWant or lo ~= nil or hi ~= nil then return end
  local byDay = self:_days()
  local n = 0
  for _, day in ipairs(days) do
    for id, e in pairs(byDay[day] or {}) do
      local o = have[id]
      if type(o) ~= "table" or o[1] ~= e[1] or o[2] ~= e[2] then return end
      n = n + 1
    end
  end
  for _ in pairs(have) do n = n - 1 end
  if n ~= 0 then return end
  for _, day in ipairs(days) do self.dayWant[day] = nil end
end

-- A REQ naming days: answer with our records in those days the sender lacks, and ask back for
-- the versions its have lists that we lack.
function Sync:_onDaysReq(have, days, lo, hi)
  local want, list = {}, {}
  for _, day in ipairs(days) do
    if type(day) == "string" and not want[day] then
      want[day] = true
      list[#list + 1] = day
    end
  end
  if #list == 0 then return {} end
  self:_seeDaysReq(have, list, lo, hi)
  local missing = {}
  for _, r in ipairs(self.set:Missing(have, lo, hi)) do
    if want[self:_dayOf(r) or false] then missing[#missing + 1] = r end
  end
  local behind = false
  for id, e in pairs(have) do
    if type(id) == "string" and (lo == nil or id > lo) and (hi == nil or id <= hi)
      and type(e) == "table" and type(e[1]) == "number" and type(e[2]) == "number" then
      local cur = self.set:Get(id)
      if not cur or e[1] > cur.v or (e[1] == cur.v and e[2] > cur.t) then behind = true; break end
    end
  end
  if behind then
    local now, ask = self.now(), {}
    for _, day in ipairs(list) do
      local last = self.counterAt[day]
      if not last or now - last >= self.minInterval then
        self.counterAt[day] = now
        ask[#ask + 1] = day
      end
    end
    if #ask > 0 then
      table.sort(ask)
      self:_sendDays(ask)
    end
  end
  return missing
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
  local missing
  if self.bucket and type(p.days) == "table" then
    missing = self:_onDaysReq(have, p.days, lo, hi)
  else
    missing = self.set:Missing(have, lo, hi)
  end
  self:_queue(missing)
end

-- Adds records to the pending reply, scheduling its flush after a random wait.
function Sync:_queue(missing)
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
  -- Each REC must fit Comm's per-message limit once encoded, so batches are also split by size.
  local function fits(rs)
    if not self.comm.Fits then return true end
    return self.comm:Fits(self.module, "REC", { rs = rs })
  end
  local batch = {}
  local function send()
    if #batch > 0 then self.comm:Send(self.module, "REC", { rs = batch }) end
    batch = {}
  end
  for _, id in ipairs(ids) do
    local r = pending[id]
    if not fits({ r }) then
      self.oversize = self.oversize or {}
      if ns.OnError and not self.oversize[id] then
        self.oversize[id] = true
        ns.OnError("Sync " .. tostring(self.module) .. ": record too large to send: " .. id)
      end
    else
      batch[#batch + 1] = r
      if #batch > 1 and not fits(batch) then
        batch[#batch] = nil
        send()
        batch[1] = r
      end
      if #batch == BATCH then send() end
    end
  end
  send()
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
