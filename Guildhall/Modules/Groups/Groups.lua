local ADDON, ns = ...

-- Group finder service: posts, signups and Ready now, each a ReplicatedSet with its own Sync.
-- Never sends chat on its own.
ns.Groups = ns.Groups or {}

local G = {}
G.__index = G

local function copy(t)
  if t == nil then return nil end
  return ns.Util.DeepCopy(t)
end

function ns.Groups.Create(ctx)
  local Post = ns.Groups.Post
  local self = setmetatable({}, G)
  self.ctx = ctx
  self.compat, self.profile, self.log = ctx.compat, ctx.profile, ctx.log
  self.now, self.playerChar = ctx.now, ctx.playerChar
  local db = ctx.moduleDb
  db.posts = db.posts or {}
  db.signups = db.signups or {}
  db.ready = db.ready or {}
  self.db = db

  local queued = false
  local function changed()
    if not ctx.onChange then return end
    if not ctx.after then return ctx.onChange() end
    if queued then return end
    queued = true
    ctx.after(1, function()
      queued = false
      ctx.onChange()
    end)
  end

  self.posts = ns.ReplicatedSet.new("groups.posts", db.posts, { now = ctx.now, onChange = changed })
  self.signups = ns.ReplicatedSet.new("groups.signups", db.signups, { now = ctx.now, onChange = changed })
  self.ready = ns.ReplicatedSet.new("groups.ready", db.ready, { now = ctx.now, onChange = changed })

  local function logger(set)
    return function(rec, status, old, sender, reason)
      if not self.log then return end
      local e = { t = self.now(), set = set, id = rec.id, v = rec.v, author = rec.by,
        authorChar = rec.char, relayer = sender }
      if status == "accepted" then
        e.result, e.reason = "accepted", reason
        if not old then e.action = "create"
        elseif rec.del == true then e.action = "remove"
        else e.action = "edit" end
      elseif status == "stale" then
        e.action, e.result = "ignored", "stale"
      else
        e.action, e.result, e.reason = "invalid", "rejected", reason or status
      end
      self.log:Add(e)
    end
  end

  local function newSync(set, name, validate)
    local s = ns.Sync.new({
      comm = ctx.comm, set = set, module = name,
      after = ctx.after, random = ctx.random, playerName = ctx.playerChar,
      validate = validate, onApplied = logger(name),
    })
    ctx.syncs = ctx.syncs or {}
    ctx.syncs[#ctx.syncs + 1] = s
    return s
  end

  self.postSync = newSync(self.posts, "groups.posts", function(rec, existing)
    return Post.CheckIncoming(rec, existing)
  end)
  self.signupSync = newSync(self.signups, "groups.signups", function(rec, existing)
    return Post.CheckIncomingSignup(rec, existing, {
      now = self.now,
      postExp = function(postId)
        local p = self.posts:Get(postId)
        return p and p.exp or nil
      end,
    })
  end)
  self.readySync = newSync(self.ready, "groups.ready", function(rec, existing)
    return Post.CheckIncomingReady(rec, existing)
  end)
  return self
end

function G:Start()
  self.posts:Purge()
  self.signups:Purge()
  self.ready:Purge()
  self.postSync:Start()
  self.signupSync:Start()
  self.readySync:Start()
  self.started = true
end

-- Every record carries by = profile id and char = this character, so publishing from an
-- excluded character would reveal the link the player declined.
function G:_gate()
  if self.compat and self.compat:IsTrial() then return "trial" end
  if self.profile:NeedsConsent() then return "consent" end
  if self.profile:IsExcluded(self.playerChar) then return "excluded" end
end

local function publish(sync, rec)
  local status = sync:Publish(rec)
  if status ~= "accepted" then return false, status end
  return true, rec
end

-- Posts

function G:Post(d)
  local err = self:_gate()
  if err then return false, err end
  local ok, verr = ns.Groups.Post.Validate(d)
  if not ok then return false, verr end
  local now = self.now()
  local rec = ns.Groups.Post.New(d, self.profile:Id(), self.playerChar, now, ns.Groups.Post.NextN(now))
  return publish(self.postSync, rec)
end

function G:_mine(id)
  local rec = self.posts:Get(id)
  if not rec or rec.del == true or rec.by ~= self.profile:Id() then return nil end
  return rec
end

function G:Close(id)
  local rec = self:_mine(id)
  if not rec then return false, "not owner" end
  local err = self:_gate()
  if err then return false, err end
  return publish(self.postSync, ns.Groups.Post.Close(rec, self.playerChar, self.now()))
end

-- role nil removes the assignment.
function G:Assign(postId, profileId, role)
  local rec = self:_mine(postId)
  if not rec then return false, "not owner" end
  local err = self:_gate()
  if err then return false, err end
  local new = ns.Groups.Post.Assign(rec, profileId, role, self.playerChar, self.now())
  local ok, verr = ns.Groups.Post.Validate(new.d)
  if not ok then return false, verr end
  return publish(self.postSync, new)
end

function G:Get(id) return self.posts:Get(id) end

-- Now posts first (newest created first), then scheduled posts by start.
function G:Posts()
  local now, out = self.now(), {}
  for _, rec in ipairs(self.posts:List(false)) do
    if rec.exp > now and type(rec.d) == "table" then out[#out + 1] = rec end
  end
  table.sort(out, function(a, b)
    local an, bn = a.d.start == nil, b.d.start == nil
    if an ~= bn then return an end
    if an then
      if a.d.created ~= b.d.created then return a.d.created > b.d.created end
    elseif a.d.start ~= b.d.start then
      return a.d.start < b.d.start
    end
    return a.id < b.id
  end)
  return out
end

-- post: a post record. The poster fills their own role, each assign entry its role.
function G:Filled(post)
  local d = post.d
  local out = { t = {}, h = {}, d = {}, open = {} }
  out[d.role][1] = post.by
  local ids = {}
  for pid in pairs(d.assign or {}) do ids[#ids + 1] = pid end
  table.sort(ids)
  for _, pid in ipairs(ids) do
    if pid ~= post.by then
      local list = out[d.assign[pid]]
      list[#list + 1] = pid
    end
  end
  for _, r in ipairs({ "t", "h", "d" }) do
    local assigned = #out[r] - (d.role == r and 1 or 0)
    out.open[r] = math.max(0, d.need[r] - assigned)
  end
  return out
end

-- Signups

function G:SignUp(postId, roles)
  local err = self:_gate()
  if err then return false, err end
  local post = self.posts:Get(postId)
  if not post or post.del == true or post.exp <= self.now() then return false, "unknown post" end
  local ok = ns.Groups.Post.ValidateSignup({ roles = roles, at = 0 })
  if not ok then return false, "bad roles" end
  local me = self.profile:Id()
  local old = self.signups:Get(ns.Groups.Post.SignupId(postId, me))
  local rec = ns.Groups.Post.NewSignup(postId, roles, me, self.playerChar, self.now(), post.exp, old)
  return publish(self.signupSync, rec)
end

function G:Withdraw(postId)
  local me = self.profile:Id()
  local old = self.signups:Get(ns.Groups.Post.SignupId(postId, me))
  if not old or old.del == true then return false, "not signed up" end
  local err = self:_gate()
  if err then return false, err end
  local new = copy(old)
  new.v, new.t, new.char = old.v + 1, self.now(), self.playerChar
  new.d.withdrawn = true
  return publish(self.signupSync, new)
end

-- Live, not withdrawn signups for a post, oldest first.
function G:Signups(postId)
  local now, out = self.now(), {}
  local prefix = postId .. "|"
  for id, rec in pairs(self.signups.store) do
    if id:sub(1, #prefix) == prefix and rec.del ~= true and rec.exp > now and type(rec.d) == "table"
        and rec.d.withdrawn ~= true then
      out[#out + 1] = { profile = rec.by, roles = copy(rec.d.roles), withdrawn = false, at = rec.d.at }
    end
  end
  table.sort(out, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.profile < b.profile
  end)
  return out
end

-- Ready now

function G:SetReady(roles, level, forSeconds)
  local err = self:_gate()
  if err then return false, err end
  local d = { roles = copy(roles), level = level }
  local ok, verr = ns.Groups.Post.ValidateReady(d)
  if not ok then return false, verr end
  local me, now = self.profile:Id(), self.now()
  local rec = { id = me, v = self.ready:NextVersion(me), t = now, by = me, char = self.playerChar,
    exp = now + ns.Groups.Post.ClampReady(forSeconds), del = false, d = d }
  return publish(self.readySync, rec)
end

function G:ClearReady()
  local me = self.profile:Id()
  local old = self.ready:Get(me)
  if not old or old.del == true then return false, "not ready" end
  local err = self:_gate()
  if err then return false, err end
  local new = copy(old)
  new.v, new.t, new.char, new.del = old.v + 1, self.now(), self.playerChar, true
  return publish(self.readySync, new)
end

function G:Ready()
  local now, out = self.now(), {}
  for _, rec in ipairs(self.ready:List(false)) do
    if rec.exp > now and type(rec.d) == "table" then
      out[#out + 1] = { profile = rec.by, char = rec.char, roles = copy(rec.d.roles),
        level = rec.d.level, exp = rec.exp, at = rec.t }
    end
  end
  return out
end
