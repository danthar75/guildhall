local ADDON, ns = ...

-- Comm: guild addon traffic. Envelope -> chunks -> token-bucket queue -> SendAddon; and the reverse.
local Comm = {}
Comm.__index = Comm

local HEADER_RESERVE = 10   -- "999:64/64:"
local MAX_CHUNKS = 64
local EXPIRY = 30
local THROTTLE_RETRY, LOCKDOWN_RETRY = 2, 5

function Comm.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Comm)
  self.compat = opts.compat
  self.now = opts.now
  self.after = opts.after
  self.prefix = opts.prefix or "Guildhall"
  self.maxBytes = opts.maxBytes or 255
  self.burst = opts.burst or 10
  self.refill = opts.refill or 1
  self.onIgnored = opts.onIgnored or function() end
  self.playerName = opts.playerName
  self.handlers = {}
  self.queue = {}
  self.head = 1
  self.tail = 0
  self.assembly = {}
  self.seq = 0
  self.recentSenders = {} -- raw sender strings, newest last (diagnostic: /gh names)
  self.tokens = self.burst
  self.lastRefill = self.now()
  self.retryPending = false
  return self
end

function Comm:On(module, kind, handler)
  local m = self.handlers[module]
  if not m then m = {}; self.handlers[module] = m end
  m[kind] = handler
end

function Comm:Pending() return self.tail - self.head + 1 end

function Comm:_push(line)
  self.tail = self.tail + 1
  self.queue[self.tail] = line
end

function Comm:_pushFront(line)
  self.head = self.head - 1
  self.queue[self.head] = line
end

function Comm:_pop()
  local line = self.queue[self.head]
  self.queue[self.head] = nil
  self.head = self.head + 1
  return line
end

function Comm:Send(module, kind, payload)
  local body = ns.Serialize.Encode({ pv = 1, m = module, k = kind, p = payload })
  local size = self.maxBytes - HEADER_RESERVE
  local n = math.max(1, math.ceil(#body / size))
  if n > MAX_CHUNKS then
    self.onIgnored(nil, "too large")
    return false
  end
  self.seq = (self.seq + 1) % 1000
  for i = 1, n do
    local slice = body:sub((i - 1) * size + 1, i * size)
    self:_push(self.seq .. ":" .. i .. "/" .. n .. ":" .. slice)
  end
  self:Pump()
  return true
end

function Comm:_schedule(delay)
  if self.retryPending then return end
  self.retryPending = true
  self.after(delay, function()
    self.retryPending = false
    self:Pump()
  end)
end

function Comm:Pump()
  self:_expire()
  local t = self.now()
  self.tokens = math.min(self.burst, self.tokens + (t - self.lastRefill) * self.refill)
  self.lastRefill = t
  while self:Pending() > 0 do
    if self.tokens < 1 - 1e-9 then
      self:_schedule((1 - self.tokens) / self.refill)
      return
    end
    local line = self:_pop()
    local r = self.compat:SendAddon(self.prefix, line)
    if r == "ok" then
      self.tokens = self.tokens - 1
    elseif r == "throttle" then
      self:_pushFront(line)
      self:_schedule(THROTTLE_RETRY)
      return
    elseif r == "lockdown" then
      self:_pushFront(line)
      self:_schedule(LOCKDOWN_RETRY)
      return
    else
      self.onIgnored(nil, "send error")
    end
  end
end

function Comm:_expire()
  local t = self.now()
  for key, set in pairs(self.assembly) do
    if t - set.first > EXPIRY then self.assembly[key] = nil end
  end
end

function Comm:Receive(prefix, msg, channel, sender)
  local compat = self.compat
  prefix, msg, channel, sender = compat:Safe(prefix), compat:Safe(msg), compat:Safe(channel), compat:Safe(sender)
  if type(prefix) ~= "string" or type(msg) ~= "string" or type(channel) ~= "string" or type(sender) ~= "string" then
    return
  end
  if prefix ~= self.prefix or channel ~= "GUILD" then return end
  local own = self.playerName or compat:PlayerFullName()
  local full = ns.Util.FullName(sender, nil, own:match("%-(.+)$"))
  local rs = self.recentSenders
  if rs[#rs] ~= sender then
    rs[#rs + 1] = sender
    if #rs > 5 then table.remove(rs, 1) end
  end
  if full == own then return end
  self:_expire()

  local seq, i, n, slice = msg:match("^(%d+):(%d+)/(%d+):(.*)$")
  i, n = tonumber(i), tonumber(n)
  if not (seq and i and n and n >= 1 and n <= MAX_CHUNKS and i >= 1 and i <= n) then
    self.onIgnored(full, "bad chunk")
    return
  end
  local body
  if n == 1 then
    body = slice
  else
    local key = full .. seq
    local set = self.assembly[key]
    if set and set.n ~= n then
      self.assembly[key] = nil
      self.onIgnored(full, "bad chunk")
      return
    end
    if not set then
      set = { n = n, parts = {}, count = 0, first = self.now() }
      self.assembly[key] = set
    end
    if not set.parts[i] then set.count = set.count + 1 end
    set.parts[i] = slice
    if set.count < n then return end
    self.assembly[key] = nil
    body = table.concat(set.parts)
  end
  self:_dispatch(full, body)
end

function Comm:_dispatch(sender, body)
  local env = ns.Serialize.Decode(body)
  if type(env) ~= "table" or type(env.m) ~= "string" or type(env.k) ~= "string" then
    self.onIgnored(sender, "bad payload")
    return
  end
  local mod = self.handlers[env.m]
  local handler = mod and mod[env.k]
  if not handler then
    self.onIgnored(sender, "unknown " .. env.m .. "/" .. env.k)
    return
  end
  local ok, err = pcall(handler, env.p, sender)
  if not ok then self.onIgnored(sender, "handler error: " .. tostring(err)) end
end

ns.Comm = Comm
