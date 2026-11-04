local ADDON, ns = ...

-- Module registry ----------------------------------------------------------
local modules, order = {}, {}

function ns.RegisterModule(name, def)
  if modules[name] then error("module already registered: " .. tostring(name), 2) end
  modules[name] = def
  order[#order + 1] = name
  return def
end

function ns.GetModule(name) return modules[name] end

function ns.Modules()
  local out = {}
  for i, n in ipairs(order) do out[i] = n end
  return out
end

-- Event bus ----------------------------------------------------------------
function ns.OnError(err) print(err) end

local handlers = {}
ns.Events = {}

function ns.Events:On(event, fn)
  local list = handlers[event]
  if not list then list = {}; handlers[event] = list end
  list[#list + 1] = fn
end

function ns.Events:Fire(event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], ...)
    if not ok then ns.OnError(err) end
  end
end
