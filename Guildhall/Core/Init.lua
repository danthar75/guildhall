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

-- About text for the welcome screen and About tab that no module owns. Modules supply their own
-- as def.about = { title, lines, order }; order places a section (Exchange 10, these 20 and 40,
-- Leaderboard 30). Plain ASCII only.
ns.CoreAbout = {
  { title = "Linked characters", order = 20, lines = {
    "Guildmates reach you on whichever character you're on. Only the characters you choose are shared.",
  } },
  { title = "Log and Settings", order = 40, lines = {
    "See every change in the Log, and adjust your message templates in Settings.",
  } },
}

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
