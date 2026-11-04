local ADDON, ns = ...

-- Bank: reads the guild bank log (items per tab, plus the money log) while the bank is open and
-- publishes one "bank" observation per deposit or withdrawal, so donations earn leaderboard
-- credit. The game only reports "N hours ago", so every observation is bucketed to the hour and
-- the deriver merges readings of the same entry from different clients (hour buckets within one
-- of each other). Wiring: Task 10 registers the events through the module's def.events and calls
-- Bank.new with the real objects. Never calls a restricted or action API (the log queries are
-- read-only requests); secret values drop the entry.
--
-- ctx: { compat, observations, profile, roster?, now, after, moduleDb }.
-- Observation: { kind = "bank", type = "dep"|"wd", player, tab?, item?, count?|copper?, at }.
-- Items entries carry tab, item and count; money entries carry copper and no tab.
-- db.bankSeen (ctx.moduleDb) holds what this client already published:
-- base key "tab|type|player|item|amount" -> list of { b = hour bucket, t = publish time }.
ns.Bank = ns.Bank or {}
local Bank = ns.Bank

local HOUR, RETENTION, TICK = 3600, 34560000, 60

ns.Activity.Register({ id = "bank.gold", label = "Bank gold", unit = "gold", verify = "paired",
  weight = 0.2, order = 60 })
ns.Activity.Register({ id = "bank.items", label = "Bank items", unit = "items", verify = "paired",
  weight = 0.05, order = 70 })

local B = {}
B.__index = B

function Bank.new(ctx)
  local db = ctx.moduleDb
  db.bankSeen = db.bankSeen or {}
  return setmetatable({ ctx = ctx, db = db, gen = 0, open = false }, B)
end

local TYPES = { deposit = "dep", withdraw = "wd" }

function B:_queryAll()
  local compat = self.ctx.compat
  for tab = 1, compat:BankTabCount() do compat:QueryBankLog(tab) end
  compat:QueryBankLog(compat:BankMoneyTab())
end

function B:_tick(gen)
  self.ctx.after(TICK, function()
    if gen ~= self.gen or not self.open or not self.ctx.compat:BankOpen() then return end
    self:_queryAll()
    self:_tick(gen)
  end)
end

