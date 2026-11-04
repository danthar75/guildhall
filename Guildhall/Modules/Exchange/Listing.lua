local ADDON, ns = ...

-- Pure Exchange listing model: payload validation, record constructors, and
-- the acceptance check for records arriving from peers. No WoW API use.
ns.Exchange = ns.Exchange or {}

local Listing = {}

local WEEK = 604800
local MAX_EXP_AHEAD = 691200 -- 8 days

local function copy(t)
  if ns.Util and ns.Util.DeepCopy then return ns.Util.DeepCopy(t) end
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function isInt(n)
  return type(n) == "number" and n == math.floor(n) and n == n and n ~= math.huge and n ~= -math.huge
end

-- Returns ok, err. Never raises on malformed input. Unknown extra keys are allowed.
function Listing.Validate(d)
  if type(d) ~= "table" then return false, "payload not a table" end
  if d.kind ~= "LF" and d.kind ~= "WTS" then return false, "bad kind" end
  if type(d.item) ~= "string" or #d.item < 1 or #d.item > 255 then return false, "bad item" end
  if d.qty ~= nil and not (isInt(d.qty) and d.qty >= 1 and d.qty <= 9999) then return false, "bad qty" end
  if type(d.mats) ~= "boolean" then return false, "bad mats" end
  if type(d.cod) ~= "boolean" then return false, "bad cod" end
  if d.note ~= nil and (type(d.note) ~= "string" or #d.note > 200) then return false, "bad note" end
  if d.offRemove ~= nil and type(d.offRemove) ~= "boolean" then return false, "bad offRemove" end
  if d.src ~= nil and d.src ~= "discord" then return false, "bad src" end
  if d.poster ~= nil and (type(d.poster) ~= "string" or #d.poster > 64) then return false, "bad poster" end
  if d.created ~= nil and not isInt(d.created) then return false, "bad created" end
  return true
end

-- d.created keeps the original post time; t moves on every edit and renew.
function Listing.New(d, profileId, char, now, idCounter)
  local payload = copy(d)
  payload.created = now
  return {
    id = profileId .. ":" .. idCounter,
    v = 1, t = now, by = profileId, char = char,
    exp = now + WEEK, del = false, d = payload,
  }
end

-- Listings from before d.created existed: the previous t is the best known post time.
local function backfillCreated(n, rec)
  if type(n.d) == "table" and n.d.created == nil and isInt(rec.t) then n.d.created = rec.t end
end

-- changes: shallow-merged into a copy of d. qty/note == false removes the field.
-- The result is NOT validated; callers validate d before publishing.
function Listing.Edit(rec, changes, char, now)
  local n = copy(rec)
  n.d = type(rec.d) == "table" and copy(rec.d) or {}
  for k, v in pairs(changes) do
    if v == false and (k == "qty" or k == "note") then n.d[k] = nil else n.d[k] = v end
  end
  n.v, n.t, n.char = rec.v + 1, now, char
  backfillCreated(n, rec)
  return n
end

function Listing.Renew(rec, char, now)
  local n = copy(rec)
  n.v, n.t, n.char, n.exp = rec.v + 1, now, char, now + WEEK
  backfillCreated(n, rec)
  return n
end

-- byOfficer: marks d.offRemove and records the officer's profile in d.offBy. `by` never
-- changes, so the owner check holds for every version and the merge rule alone decides.
function Listing.Remove(rec, char, now, byOfficer, officerProfileId)
  if byOfficer and officerProfileId == nil then
    error("Listing.Remove: officerProfileId required when byOfficer", 2)
  end
  local n = copy(rec)
  n.d = type(rec.d) == "table" and copy(rec.d) or {}
  n.v, n.t, n.char, n.del = rec.v + 1, now, char, true
  if byOfficer then
    n.d.offRemove = true
    n.d.offBy = officerProfileId
  end
  return n
end

local function isOfficerRemoval(rec)
  return rec.del == true and type(rec.d) == "table" and rec.d.offRemove == true
end

-- Returns ok, reason. ok=true may carry a reason ("officer unverified") to be logged.
-- ctx: isOfficer(char) -> true|false|nil; rosterKnown: true once a guild roster has been
-- read, so a name missing from it is treated as "not officer" rather than "unverified".
function Listing.CheckIncoming(rec, existing, ctx)
  if type(rec) ~= "table" then return false, "bad record" end
  if type(rec.char) ~= "string" or rec.char == "" then return false, "bad char" end
  if rec.del ~= true then
    local ok, err = Listing.Validate(rec.d)
    if not ok then return false, err end
  end
  if type(rec.exp) ~= "number" or type(rec.t) ~= "number" then return false, "bad times" end
  if rec.exp > rec.t + MAX_EXP_AHEAD then return false, "exp too far" end
  local offRemoval = isOfficerRemoval(rec)
  if existing and rec.by ~= existing.by then return false, "not owner" end
  if offRemoval then
    if type(rec.d.offBy) ~= "string" or rec.d.offBy == "" then return false, "bad offBy" end
    local isOff = ctx and ctx.isOfficer and ctx.isOfficer(rec.char)
    if isOff == false then return false, "not officer" end
    if isOff == nil then
      if ctx and ctx.rosterKnown then return false, "not officer" end
      return true, "officer unverified"
    end
  end
  return true
end

function Listing.CanEdit(rec, myProfileId)
  if type(rec) ~= "table" or rec.by ~= myProfileId or rec.del == true then return false end
  return not (type(rec.d) == "table" and rec.d.src == "discord")
end

function Listing.CanOfficerRemove(isOfficer)
  return isOfficer == true
end

ns.Exchange.Listing = Listing
