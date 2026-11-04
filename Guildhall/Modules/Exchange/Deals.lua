local ADDON, ns = ...

-- Exchange deals: matches a completed transfer (trade, CoD, manual) to a Guildhall listing,
-- builds the observation both sides publish, and derives paired Contributions from those
-- observations. Pure: no WoW API use. Gold values are copper.
--
-- transfer = { me, partner (profile ids), give, get ({ {id, n} }), giveCopper, getCopper, at }.
-- A deal needs gold moving in the listing's direction (a free hand-over is not a sale).
-- An unpaired observation yields uncounted rows for the observer's own side only.
ns.Exchange = ns.Exchange or {}
local Deals = {}
ns.Exchange.Deals = Deals

local WINDOW = 172800   -- a listing still matches this long after it ended (48 h)
local PAIR_WINDOW = { trade = 900, cod = 2592000, manual = 1209600 }

local function register(id, label, unit, weight, order)
  ns.Activity.Register({ id = id, label = label, unit = unit, verify = "paired", weight = weight, order = order })
end
register("exchange.listings", "Listings posted", "count", 1, 10)
register("exchange.sales", "Sales", "count", 5, 20)
register("exchange.purchases", "Purchases", "count", 5, 30)
register("exchange.gold.earned", "Gold earned", "gold", 0.1, 40)
register("exchange.gold.paid", "Gold paid", "gold", 0.1, 50)

local function total(list, id)
  local n = 0
  for _, it in ipairs(list or {}) do
    if it.id == id and type(it.n) == "number" then n = n + it.n end
  end
  return n
end

local function active(rec, at)
  if rec.del == true then return false, rec.t end
  if type(rec.exp) == "number" and rec.exp <= at then return false, rec.exp end
  return true
end

-- The profile id a listing id carries ("<profile>:<n>"), or nil.
local function idPrefix(id)
  return type(id) == "string" and id:match("^(.+):[^:]*$") or nil
end

-- True when a listing can still be matched at `at`: active, or ended within the window.
function Deals.Matchable(rec, at)
  local isActive, endedAt = active(rec, at)
  return isActive or (type(endedAt) == "number" and at - endedAt <= WINDOW), isActive
end

-- Seller and buyer profile ids for a listing record and the transfer's other party.
local function roles(listing, transfer)
  local owner = listing.by
  local other = owner == transfer.me and transfer.partner or transfer.me
  if listing.d.kind == "WTS" then return owner, other end
  return other, owner
end

-- Returns the best matching listing record, or nil.
function Deals.Match(transfer, listings, ctx)
  if type(transfer) ~= "table" or transfer.me == nil or transfer.partner == nil
      or transfer.me == transfer.partner then return nil end
  local at = transfer.at
  local best, bestActive
  for _, rec in ipairs(listings or {}) do
    local d = rec.d
    local ok = type(d) == "table" and (d.kind == "WTS" or d.kind == "LF")
      and (rec.by == transfer.me or rec.by == transfer.partner)
      and type(d.item) == "string"
    local id = ok and ns.Util.ItemIdFromLink(d.item) or nil
    if id and not (type(d.created) == "number" and d.created > at) then
      local matchable, isActive = Deals.Matchable(rec, at)
      if matchable then
        local seller = roles(rec, transfer)
        local sellerIsMe = seller == transfer.me
        local items = sellerIsMe and transfer.give or transfer.get
        local paid = sellerIsMe and transfer.getCopper or transfer.giveCopper
        local back = sellerIsMe and transfer.giveCopper or transfer.getCopper
        if total(items, id) > 0 and (paid or 0) > 0 and (back or 0) == 0 then
          -- An active listing beats an ended one; within the same group the newest t wins.
          if not best or (isActive and not bestActive)
              or (isActive == bestActive and (rec.t or 0) > (best.t or 0)) then
            best, bestActive = rec, isActive
          end
        end
      end
    end
  end
  return best
end

-- The observation data both sides publish (payload fields are integers or short strings).
function Deals.Observation(kind, listing, transfer)
  local seller, buyer = roles(listing, transfer)
  local id = Deals.ItemKey(listing)
  local sellerIsMe = seller == transfer.me
  return {
    kind = kind, listing = listing.id, seller = seller, buyer = buyer, item = id,
    count = total(sellerIsMe and transfer.give or transfer.get, id),
    copper = sellerIsMe and transfer.getCopper or transfer.giveCopper,
    at = transfer.at, owner = listing.by,
    listed = type(listing.d.created) == "number" and listing.d.created or nil,
  }
end

-- The pairing item of a listing: its item id, or its typed name (hand-typed listings).
function Deals.ItemKey(listing)
  local d = listing.d
  if type(d) ~= "table" or type(d.item) ~= "string" then return nil end
  return ns.Util.ItemIdFromLink(d.item) or d.item:sub(1, 64)
end

-- A confirming observation: the known fields of a peer's, republished by the other side.
function Deals.Rebuild(d, at)
  return { kind = "manual", listing = d.listing, seller = d.seller, buyer = d.buyer, item = d.item,
    count = d.count, copper = d.copper, at = at, owner = d.owner, listed = d.listed }
end

local function rows(d, ref, at, counted, why, sides)
  local out = {}
  local function add(type_, profile, value)
    out[#out + 1] = { type = type_, profile = profile, value = value, at = at, item = d.item,
      ref = ref, counted = counted, why = why, listing = d.listing,
      owner = Deals.OwnerOf(d), listed = d.listed }
  end
  if sides.seller then
    add("exchange.sales", d.seller, 1)
    add("exchange.gold.earned", d.seller, d.copper)
  end
  if sides.buyer then
    add("exchange.purchases", d.buyer, 1)
    add("exchange.gold.paid", d.buyer, d.copper)
  end
  return out
