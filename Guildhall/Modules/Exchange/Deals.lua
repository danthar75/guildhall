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
      local isActive, endedAt = active(rec, at)
      if isActive or (type(endedAt) == "number" and at - endedAt <= WINDOW) then
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
  local id = ns.Util.ItemIdFromLink(listing.d.item)
  local sellerIsMe = seller == transfer.me
  return {
    kind = kind, listing = listing.id, seller = seller, buyer = buyer, item = id,
    count = total(sellerIsMe and transfer.give or transfer.get, id),
    copper = sellerIsMe and transfer.getCopper or transfer.giveCopper,
    at = transfer.at,
  }
end

local function rows(d, ref, at, counted, why, sides)
  local out = {}
  local function add(type_, profile, value)
    out[#out + 1] = { type = type_, profile = profile, value = value, at = at, item = d.item,
      ref = ref, counted = counted, why = why }
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

local function valid(rec)
  local d = rec.d
  return type(d) == "table" and type(d.listing) == "string" and type(d.seller) == "string"
    and type(d.buyer) == "string" and d.seller ~= d.buyer and type(d.at) == "number"
    and type(d.count) == "number" and type(d.copper) == "number"
    and (rec.by == d.seller or rec.by == d.buyer)
end

local function derive(kind)
  local window = PAIR_WINDOW[kind]
  return function(list)
    local groups, order = {}, {}
    for _, rec in ipairs(list) do
      if valid(rec) then
        local d = rec.d
        local key = table.concat({ d.listing, tostring(d.item), d.count, d.copper, d.seller, d.buyer }, "|")
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
          local mate
          for j = i + 1, #g do
            local b = g[j]
            if not used[j] and b.by ~= a.by and b.d.at - a.d.at <= window then mate = j; break end
          end
          local d = a.d
          local ref = "deal:" .. d.listing .. ":" .. tostring(a.id)
          if mate then
            used[i], used[mate] = true, true
            for _, c in ipairs(rows(d, ref, d.at, true, nil, { seller = true, buyer = true })) do out[#out + 1] = c end
          else
            used[i] = true
            local why = kind == "manual" and "waiting for confirmation" or "unpaired"
            local sides = a.by == d.seller and { seller = true } or { buyer = true }
            for _, c in ipairs(rows(d, ref, d.at, false, why, sides)) do out[#out + 1] = c end
          end
        end
      end
    end
    return out
  end
end

for kind in pairs(PAIR_WINDOW) do ns.Activity.RegisterDeriver(kind, derive(kind)) end
