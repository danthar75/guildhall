local ADDON, ns = ...

local DB = {}
ns.DB = DB

local SCHEMA = 1

local function defaults()
  return {
    schema = SCHEMA,
    personal = {
      profile = { consented = false, excluded = {}, chars = {} },
      templates = {},
      window = {},
    },
    guilds = {},
  }
end

-- Fill only missing keys; never overwrite existing values.
local function merge(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then
      dst[k] = ns.Util.DeepCopy(v)
    elseif type(dst[k]) == "table" and type(v) == "table" then
      merge(dst[k], v)
    end
  end
end

function DB.Init(sv)
  if type(sv) ~= "table" then sv = {} end
  merge(sv, defaults())
  return sv
end

function DB.Guild(sv, guildKey)
  sv.guilds = sv.guilds or {}
  local g = sv.guilds[guildKey]
  if not g then g = {}; sv.guilds[guildKey] = g end
  g.sets = g.sets or {}
  g.log = g.log or {}
  g.cache = g.cache or {}
  g.modules = g.modules or {}
  return g
end

function DB.Module(sv, guildKey, moduleName)
  local g = DB.Guild(sv, guildKey)
  local m = g.modules[moduleName]
  if not m then m = {}; g.modules[moduleName] = m end
  return m
end
