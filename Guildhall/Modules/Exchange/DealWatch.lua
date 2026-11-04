local ADDON, ns = ...

-- DealWatch: watches the trade window and CoD mail, and publishes one "trade" / "cod" observation
-- per completed deal that matches a Guildhall listing. Wiring: Task 10 registers the events through the
-- module's def.events and calls DealWatch.new with the real objects.
--
-- ctx: { compat, exchange, observations, profile, roster, now, after, env?, hooksecurefunc? }.
-- CoD mail: DealWatch:InstallHooks() (Task 10 calls it at login) post-hooks SendMail,
-- TakeInboxItem and AutoLootMailItem (hooksecurefunc only, bodies pcall'd). A seller's send is
-- snapshotted in the SendMail post-hook and published on MAIL_SEND_SUCCESS; a buyer's take reads
-- the CoD header at that index (still there in the post-hook), recorded as a pending take keyed by
-- signature; MAIL_INBOX_UPDATE publishes it only if a mail with that signature has vanished.
-- Reads the globals ERR_TRADE_COMPLETE and LE_GAME_ERR_TRADE_COMPLETE (from ctx.env, default _G).
-- Never calls a restricted or action API. A secret value anywhere means no snapshot, no
-- observation.
ns.Exchange = ns.Exchange or {}
local DealWatch = {}
ns.Exchange.DealWatch = DealWatch

local W = {}
W.__index = W

function DealWatch.new(ctx)
  return setmetatable({ ctx = ctx, snap = nil, partner = nil, sendSnap = nil, preSnap = nil, pending = {} }, W)
end

local function accepted(v) return v == 1 or v == true end

function W:_isComplete(a1, a2)
  local env = self.ctx.env or _G
  local compat = self.ctx.compat
  a1, a2 = compat:Safe(a1), compat:Safe(a2)
  if type(a1) == "number" and env.LE_GAME_ERR_TRADE_COMPLETE ~= nil then
    return a1 == env.LE_GAME_ERR_TRADE_COMPLETE
  end
  return env.ERR_TRADE_COMPLETE ~= nil and a2 == env.ERR_TRADE_COMPLETE
end

function W:_complete()
  local snap, partner, ctx = self.snap, self.partner, self.ctx
  self.snap, self.partner = nil, nil   -- one observation per trade
  if not snap or not partner then return end
  local theirs = ctx.profile:OwnerOf(ctx.roster:Norm(partner))
  local me = ctx.profile:Id()
  if not theirs or not me then return end
  local transfer = { me = me, partner = theirs, give = snap.give, get = snap.get,
    giveCopper = snap.giveCopper, getCopper = snap.getCopper, at = ctx.now() }
  local Deals = ns.Exchange.Deals
  local listing = Deals.Match(transfer, ctx.exchange.listings:List(true), {})
  if not listing then return end
  ctx.observations:Publish(Deals.Observation("trade", listing, transfer))
end

-- Matches and publishes a "cod" observation for a transfer.
function W:_publishCod(transfer)
  local ctx, Deals = self.ctx, ns.Exchange.Deals
  local listing = Deals.Match(transfer, ctx.exchange.listings:List(true), {})
  if not listing then return end
  ctx.observations:Publish(Deals.Observation("cod", listing, transfer))
end

function W:_onSendMail(recipient)
  local ctx = self.ctx
  local snap = ctx.compat:SendMailSnapshot()
  local pre = self.preSnap
  self.preSnap = nil
  if not snap and pre and ctx.now() - pre.t <= 1 then
    local to = ctx.compat:Safe(recipient)
    if type(to) == "string" and ctx.roster:Norm(to) == ctx.roster:Norm(pre.snap.to) then snap = pre.snap end
  end
  self.sendSnap = snap
end

-- Identifies a CoD mail by what it says, not where it sits (indexes shift).
local function signature(mail)
  local parts = {}
  for i, it in ipairs(mail.items) do parts[i] = it.id .. "x" .. it.n end
  return mail.sender .. "|" .. mail.cod .. "|" .. table.concat(parts, ",")
end

local PENDING_TTL = 5   -- seconds a take may wait for its money to leave

-- Live count of CoD mails per signature in the current inbox.
function W:_liveCounts()
  local compat = self.ctx.compat
  local counts = {}
  for i = 1, compat:InboxCount() do
    local mail = compat:InboxCod(i)
    if mail then
      local sig = signature(mail)
      counts[sig] = (counts[sig] or 0) + 1
    end
  end
  return counts
end

-- A take hook only means a request was sent. Record it with the money and live signature count
-- at that moment; settlement decides if it worked.
function W:_onTake(index)
  local ctx = self.ctx
  local mail = ctx.compat:InboxCod(index)
  local money = ctx.compat:Money()
  if not mail or not money then return end
  local sig = signature(mail)
  self.pending[#self.pending + 1] = { sig = sig, mail = mail, moneyBefore = money, cod = mail.cod,
    countBefore = self:_liveCounts()[sig] or 1, t = ctx.now() }
end

-- Return/Delete hooks: one pending take of that signature (the newest) will not pay.
function W:_onCancel(index)
  local mail = self.ctx.compat:InboxCod(index)
  if not mail then return end
  local sig = signature(mail)
  for i = #self.pending, 1, -1 do
    if self.pending[i].sig == sig then table.remove(self.pending, i); return end
  end
end

function W:_publishTaken(mail)
  local ctx = self.ctx
  local me = ctx.profile:Id()
  local theirs = ctx.profile:OwnerOf(ctx.roster:Norm(mail.sender))
  if not me or not theirs then return end
  self:_publishCod({ me = me, partner = theirs, give = {}, get = mail.items,
    giveCopper = mail.cod, getCopper = 0, at = ctx.now() })
end

function W:_sendSuccess()
  local snap, ctx = self.sendSnap, self.ctx
  self.sendSnap, self.preSnap = nil, nil
  if not snap then return end
  local me = ctx.profile:Id()
  local theirs = ctx.profile:OwnerOf(ctx.roster:Norm(snap.to))
  if not me or not theirs then return end
  self:_publishCod({ me = me, partner = theirs, give = snap.items, get = {},
    giveCopper = 0, getCopper = snap.cod, at = ctx.now() })
end

-- Settlement with one shared ledger. A pending take succeeds only when (a) fewer mails with its
-- signature remain than when it was taken (less takes already counted in this walk), (b) the money
-- spent since the oldest pending take still covers its CoD (each success deducts it), and
-- (c) it is at most PENDING_TTL seconds old. Older takes are discarded at any settle, unreadable
-- money discards everything, and unbacked takes wait for the next event until they expire.
function W:_settle()
  local ctx = self.ctx
  if #self.pending == 0 then return end
  local money, now = ctx.compat:Money(), ctx.now()
  if not money then self.pending = {}; return end
  local live = {}
  for _, p in ipairs(self.pending) do
    if now - p.t <= PENDING_TTL then live[#live + 1] = p end
  end
  self.pending = live
  if #live == 0 then return end
  local spend = live[1].moneyBefore - money
  local counts, counted, keep = self:_liveCounts(), {}, {}
  for _, p in ipairs(live) do
    local avail = p.countBefore - (counts[p.sig] or 0) - (counted[p.sig] or 0)
    if avail > 0 and spend >= p.cod then
      spend = spend - p.cod
      counted[p.sig] = (counted[p.sig] or 0) + 1
      self:_publishTaken(p.mail)
    elseif avail <= 0 and p.countBefore - (counts[p.sig] or 0) > 0 then
      -- its vanished mail was already claimed by an earlier take (e.g. the double hook): drop it
    else
      keep[#keep + 1] = p
    end
  end
  self.pending = keep
end

-- Post-hooks only; every body is pcall'd so a hook can never raise into Blizzard code.
function W:InstallHooks()
  local ctx = self.ctx
  local env = ctx.env or _G
  local hook = ctx.hooksecurefunc or _G.hooksecurefunc
  if not hook then return false end
  local function guard(fn) return function(...) pcall(fn, ...) end end
  if env.SendMail then hook("SendMail", guard(function(to) self:_onSendMail(to) end)) end
  if env.TakeInboxItem then hook("TakeInboxItem", guard(function(index) self:_onTake(index) end)) end
  if env.AutoLootMailItem then hook("AutoLootMailItem", guard(function(index) self:_onTake(index) end)) end
  if env.ReturnInboxItem then hook("ReturnInboxItem", guard(function(index) self:_onCancel(index) end)) end
  if env.DeleteInboxItem then hook("DeleteInboxItem", guard(function(index) self:_onCancel(index) end)) end
  local btn = env.SendMailMailButton
  if btn and btn.HookScript then
    btn:HookScript("PreClick", guard(function()
      local snap = ctx.compat:SendMailSnapshot()
      self.preSnap = snap and { snap = snap, t = ctx.now() } or nil
    end))
  end
  return true
end

function W:OnEvent(event, ...)
  local ctx = self.ctx
  if event == "MAIL_SEND_SUCCESS" then
    self:_sendSuccess()
  elseif event == "MAIL_FAILED" then
    self.sendSnap, self.preSnap = nil, nil
  elseif event == "MAIL_INBOX_UPDATE" then
    self:_settle()
  elseif event == "PLAYER_MONEY" then
    self:_settle()
  elseif event == "MAIL_CLOSED" then
    self.pending = {}
  elseif event == "TRADE_ACCEPT_UPDATE" then
    local player, target = ctx.compat:Safe((...)), ctx.compat:Safe((select(2, ...)))
    if accepted(player) and accepted(target) then
      self.snap, self.partner = ctx.compat:TradeSnapshot(), ctx.compat:TradePartner()
    end
  elseif event == "UI_INFO_MESSAGE" then
    if self:_isComplete(...) then self:_complete() end
  elseif event == "TRADE_CLOSED" then
    local snap = self.snap
    ctx.after(1, function()
      if self.snap == snap then self.snap, self.partner = nil, nil end
    end)
  end
end
