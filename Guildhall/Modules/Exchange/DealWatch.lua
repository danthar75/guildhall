local ADDON, ns = ...

-- DealWatch: watches the trade window and publishes one "trade" observation per completed
-- trade that matches a Guildhall listing. Wiring: Task 10 registers the events through the
-- module's def.events and calls DealWatch.new with the real objects.
--
-- ctx: { compat, exchange, observations, profile, roster, now, after, env? }.
-- Reads the globals ERR_TRADE_COMPLETE and LE_GAME_ERR_TRADE_COMPLETE (from ctx.env, default _G).
-- Never calls a restricted or action API. A secret value anywhere means no snapshot, no
-- observation.
ns.Exchange = ns.Exchange or {}
local DealWatch = {}
ns.Exchange.DealWatch = DealWatch

local W = {}
W.__index = W

function DealWatch.new(ctx)
  return setmetatable({ ctx = ctx, snap = nil, partner = nil }, W)
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

function W:OnEvent(event, ...)
  local ctx = self.ctx
  if event == "TRADE_ACCEPT_UPDATE" then
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