end

local function isInt(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge and x == math.floor(x)
end

-- The owner a deal observation names: its owner field, else the listing id's prefix.
function Deals.OwnerOf(d)
  if type(d) ~= "table" then return nil end
  if type(d.owner) == "string" then return d.owner end
  return idPrefix(d.listing)
end

-- True for a well-formed deal payload (so Key and the deriver never meet a bad field).
function Deals.Valid(d)
  if type(d) ~= "table" or type(d.listing) ~= "string" or type(d.seller) ~= "string"
      or type(d.buyer) ~= "string" or d.seller == d.buyer or not isInt(d.at)
      or not isInt(d.count) or not isInt(d.copper)
      or not (type(d.item) == "string" or isInt(d.item)) then return false end
  if d.owner ~= nil then
    local prefix = idPrefix(d.listing)
    if type(d.owner) ~= "string" or (prefix and d.owner ~= prefix)
        or (d.owner ~= d.seller and d.owner ~= d.buyer) then return false end
  end
  if d.listed ~= nil and not isInt(d.listed) then return false end
  return true
end

-- Identity of a deal across both sides and across kinds.
function Deals.Key(d)
  return table.concat({ d.listing, tostring(d.item), d.count, d.copper, d.seller, d.buyer }, "|")
end

local function valid(rec)
  local d = rec.d
  return Deals.Valid(d) and (rec.by == d.seller or rec.by == d.buyer)
end

-- Pairs the observations of one kind: array of { a, mate?, key } in a stable order.
local function pairUp(kind, list)
  local window = PAIR_WINDOW[kind]
  local groups, order = {}, {}
  for _, rec in ipairs(list) do
    if valid(rec) then
      local key = Deals.Key(rec.d)
      if not groups[key] then groups[key] = {}; order[#order + 1] = key end
      table.insert(groups[key], rec)
    end
  end
  local out = {}
  for _, key in ipairs(order) do
    local g = groups[key]
    table.sort(g, function(a, b)
      if a.d.at ~= b.d.at then return a.d.at < b.d.at end
      return tostring(a.id) < tostring(b.id)
    end)
    local used = {}
    for i, a in ipairs(g) do
      if not used[i] then
        used[i] = true
        local mate
        for j = i + 1, #g do
          local b = g[j]
          if not used[j] and b.by ~= a.by and b.d.at - a.d.at <= window then mate = j; break end
        end
        if mate then used[mate] = true end
        out[#out + 1] = { a = a, mate = mate and g[mate] or nil, key = key }
      end
    end
  end
  return out
end

-- Map of Deals.Key -> times of paired trade or CoD deals in ctx.observations.
function Deals.AutoPaired(observations)
  local set = {}
  if observations then
    for _, kind in ipairs({ "trade", "cod" }) do
      for _, p in ipairs(pairUp(kind, observations:List(kind))) do
        if p.mate then
          set[p.key] = set[p.key] or {}
          table.insert(set[p.key], p.a.d.at)
        end
      end
    end
  end
  return set
end

-- True when a manual deal (key, at) repeats an auto-paired deal made within 48 h of it.
function Deals.IsDuplicate(autoPaired, key, at)
  for _, t in ipairs(autoPaired[key] or {}) do
    if math.abs(at - t) <= WINDOW then return true end
  end
  return false
end

local function derive(kind)
  return function(list, ctx)
    local skip = kind == "manual" and Deals.AutoPaired(ctx and ctx.observations) or {}
    local out = {}
    for _, p in ipairs(pairUp(kind, list)) do
      local d = p.a.d
      local ref = "deal:" .. d.listing .. ":" .. tostring(p.a.id)
      local dup = kind == "manual" and Deals.IsDuplicate(skip, p.key, d.at)
      if p.mate then
        if not dup then
          for _, c in ipairs(rows(d, ref, d.at, true, nil, { seller = true, buyer = true })) do out[#out + 1] = c end
        end
      elseif not dup then
        local why = kind == "manual" and "waiting for confirmation" or "unpaired"
        local sides = p.a.by == d.seller and { seller = true } or { buyer = true }
        for _, c in ipairs(rows(d, ref, d.at, false, why, sides)) do out[#out + 1] = c end
      end
    end
    return out
  end
end

for kind in pairs(PAIR_WINDOW) do ns.Activity.RegisterDeriver(kind, derive(kind)) end

-- A listing counts once for its owner when a non-owner witnessed it, or when it ended in a
-- paired deal (ctx.observations, when present, supplies the deal observations). Credit lands at
-- the listing's creation time.
ns.Activity.RegisterDeriver("witness", function(list, ctx)
  local out, done = {}, {}
  local function add(listing, owner, at)
    if done[listing] then return end
    done[listing] = true
    out[#out + 1] = { type = "exchange.listings", profile = owner, value = 1, at = at,
      ref = "listing:" .. listing, counted = true }
  end
  for _, rec in ipairs(list) do
    local d = rec.d
    if type(d) == "table" and type(d.listing) == "string" and isInt(d.at) then
      local owner = idPrefix(d.listing)
      if owner and (d.owner == nil or d.owner == owner) and rec.by ~= owner then
        add(d.listing, owner, d.at)
      end
    end
  end
  local obs = ctx and ctx.observations
  if obs then
    for kind in pairs(PAIR_WINDOW) do
      for _, c in ipairs(ns.Activity.Deriver(kind)(obs:List(kind), ctx)) do
        if c.counted and c.owner and c.profile == c.owner and isInt(c.listed)
            and c.owner == idPrefix(c.listing) then
          add(c.listing, c.owner, c.listed)
        end
      end
    end
  end
  return out
end)
