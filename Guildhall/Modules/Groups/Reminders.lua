local ADDON, ns = ...

-- Reminders: 15 minutes before a scheduled run, one chat line (and an optional sound) for the
-- poster and each signed-up, non-withdrawn player. Each client only ever reminds its own player.
--
-- Times are server time (ctx.now, GetServerTime), the same clock a post's start is stored in, so the
-- player's local clock offset plays no part. A tick every 30 s checks the posts; a reminder fires once
-- per post (and start), immediately when the client logs in between start - 900 and start.
-- A post with d.remind = false (the poster unticked "Remind signups 15 min before") reminds nobody.
-- Fired reminders are remembered in ctx.db.reminded (post id -> start, the per-guild Groups table),
-- so a /reload inside the window does not repeat one.
--
-- ctx: { groups (Groups service: Posts, Signups), profile (Id, OnlineChar), now, after, personal
--        (SavedVariables personal), db?, print?, playSound? }.
-- personal.groups (account-wide): reminders (false = off), sound (false = no sound), roles (the
-- default signup roles). Defaults fills the missing ones.
--
-- Globals: ns.Groups.Reminders.
ns.Groups = ns.Groups or {}
local Reminders = {}
ns.Groups.Reminders = Reminders

local TICK, LEAD = 30, 900
local KEEP = 86400 -- remembered reminders are dropped a day after their start

-- Fills personal.groups without touching choices already made. roles is only set when missing
-- (a merge into an existing set would add DPS to a choice that left it out).
function Reminders.Defaults(personal)
  if type(personal) ~= "table" then return nil end
  local g = type(personal.groups) == "table" and personal.groups or {}
  personal.groups = g
  if g.reminders == nil then g.reminders = true end
  if g.sound == nil then g.sound = true end
  if type(g.roles) ~= "table" then g.roles = { d = true } end
  return g
end

local R = {}
R.__index = R

function Reminders.new(ctx)
  local self = setmetatable({ ctx = ctx }, R)
  if type(ctx.db) == "table" then
    ctx.db.reminded = type(ctx.db.reminded) == "table" and ctx.db.reminded or {}
    self.reminded = ctx.db.reminded
  else
    self.reminded = {}
  end
  self.print = ctx.print or print
  return self
end

function R:Start()
  self.stopped = false
  self.gen = (self.gen or 0) + 1
  local gen = self.gen
  local function tick()
    if self.stopped or self.gen ~= gen then return end
    self:Check()
    self.ctx.after(TICK, tick)
  end
  tick()
end

function R:Stop() self.stopped = true end

local function opts(ctx)
  local p = ctx.personal
  return type(p) == "table" and type(p.groups) == "table" and p.groups or {}
end

-- Checks every post once. Returns how many reminders fired.
function R:Check()
  local ctx = self.ctx
  local now = ctx.now()
  for id, start in pairs(self.reminded) do
    if type(start) ~= "number" or start + KEEP < now then self.reminded[id] = nil end
  end
  local o = opts(ctx)
  if o.reminders == false then return 0 end
  local me = ctx.profile and ctx.profile:Id()
  if me == nil then return 0 end
  local fired = 0
  for _, post in ipairs(ctx.groups:Posts() or {}) do
    local d = type(post) == "table" and post.d
    local start = type(d) == "table" and d.start
    if type(start) == "number" and d.remind ~= false and now >= start - LEAD and now < start and self.reminded[post.id] ~= start then
      if self:_remind(post, me, now) then fired = fired + 1 end
    end
  end
  return fired
end

-- The post's people: the poster, then each live signup (distinct profiles).
function R:_people(post)
  local list, seen = { post.by }, { [post.by] = true }
  for _, s in ipairs(self.ctx.groups:Signups(post.id) or {}) do
    if type(s.profile) == "string" and not seen[s.profile] then
      seen[s.profile] = true
      list[#list + 1] = s.profile
    end
  end
  return list, seen
end

function R:_remind(post, me, now)
  local ctx = self.ctx
  local people, seen = self:_people(post)
  if not seen[me] then return false end
  self.reminded[post.id] = post.d.start
  local entry = ns.Instances and ns.Instances.Get(post.d.instance)
  local name = entry and entry.name or tostring(post.d.instance)
  local size = entry and entry.size or #people
  local online = 0
  for _, pid in ipairs(people) do
    if ctx.profile.OnlineChar and ctx.profile:OnlineChar(pid) ~= nil then online = online + 1 end
  end
  local mins = math.max(1, math.ceil((post.d.start - now) / 60))
  self.print(string.format("Guildhall: %s starts in %d min (%d of %d signed up, %d online).", name, mins,
    #people, size, online))
  if opts(ctx).sound ~= false and ctx.playSound then ctx.playSound() end
  return true
end