function B:OnOpen()
  local now = self.ctx.now()
  local seen = self.db.bankSeen
  for base, list in pairs(seen) do
    if type(list) ~= "table" then
      seen[base] = nil   -- pre-bucket flat keys (never shipped)
    else
      local keep = {}
      for _, s in ipairs(list) do
        if type(s) == "table" and type(s.b) == "number" and type(s.t) == "number" and now - s.t <= RETENTION then
          keep[#keep + 1] = s
        end
      end
      seen[base] = #keep > 0 and keep or nil
    end
  end
  self.open = true
  self.gen = self.gen + 1
  self:_queryAll()
  self:_tick(self.gen)
end

function B:OnClose()
  self.open = false
  self.gen = self.gen + 1
end

-- Reads every tab and the money log; publishes entries this client hasn't published yet.
-- The same log entry can be read in a neighbouring hour bucket later ("N hours ago" rolls over), so
-- seen entries are kept per base key (tab, type, player, item, amount) as { b = bucket, t = time }
-- and each current entry is matched one-to-one, in one greedy pass in ascending bucket order, to the
-- smallest unused seen bucket within +-1. Only unmatched entries are published.
function B:OnLogUpdate()
  local ctx = self.ctx
  local compat, now = ctx.compat, ctx.now()
  local groups, order = {}, {}

  local function collect(e, tab)
    local t = TYPES[e.type]
    if not t then return end
    local amount = tab and e.count or e.copper
    if type(amount) ~= "number" or amount <= 0 then return end
    local player = ctx.roster and ctx.roster.Norm and ctx.roster:Norm(e.name) or e.name
    if type(player) ~= "string" then return end
    local base = table.concat({ tab or "m", t, player, tab and e.item or "", amount }, "|")
    if not groups[base] then groups[base] = {}; order[#order + 1] = base end
    table.insert(groups[base], { bucket = math.floor((now - e.ago) / HOUR), tab = tab, t = t,
      player = player, item = e.item, amount = amount })
  end

  for tab = 1, compat:BankTabCount() do
    for _, e in ipairs(compat:BankLog(tab) or {}) do collect(e, tab) end
  end
  for _, e in ipairs(compat:BankMoneyLog() or {}) do collect(e, nil) end

  for _, base in ipairs(order) do
    local cur = groups[base]
    table.sort(cur, function(a, b) return a.bucket < b.bucket end)
    local seen = self.db.bankSeen[base]
    if type(seen) ~= "table" then seen = {}; self.db.bankSeen[base] = seen end
    local sorted = {}
    for i, s in ipairs(seen) do sorted[i] = s end
    table.sort(sorted, function(a, b) return a.b < b.b end)
    local used = {}
    for _, e in ipairs(cur) do
      local hit
      for j, s in ipairs(sorted) do
        if not used[j] and math.abs(s.b - e.bucket) <= 1 then hit = j; break end
      end
      if hit then
        used[hit] = true
      else
        local d = { kind = "bank", type = e.t, player = e.player, at = e.bucket * HOUR }
        if e.tab then d.tab, d.item, d.count = e.tab, e.item, e.amount else d.copper = e.amount end
        local status, err = ctx.observations:Publish(d)
        if status == "accepted" or status == "invalid" then
          -- invalid will never become valid: remember it so it isn't retried every tick
          seen[#seen + 1] = { b = e.bucket, t = now }
          if status == "invalid" and ns.OnError then
            ns.OnError("Bank log entry not published: " .. tostring(err))
          end
        end
      end
    end
    if #seen == 0 then self.db.bankSeen[base] = nil end
  end
end

-- Deriver. Clusters readings of the same log entry across clients (one per profile, equal fields,
-- hour buckets within one, greedy oldest first); a cluster counts when two profiles saw it or its
-- only reporter isn't the depositor's owner. Netting happens in the Ledger.
local function sortKey(a, b)
  if a.d.at ~= b.d.at then return a.d.at < b.d.at end
  return tostring(a.id) < tostring(b.id)
end

ns.Activity.RegisterDeriver("bank", function(list, ctx)
  local groups, order = {}, {}
  for _, rec in ipairs(list) do
    local d = rec.d
    if type(d) == "table" and (d.type == "dep" or d.type == "wd") and type(d.player) == "string"
        and type(d.at) == "number" and type(rec.by) == "string" then
      local key = table.concat({ tostring(d.tab), d.type, d.player, tostring(d.item), tostring(d.count),
        tostring(d.copper) }, "|")
      if not groups[key] then groups[key] = {}; order[#order + 1] = key end
      table.insert(groups[key], rec)
    end
  end
  table.sort(order)
  local profile = ctx and ctx.profile
  local out = {}
  for _, key in ipairs(order) do
    local recs = groups[key]
    table.sort(recs, sortKey)
    local used = {}
    for i, first in ipairs(recs) do
      if not used[i] then
        used[i] = true
        local by = { [first.by] = true }
        local profiles = 1
        for j = i + 1, #recs do
          local r = recs[j]
          if not used[j] and not by[r.by] and math.abs(r.d.at - first.d.at) <= HOUR then
            used[j], by[r.by] = true, true
            profiles = profiles + 1
          end
        end
        local d = first.d
        local counted = profiles >= 2
        if not counted then
          local owner = profile and profile.OwnerOf and profile:OwnerOf(d.player) or nil
          counted = owner ~= first.by
        end
        local amount = d.tab and d.count or d.copper
        if type(amount) == "number" then
          out[#out + 1] = { type = d.tab and "bank.items" or "bank.gold", char = d.player, tab = d.tab,
            item = d.item, value = d.type == "wd" and -amount or amount, at = d.at,
            ref = "bank:" .. tostring(first.id), counted = counted, why = (not counted) and "unpaired" or nil,
            net = true }
        end
      end
    end
  end
  return out
end)
