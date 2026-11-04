local ADDON, ns = ...

local Theme = {}
ns.Theme = Theme

local values = {
  title = "Guildhall",
  accent = { 1, 0.82, 0 },
  border = { 0.42, 0.35, 0.23 },
  logo = nil,
  banner = nil,
}

-- Returns a copy for table values so callers cannot mutate the tokens.
function Theme.Get(key)
  return ns.Util.DeepCopy(values[key])
end

function Theme.Set(overrides)
  if type(overrides) ~= "table" then return end
  for k, v in pairs(overrides) do values[k] = ns.Util.DeepCopy(v) end
end
