local ADDON, ns = ...

-- Compact tagged format (no NUL bytes, no code evaluation):
--   n            nil
--   t / f        true / false
--   d<num>;      number, "%.17g"
--   s<text>;     string; "\" escapes "\", ";" and NUL (as "\0")
--   {k v k v }   table: key/value pairs, closed by "}"
local Serialize = {}
ns.Serialize = Serialize

local MAX_DEPTH = 32

local function escape(s)
  return (s:gsub("[;%z\\]", function(c)
    if c == "\0" then return "\\0" end
    return "\\" .. c
  end))
end

local function enc(v, out, depth)
  local t = type(v)
  if t == "nil" then out[#out + 1] = "n"
  elseif t == "boolean" then out[#out + 1] = v and "t" or "f"
  elseif t == "number" then out[#out + 1] = "d" .. string.format("%.17g", v) .. ";"
  elseif t == "string" then out[#out + 1] = "s" .. escape(v) .. ";"
  elseif t == "table" then
    if depth > MAX_DEPTH then error("table too deep") end
    out[#out + 1] = "{"
    for k, val in pairs(v) do
      local kt = type(k)
      if kt ~= "string" and kt ~= "number" then error("unsupported key type: " .. kt) end
      enc(k, out, depth + 1)
      enc(val, out, depth + 1)
    end
    out[#out + 1] = "}"
  else
    error("unsupported type: " .. t)
  end
end

function Serialize.Encode(v)
  local out = {}
  enc(v, out, 0)
  return table.concat(out)
end

-- Reads a value at position i; returns value, nextPos. Raises on malformed input.
local function dec(s, i, depth)
  local tag = s:sub(i, i)
  if tag == "n" then return nil, i + 1
  elseif tag == "t" then return true, i + 1
  elseif tag == "f" then return false, i + 1
  elseif tag == "d" then
    local e = s:find(";", i + 1, true)
    if not e then error("unterminated number at " .. i) end
    local n = tonumber(s:sub(i + 1, e - 1))
    if not n then error("bad number at " .. i) end
    return n, e + 1
  elseif tag == "s" then
    local parts, p = {}, i + 1
    while true do
      local q = s:find("[;\\]", p)
      if not q then error("unterminated string at " .. i) end
      parts[#parts + 1] = s:sub(p, q - 1)
      if s:sub(q, q) == ";" then return table.concat(parts), q + 1 end
      local c = s:sub(q + 1, q + 1)
      if c == "0" then parts[#parts + 1] = "\0"
      elseif c == "\\" or c == ";" then parts[#parts + 1] = c
      else error("bad escape at " .. q) end
      p = q + 2
    end
  elseif tag == "{" then
    if depth >= MAX_DEPTH then error("table too deep") end
    local t, p = {}, i + 1
    while true do
      if p > #s then error("unterminated table at " .. i) end
      if s:sub(p, p) == "}" then return t, p + 1 end
      local k, v
      k, p = dec(s, p, depth + 1)
      if type(k) ~= "string" and type(k) ~= "number" then error("bad key at " .. p) end
      if p > #s then error("truncated table at " .. i) end
      v, p = dec(s, p, depth + 1)
      t[k] = v
    end
  end
  error("unexpected '" .. tag .. "' at " .. i)
end

function Serialize.Decode(s)
  if type(s) ~= "string" or s == "" then return nil, "empty or non-string input" end
  local ok, v, p = pcall(dec, s, 1, 0)
  if not ok then return nil, tostring(v) end
  if p ~= #s + 1 then return nil, "trailing data at " .. p end
  return v
end
