local ADDON, ns = ...

-- One entry per release, newest first: { version = "0.2.0", lines = { ... }, gnomes = { lo, hi } | nil }.
-- Every release gets an entry, even one with no news (lines = {}): the welcome screen reopens
-- only for entries with lines, but the gnome count on it moves with every entry.
-- tools/release.sh refuses to build a version that has no entry here. Plain ASCII only.
local WhatsNew = {}
ns.WhatsNew = WhatsNew

WhatsNew.ENTRIES = {
  { version = "0.1.0", lines = {
    "New Groups tab: post or join guild runs, now or scheduled.",
    "Finished dungeons, raid bosses, prepared raiders and spec switches now count on the leaderboard.",
    "Guild masters can choose which ranks can do what, and every change is recorded.",
    "Guild masters choose whether runs with non-guild players count; calendar raids can include pugs.",
  } },
}

local function parts(v)
  local out = {}
  for n in tostring(v or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
  return out
end

-- -1, 0 or 1; numeric by dotted parts, so 0.10.0 > 0.9.9. Missing parts count as 0.
function WhatsNew.Compare(a, b)
  local pa, pb = parts(a), parts(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x < y then return -1 elseif x > y then return 1 end
  end
  return 0
end

-- The "no more than lo or hi" numbers for a version. n = released versions up to it, the first
-- release being 0. An entry's gnomes = { lo, hi } overrides the count.
function WhatsNew.Gnomes(version)
  local n = 0
  for _, e in ipairs(WhatsNew.ENTRIES) do
    local c = WhatsNew.Compare(e.version, version)
    if c == 0 and type(e.gnomes) == "table" and e.gnomes[1] and e.gnomes[2] then
      return e.gnomes[1], e.gnomes[2]
    end
    if c <= 0 then n = n + 1 end
  end
  n = math.max(0, n - 1)
  return 10 + 2 * n, 20 + 3 * n
end

-- Entries with news (non-empty lines) for versions after lastSeen up to current, newest first.
function WhatsNew.Unseen(lastSeen, current)
  local out = {}
  for _, e in ipairs(WhatsNew.ENTRIES) do
    if #e.lines > 0 and WhatsNew.Compare(e.version, lastSeen) > 0 and WhatsNew.Compare(e.version, current) <= 0 then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b) return WhatsNew.Compare(a.version, b.version) > 0 end)
  return out
end
