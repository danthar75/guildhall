local ADDON, ns = ...

-- Activity registry for the Leaderboard. Modules register what can be scored (id, label, unit,
-- verification level, weight, display order) and the derivers that turn observations into
-- contributions. Gold values are copper; weight is per gold, so points = copper / 10000 * weight.
ns.Activity = ns.Activity or {}
local Activity = ns.Activity

local UNITS = { count = true, gold = true, items = true }
local VERIFY = { paired = true, confirmed = true, self = true }

local defs, derivers = {}, {}

function Activity.Register(def)
  assert(type(def) == "table", "Activity.Register: def must be a table")
  assert(type(def.id) == "string" and def.id ~= "", "Activity.Register: bad id")
  assert(type(def.label) == "string", "Activity.Register: bad label")
  assert(UNITS[def.unit], "Activity.Register: bad unit")
  assert(VERIFY[def.verify], "Activity.Register: bad verify")
  assert(type(def.weight) == "number", "Activity.Register: bad weight")
  assert(type(def.order) == "number", "Activity.Register: bad order")
  if defs[def.id] then error("Activity.Register: duplicate id " .. def.id, 2) end
  defs[def.id] = def
end

function Activity.Types()
  local out = {}
  for _, d in pairs(defs) do out[#out + 1] = d end
  table.sort(out, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
  end)
  return out
end

function Activity.Get(id) return defs[id] end

-- fn(obsList, ctx) -> array of Contribution (ctx is defined by Ledger).
function Activity.RegisterDeriver(kind, fn)
  assert(type(kind) == "string" and type(fn) == "function", "Activity.RegisterDeriver: bad args")
  derivers[kind] = fn
end

function Activity.Deriver(kind) return derivers[kind] end
