local M = {}

function M.clock(start)
  local t = start or 0
  return {
    now = function() return t end,
    advance = function(s) t = t + s end,
  }
end

-- timers(clock?): if a clock is given, delays are measured from its time at after() call (else from 0).
function M.timers(clock0)
  local pending = {}
  local self = {}
  function self.after(delay, cb)
    pending[#pending + 1] = { delay = delay, cb = cb, base = clock0 and clock0.now() or 0 }
  end
  function self.run(clock)
    local now = clock.now()
    local keep = {}
    local due = {}
    for _, p in ipairs(pending) do
      if p.base + p.delay <= now then due[#due + 1] = p else keep[#keep + 1] = p end
    end
    pending = keep
    for _, p in ipairs(due) do p.cb() end
  end
  return self
end

-- compat(overrides): a real Compat instance over a fake env. overrides are merged into the env;
-- the env exposes env.sent (count of C_ChatInfo.SendAddonMessage calls).
function M.compat(overrides)
  local ns = {}
  loadAddonFile(ns, "Guildhall/Core/Util.lua")
  loadAddonFile(ns, "Guildhall/Core/Compat.lua")
  -- the addon shares one namespace: Compat:InstanceKey matches map ids against ns.Instances
  loadAddonFile(ns, "Guildhall/Modules/Groups/Instances.lua")
  local env = { sent = 0, GetServerTime = function() return 1000 end }
  for k, v in pairs(overrides or {}) do env[k] = v end
  return ns.Compat.new(env), env
end

-- bus(clock, timers, commOpts?): a fake guild channel. bus:join("Name-Realm") returns that member's
-- real Comm (own ns, own Compat). Every line a member sends is delivered synchronously, in order,
-- to every other member's comm:Receive(prefix, line, "GUILD", senderFullName). Deterministic.
-- commOpts are merged into each Comm's options (e.g. a larger burst for multi-chunk traffic).
function M.bus(clock, timers, commOpts)
  local bus = { members = {}, order = {} }
  function bus:join(name)
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Serialize.lua")
    loadAddonFile(ns, "Guildhall/Core/Comm.lua")
    local compat = M.compat({
      C_ChatInfo = { SendAddonMessage = function(prefix, line, channel)
        for _, other in ipairs(bus.order) do
          if other ~= name then bus.members[other]:Receive(prefix, line, channel, name) end
        end
        return 0
      end },
    })
    local opts = { compat = compat, now = clock.now, after = timers.after, playerName = name, burst = 100 }
    for k, v in pairs(commOpts or {}) do opts[k] = v end
    local comm = ns.Comm.new(opts)
    bus.members[name] = comm
    bus.order[#bus.order + 1] = name
    return comm
  end
  return bus
end

-- widgets(): a permissive fake of WoW frames for UI specs. Every widget accepts any method
-- call (recorded in w.calls[method] as arrays of args) and returns nil, except: Create*/
-- CreateTexture/CreateFontString return a new widget, GetText returns the last SetText,
-- IsShown/IsVisible follow Show/Hide, GetChecked follows SetChecked. W.created lists
-- {type, widget} for each CreateFrame call; W.CreateFrame is the global to install.
function M.widgets()
  local W = { created = {} }
  local function new(kind)
    local w = { kind = kind, calls = {}, shown = false }
    return setmetatable(w, { __index = function(t, k)
      local f = function(self, ...)
        local list = self.calls[k]
        if not list then list = {}; self.calls[k] = list end
        list[#list + 1] = { ... }
        if k == "CreateTexture" or k == "CreateFontString" then return new(k) end
        if k == "SetText" then self.text = (...) end
        if k == "GetText" then return self.text end
        if k == "Show" then self.shown = true end
        if k == "Hide" then self.shown = false end
        if k == "IsShown" or k == "IsVisible" then return self.shown end
        if k == "SetChecked" then self.checked = (...) and true or false end
        if k == "GetChecked" then return self.checked end
        if k == "GetStringHeight" or k == "GetWidth" or k == "GetFrameLevel" then return 10 end
        return nil
      end
      rawset(t, k, f)
      return f
    end })
  end
  W.new = new
  -- Like the real client, an EditBox's SetText fires its OnTextChanged handler (userInput false).
  local function fireOnSetText(w)
    local handlers = {}
    rawset(w, "SetScript", function(self, event, fn)
      self.calls.SetScript = self.calls.SetScript or {}
      table.insert(self.calls.SetScript, { event, fn })
      handlers[event] = fn
    end)
    rawset(w, "SetText", function(self, text)
      self.calls.SetText = self.calls.SetText or {}
      table.insert(self.calls.SetText, { text })
      self.text = text
      if handlers.OnTextChanged then handlers.OnTextChanged(self, false) end
    end)
  end
  function W.CreateFrame(kind)
    local w = new(kind)
    if kind == "EditBox" then fireOnSetText(w) end
    W.created[#W.created + 1] = { kind, w }
    return w
  end
  function W.ofKind(kind)
    local out = {}
    for _, c in ipairs(W.created) do if c[1] == kind then out[#out + 1] = c[2] end end
    return out
  end
  return W
end

return M
