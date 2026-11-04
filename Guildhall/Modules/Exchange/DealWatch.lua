local ADDON, ns = ...

-- DealWatch: watches the trade window and CoD mail, and publishes one "trade" / "cod" observation
-- per completed deal that matches a Guildhall listing. Wiring: Task 10 registers the events through the
-- module's def.events and calls DealWatch.new with the real objects.
--
-- ctx: { compat, exchange, observations, profile, roster, now, after, env?, hooksecurefunc? }.
-- CoD mail: DealWatch:InstallHooks() (Task 10 calls it at login) post-hooks SendMail,
-- TakeInboxItem and AutoLootMailItem (hooksecurefunc only, bodies pcall'd). A seller's send is
-- snapshotted in the SendMail post-hook and published on MAIL_SEND_SUCCESS; a buyer's take reads
-- the inbox header cached at MAIL_INBOX_UPDATE (the post-hook runs after the mail is gone).
-- Reads the globals ERR_TRADE_COMPLETE and LE_GAME_ERR_TRADE_COMPLETE (from ctx.env, default _G).
-- Never calls a restricted or action API. A secret value anywhere means no snapshot, no
-- observation.
ns.Exchange = ns.Exchange or {}
local DealWatch = {}
ns.Exchange.DealWatch = DealWatch

local W = {}
W.__index = W

function DealWatch.new(ctx)
  return setmetatable({ ctx = ctx, snap = nil, partner = nil, sendSnap = nil, preSnap = nil, inbox = {} }, W)
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

function W:_onSendMail()
  local snap = self.ctx.compat:SendMailSnapshot() or self.preSnap
  self.preSnap = nil
  self.sendSnap = snap
end

function W:_onTake(index)
  local ctx = self.ctx
  local mail = self.inbox[index]
  if not mail then return end
  self.inbox[index] = nil   -- one observation per mail
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

function W:_cacheInbox()
  local compat = self.ctx.compat
  local cache = {}
  for i = 1, compat:InboxCount() do
    local mail = compat:InboxCod(i)
    if mail then cache[i] = mail end
  end
  self.inbox = cache
end

-- Post-hooks only; every body is pcall'd so a hook can never raise into Blizzard code.
function W:InstallHooks()
  local ctx = self.ctx
  local env = ctx.env or _G
  local hook = ctx.hooksecurefunc or _G.hooksecurefunc
  if not hook then return false end
  local function guard(fn) return function(...) pcall(fn, ...) end end
  hook("SendMail", guard(function() self:_onSendMail() end))
  hook("TakeInboxItem", guard(function(index) self:_onTake(index) end))
  hook("AutoLootMailItem", guard(function(index) self:_onTake(index) end))
  local btn = env.SendMailMailButton
  if btn and btn.HookScript then
    btn:HookScript("PreClick", guard(function() self.preSnap = ctx.compat:SendMailSnapshot() end))
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
    self:_cacheInbox()
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
