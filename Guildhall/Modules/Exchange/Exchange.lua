local ADDON, ns = ...

-- Exchange module: glues Listing, ReplicatedSet, Sync, Log, Profile, Roster and
-- Compat into the object the UI calls. Never sends chat or mail on its own.
ns.Exchange = ns.Exchange or {}

local SET_NAME = "exchange.listings"
local Ex = {}
Ex.__index = Ex

local function copy(t)
  if t == nil then return nil end
  return ns.Util.DeepCopy(t)
end

-- Tells the UI the listing sets changed (the event bus is absent in unit specs).
local function changed()
  if ns.Events then ns.Events:Fire("ExchangeChanged") end
end

function ns.Exchange.Create(ctx)
  local Listing, Format, MailDrafts = ns.Exchange.Listing, ns.Exchange.Format, ns.Exchange.MailDrafts
  local self = setmetatable({}, Ex)
  self.ctx = ctx
  self.compat, self.profile, self.roster, self.log = ctx.compat, ctx.profile, ctx.roster, ctx.log
  self.now, self.templates, self.playerChar = ctx.now, ctx.templates, ctx.playerChar
  local db = ctx.moduleDb
  db.listings = db.listings or {}
  db.imported = db.imported or {}
  db.drafts = db.drafts or {}
  db.declined = db.declined or {}
  db.prompted = db.prompted or {} -- deal ref -> time the "Sold?" prompt was first offered
  self.db = db
  self.soldDirty = true -- NextSoldPrompt rescans only after listings or observations change
  if ns.Events and ns.Events.On then
    ns.Events:On("ObservationsChanged", function() self.soldDirty = true end)
  end
  self.listings = ns.ReplicatedSet.new(SET_NAME, db.listings, { now = ctx.now, onChange = function()
    self.soldDirty = true
    changed()
    if self.started then self:_queueWitness() end
  end })
  self.imported = ns.ReplicatedSet.new("exchange.imported", db.imported, { now = ctx.now, onChange = changed })
  self.drafts = MailDrafts.new(db.drafts)

  local function logApplied(rec, status, old, sender, reason)
    local e = { t = self.now(), set = SET_NAME, id = rec.id, v = rec.v, author = rec.by,
      authorChar = rec.char, relayer = sender }
    if status == "accepted" then
      e.result, e.reason = "accepted", reason
      if not old then
        e.action, e.after = "create", copy(rec.d)
      elseif rec.del == true and type(rec.d) == "table" and rec.d.offRemove then
        e.action, e.before, e.after = "officer-remove", copy(old.d), copy(rec.d)
        e.author = rec.d.offBy
      elseif rec.del == true then
        e.action, e.before, e.after = "remove", copy(old.d), copy(rec.d)
      elseif rec.exp > old.exp then
        e.action = "renew"
        if rec.d ~= nil and old.d ~= nil then
          local b, a = copy(old.d), copy(rec.d)
          local changed = false
          for k in pairs(b or {}) do if type(b[k]) == "table" or b[k] ~= a[k] then changed = true end end
          for k in pairs(a or {}) do if type(a[k]) == "table" or (b or {})[k] ~= a[k] then changed = true end end
          if changed then e.before, e.after = b, a end
        end
      else
        e.action, e.before, e.after = "edit", copy(old.d), copy(rec.d)
      end
    elseif status == "stale" then
      e.action, e.result = "ignored", "stale"
    else
      e.action, e.result, e.reason = "invalid", "rejected", reason or status
    end
    self.log:Add(e)
  end

  self.sync = ns.Sync.new({
    comm = ctx.comm, set = self.listings, module = SET_NAME,
    after = ctx.after, random = ctx.random, playerName = ctx.playerChar,
    validate = function(rec, existing)
      return Listing.CheckIncoming(rec, existing, {
        ownerOf = function(c) return self.profile:OwnerOf(c) end,
        isOfficer = function(c) return self.roster:IsOfficer(c) end,
        rosterKnown = type(self.roster.HasRanks) == "function" and self.roster:HasRanks() or false,
        now = self.now(),
      })
    end,
    onApplied = logApplied,
  })
  ctx.syncs = ctx.syncs or {}
  ctx.syncs[#ctx.syncs + 1] = self.sync
  return self
end

-- The Leaderboard builds the observation set after Exchange logs in. Once it exists, deals
-- seen by DealWatch and the day-old witness are recorded, and DealWatch's hooks go in (once).
function Ex:AttachObservations(observations)
  if self.dealWatch then return end
  self.ctx.observations = observations
  self.dealWatch = ns.Exchange.DealWatch.new({
    compat = self.compat, exchange = self, observations = observations, profile = self.profile,
    roster = self.roster, now = self.now, after = self.ctx.after,
  })
  if self.started then
    self:_pruneDeclined()
    self:_queueWitness()
  end
  self.dealWatch:InstallHooks()
end

function Ex:Start()
  self.listings:Purge()
  self.imported:Purge()
  self.sync:Start()
  self.started = true
  self:_pruneDeclined()
  self:_witness()
end

function Ex:_gate()
  if self.compat:IsTrial() then return "trial" end
  if self.profile:NeedsConsent() then return "consent" end
  -- Every record carries by = profile id and char = this character, so publishing from an
  -- unlinked character would reveal the link the player declined.
  if self.profile:IsExcluded(self.playerChar) then return "excluded" end
end

function Ex:_nextId()
  local n = (self.db.nextId or 0) + 1
  self.db.nextId = n
  return n
end

function Ex:Post(d)
  local err = self:_gate()
  if err then return false, err end
  local ok, verr = ns.Exchange.Listing.Validate(d)
  if not ok then return false, verr end
  local rec = ns.Exchange.Listing.New(d, self.profile:Id(), self.playerChar, self.now(), self:_nextId())
  local status = self.sync:Publish(rec)
  if status ~= "accepted" then return false, status end
  return true, rec
end

-- Shared path for Edit/Renew/Remove: owner check, gate, build, publish.
function Ex:_mutate(id, build, validatePayload)
  local rec = self.listings:Get(id)
  if not rec or not ns.Exchange.Listing.CanEdit(rec, self.profile:Id()) then return false, "not owner" end
  local err = self:_gate()
  if err then return false, err end
  local new = build(rec)
  if validatePayload then
    local ok, verr = ns.Exchange.Listing.Validate(new.d)
    if not ok then return false, verr end
  end
  local status = self.sync:Publish(new)
  if status ~= "accepted" then return false, status end
  return true, new
end

function Ex:Edit(id, changes)
  return self:_mutate(id, function(rec)
    return ns.Exchange.Listing.Edit(rec, changes, self.playerChar, self.now())
  end, true)
end

function Ex:Renew(id)
  return self:_mutate(id, function(rec)
    return ns.Exchange.Listing.Renew(rec, self.playerChar, self.now())
  end)
end

function Ex:Remove(id)
  return self:_mutate(id, function(rec)
    return ns.Exchange.Listing.Remove(rec, self.playerChar, self.now())
  end)
end

function Ex:OfficerRemove(id)
  local rec = self.listings:Get(id)
  if not rec or rec.del or self.profile:IsMine(rec.by)
    or not ns.Exchange.Listing.CanOfficerRemove(self.roster:IsOfficer(self.playerChar)) then
    return false, "not officer"
  end
  local err = self:_gate()
  if err then return false, err end
  local new = ns.Exchange.Listing.Remove(rec, self.playerChar, self.now(), true, self.profile:Id())
  local status = self.sync:Publish(new)
  if status ~= "accepted" then return false, status end
  return true, new
end

local CONFIRM_WINDOW = 1209600   -- a manual deal waits this long for the other side (14 days)
local PROMPT_KEEP = 34560000      -- the observations live this long (400 days)
local WITNESS_AGE = 86400        -- a listing must be this old before anyone witnesses it
local WITNESS_DELAY = 2          -- listing changes arrive in bursts; witness once they settle
local MAX_COPPER, MAX_COUNT = 10000000000, 10000

-- Records a deal done by hand (no trade window or CoD mail) on one of the listings. The other
-- side confirms it later; until then it is unpaired. Returns true, record or false, reason.
function Ex:RecordDeal(listingId, partner, count, copper)
  local Deals = ns.Exchange.Deals
  local err = self:_gate()
  if err then return false, err end
  local me = self.profile:Id()
  if type(partner) ~= "string" or partner == "" then return false, "no partner" end
  if partner == me then return false, "partner is you" end
  if type(count) ~= "number" or count ~= math.floor(count) or count < 1 or count > MAX_COUNT then
    return false, "bad count"
  end
  if type(copper) ~= "number" or copper ~= math.floor(copper) or copper < 1 or copper > MAX_COPPER then
    return false, "bad amount"
  end
  local rec = self.listings:Get(listingId)
  if not rec or type(rec.d) ~= "table" then return false, "unknown listing" end
  if rec.by ~= me and rec.by ~= partner then return false, "neither of you owns that listing" end
  if not Deals.Matchable(rec, self.now()) then return false, "listing ended" end
  local item = Deals.ItemKey(rec)
  if not item then return false, "bad listing" end
  local obs = self.ctx.observations
  if not obs then return false, "unavailable" end
  local weSell = (rec.d.kind == "WTS") == (rec.by == me)
  local transfer = { me = me, partner = partner, at = self.now(),
    give = weSell and { { id = item, n = count } } or {}, get = weSell and {} or { { id = item, n = count } },
    giveCopper = weSell and 0 or copper, getCopper = weSell and copper or 0 }
  local d = Deals.Observation("manual", rec, transfer)
  if Deals.IsDuplicate(Deals.AutoPaired(obs), Deals.Key(d), d.at) then return false, "already recorded" end
  local status, o = obs:Publish(d)
  if status ~= "accepted" then return false, status end
  return true, o
end

-- Manual observations from the other party that name me and still wait for my side.
function Ex:PendingConfirmations()
  local Deals = ns.Exchange.Deals
  local out = {}
  local obs = self.ctx.observations
  if not obs then return out end
  local me, now = self.profile:Id(), self.now()
  local auto, mine = Deals.AutoPaired(obs), {}
  local list = obs:List("manual")
  for _, rec in ipairs(list) do
    if rec.by == me and Deals.Valid(rec.d) then mine[Deals.Key(rec.d)] = true end
  end
  for _, rec in ipairs(list) do
    local d = rec.d
    if rec.by ~= me and Deals.Valid(d) and (d.seller == me or d.buyer == me)
        and (rec.by == d.seller or rec.by == d.buyer)
        and now - d.at <= CONFIRM_WINDOW and not self.db.declined[rec.id] and not mine[Deals.Key(d)]
        and not Deals.IsDuplicate(auto, Deals.Key(d), d.at) then
      local listing = self:Get(d.listing)
      if not listing then
        -- The listing was purged: the observation's own fields stand in for it.
        listing = { id = d.listing, by = Deals.OwnerOf(d), stub = true, d = { item = tostring(d.item), qty = d.count } }
      end
      out[#out + 1] = { obs = rec, listing = listing }
    end
  end
  return out
end

function Ex:ConfirmDeal(obsId)
  local err = self:_gate()
  if err then return false, err end
  for _, p in ipairs(self:PendingConfirmations()) do
    if p.obs.id == obsId then
      local status = self.ctx.observations:Publish(ns.Exchange.Deals.Rebuild(p.obs.d, self.now()))
      if status ~= "accepted" then return false, status end
      self.soldDirty = true
      return true
    end
  end
  return false, "nothing to confirm"
end

function Ex:DeclineDeal(obsId)
  if type(obsId) ~= "string" then return false end
  self.db.declined[obsId] = self.now()
  changed()
  return true
end

-- Forgets declines whose observation is gone or older than the confirmation window.
function Ex:_pruneDeclined()
  local obs = self.ctx.observations
  if not obs then return end
  local live = {}
  for _, rec in ipairs(obs:List("manual")) do live[rec.id] = true end
  local now = self.now()
  for id, at in pairs(self.db.declined) do
    if type(at) ~= "number" then self.db.declined[id] = now
    elseif not live[id] or now - at > CONFIRM_WINDOW then self.db.declined[id] = nil end
  end
  -- Prompt marks outlive the confirmation window (the pairing stays in the observations for as
  -- long as they are kept), so a deal never prompts twice.
  for ref, at in pairs(self.db.prompted) do
    if type(at) ~= "number" or now - at > PROMPT_KEEP then self.db.prompted[ref] = nil end
  end
end

-- The next "Sold?" prompt: a recent paired deal on one of my active WTS listings that has not
-- been offered yet. Returns { ref, listing } and marks it offered, so each deal prompts once
-- (the UI keeps showing it until dismissed). Nil when there is nothing to ask.
function Ex:NextSoldPrompt()
  local obs = self.ctx.observations
  if not obs or not self.soldDirty then return nil end
  self.soldDirty = false
  local me, now = self.profile:Id(), self.now()
  for _, deal in ipairs(ns.Exchange.Deals.PairedDeals(obs)) do
    local listing = self.listings:Get(deal.listing)
    if not self.db.prompted[deal.ref] and now - deal.at <= CONFIRM_WINDOW and listing and listing.by == me
        and listing.del ~= true and listing.exp > now and type(listing.d) == "table" and listing.d.kind == "WTS" then
      self.db.prompted[deal.ref] = now
      self.soldDirty = true -- another deal may be waiting behind this one
      return { ref = deal.ref, listing = listing }
    end
  end
  return nil
end

function Ex:_queueWitness()
  if self.ctx.halted then return end
  local after = self.ctx.after
  if not after then return self:_witness() end
  if self.witnessQueued then return end
  self.witnessQueued = true
  after(WITNESS_DELAY, function()
    self.witnessQueued = false
    self:_witness()
  end)
end

-- Publishes one witness observation for each listing a day old or more that someone else
-- posted, once no witness naming its owner exists in the observation set (so never twice,
-- even after a reload).
function Ex:_witness()
  local obs = self.ctx.observations
  if not obs or self.ctx.halted or self:_gate() then return end
  local now, seen = self.now(), nil
  for _, rec in ipairs(self.listings:List(false)) do
    local d = rec.d
    if rec.del ~= true and rec.exp > now and type(d) == "table" and not self.profile:IsMine(rec.by) then
      local created = type(d.created) == "number" and d.created or rec.t
      if now - created >= WITNESS_AGE then
        if not seen then
          seen = {}
          for _, w in ipairs(obs:List("witness")) do
            if rec.by ~= w.by and type(w.d) == "table" and (w.d.owner == nil or w.d.owner == (type(w.d.listing) == "string"
                and w.d.listing:match("^(.+):[^:]*$"))) then
              seen[w.d.listing] = true
            end
          end
        end
        if not seen[rec.id] then
          seen[rec.id] = true
          obs:Publish({ kind = "witness", listing = rec.id, owner = rec.by, at = created })
        end
      end
    end
  end
end

function Ex:Get(id)
  return self.listings:Get(id) or self.imported:Get(id)
end

function Ex:RemoveImported(id)
  self.db.imported[id] = nil
  changed()
end

function Ex:List(filter)
  filter = filter or "all"
  local now, out = self.now(), {}
  for _, set in ipairs({ self.listings, self.imported }) do
    local isImported = set == self.imported
    for _, rec in ipairs(set:List(false)) do
      local d = rec.d
      if rec.exp > now and type(d) == "table" then
        local keep
        if filter == "mine" then keep = not isImported and self.profile:IsMine(rec.by)
        elseif filter == "LF" or filter == "WTS" then keep = d.kind == filter
        else keep = true end
        if keep then out[#out + 1] = rec end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.id < b.id
  end)
  return out
end

-- Returns "online"|"offline"|"unknown", charToContact.
function Ex:_isImported(rec)
  return self.db.imported[rec.id] ~= nil or (type(rec.d) == "table" and rec.d.src == "discord")
end

function Ex:Status(rec)
  if self:_isImported(rec) then
    if not rec.char then return "unknown", nil end
    local o = self.roster:IsOnline(rec.char)
    if o == true then return "online", rec.char end
    if o == false then return "offline", rec.char end
    return "unknown", rec.char
  end
  local on = self.profile:OnlineChar(rec.by)
  if on then return "online", on end
  local chars = self.profile:CharsOf(rec.by)
  if #chars == 0 and rec.char then chars = { rec.char } end
  if #chars == 0 then return "unknown", nil end
  for _, c in ipairs(chars) do
    if self.roster:IsOnline(c) == nil then return "unknown", rec.char end
  end
  return "offline", rec.char
end

function Ex:Contact(rec)
  if self.profile:IsMine(rec.by) and not self:_isImported(rec) then return "no-contact" end
  local status, char = self:Status(rec)
  if not char then return "no-contact" end
  local F = ns.Exchange.Format
  if status ~= "offline" then
    self.compat:OpenChat("/w " .. char .. " " .. F.Whisper(rec, self.templates))
    return "whisper"
  end
  local subject, body = F.Mail(rec, self.templates)
  if self.compat:MailboxOpen() and self.compat:FillSendMail(char, subject, body) then
    return "mail"
  end
  self.drafts:Add(char, subject, body, rec.id)
  return "drafted"
end

function Ex:DiscordText(id)
  local rec = self:Get(id)
  return rec and ns.Exchange.Format.Discord(rec, self.templates) or ""
end

function Ex:OnMailShow() return self.drafts:Next() end

function Ex:FillDraft(draft)
  if self.compat:FillSendMail(draft.to, draft.subject, draft.body) then
    self.drafts:Remove(draft.id)
    return true
  end
  return false
end

function Ex:DismissDraft(id) self.drafts:Remove(id) end

-- Exactly the events DealWatch:OnEvent handles.
local DEALWATCH_EVENTS = { "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED", "UI_INFO_MESSAGE", "MAIL_SEND_SUCCESS",
  "MAIL_FAILED", "MAIL_INBOX_UPDATE", "MAIL_CLOSED", "PLAYER_MONEY" }
local events = {}
for _, event in ipairs(DEALWATCH_EVENTS) do
  events[event] = function(n, ...)
    local watch = n.exchange and n.exchange.dealWatch
    if watch then watch:OnEvent(event, ...) end
  end
end

if ns.RegisterModule then
  ns.RegisterModule("Exchange", {
    events = events,
    OnLogin = function(n)
      if not n.services then return end
      n.exchange = n.Exchange.Create(n.services)
      n.exchange:Start()
    end,
    about = { title = "Exchange", order = 10, lines = {
      "Post what you're looking for or selling. Guildmates see it right away, and you can whisper, mail or copy it for Discord.",
    } },
    tab = { title = "Exchange", build = function(parent) return ns.Exchange.Board.Build(parent) end },
    settings = { title = "Exchange", build = function(parent) return ns.Exchange.Board.BuildSettings(parent) end },
  })
end
