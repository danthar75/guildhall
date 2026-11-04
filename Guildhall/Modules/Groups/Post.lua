local ADDON, ns = ...

-- Pure group-finder model: validation, record constructors and the acceptance checks for
-- posts, signups and Ready now records arriving from peers. No WoW API use.
ns.Groups = ns.Groups or {}

local Post = {}

local NOW_TTL = 7200            -- a Now post lives 2 h
local START_TTL = 21600         -- a scheduled post lives until 6 h after its start
local MAX_START_AHEAD = 1209600 -- a post can be scheduled at most 14 days out
local SIGNUP_SLACK = 86400      -- a signup may outlive its post by at most a day
local SIGNUP_UNKNOWN = MAX_START_AHEAD + START_TTL + SIGNUP_SLACK -- the post may be scheduled far out
local READY_DEFAULT, READY_MAX = 7200, 21600
local MAX_ASSIGN, MAX_PROFILE_BYTES = 40, 16

Post.READY_DEFAULT, Post.READY_MAX = READY_DEFAULT, READY_MAX

local function copy(t)
  if ns.Util and ns.Util.DeepCopy then return ns.Util.DeepCopy(t) end
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

local function isInt(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end

local function isRole(r) return r == "t" or r == "h" or r == "d" end

local function isProfileId(s)
  return type(s) == "string" and #s >= 1 and #s <= MAX_PROFILE_BYTES and s:find("^[%w_%-]+$") ~= nil
end
Post.IsProfileId = isProfileId

local function onlyKeys(t, allowed)
  for k in pairs(t) do
    if not allowed[k] then return false, k end
  end
  return true
end

local function checkRoleSet(roles)
  if type(roles) ~= "table" then return false end
  local n = 0
  for k, v in pairs(roles) do
    if not isRole(k) or v ~= true then return false end
    n = n + 1
  end
  return n >= 1
end

-- remind = false turns the 15-minute reminder off for everyone on the post (absent means on).
local POST_KEYS = { instance = true, role = true, need = true, start = true, note = true, want = true,
  assign = true, created = true, remind = true }

-- Returns ok, err. Never raises on malformed input.
function Post.Validate(d)
  if type(d) ~= "table" then return false, "payload not a table" end
  local ok, k = onlyKeys(d, POST_KEYS)
  if not ok then return false, "unknown field " .. tostring(k) end
  local inst = type(d.instance) == "string" and ns.Instances and ns.Instances.Get(d.instance) or nil
  if not inst then return false, "bad instance" end
  if not isRole(d.role) then return false, "bad role" end
  if type(d.need) ~= "table" then return false, "bad need" end
  if not onlyKeys(d.need, { t = true, h = true, d = true }) then return false, "bad need" end
  local sum = 0
  for _, r in ipairs({ "t", "h", "d" }) do
    local n = d.need[r]
    if not (isInt(n) and n >= 0 and n <= 39) then return false, "bad need" end
    sum = sum + n
  end
  if sum + 1 > inst.size then return false, "need exceeds size" end
  if d.start ~= nil and not (isInt(d.start) and d.start >= 0) then return false, "bad start" end
  if d.note ~= nil and (type(d.note) ~= "string" or #d.note > 120) then return false, "bad note" end
  if d.want ~= nil then
    local w = d.want
    local okw = (isInt(w) and w >= 1 and w <= 10000000) or (type(w) == "string" and #w >= 1 and #w <= 64)
    if not okw then return false, "bad want" end
  end
  if d.remind ~= nil and type(d.remind) ~= "boolean" then return false, "bad remind" end
  if d.assign ~= nil then
    if type(d.assign) ~= "table" then return false, "bad assign" end
    local n = 0
    for pid, role in pairs(d.assign) do
      n = n + 1
      if n > MAX_ASSIGN or not isProfileId(pid) or not isRole(role) then return false, "bad assign" end
    end
  end
  if d.created ~= nil and not (isInt(d.created) and d.created >= 0) then return false, "bad created" end
  if d.start ~= nil and d.created ~= nil and d.start > d.created + MAX_START_AHEAD then
    return false, "start too far"
  end
  return true
end

-- A new post made now: Validate, plus a start that is in the future and at most 14 days out.
-- (Not part of Validate: a peer's scheduled post stays valid after its start passes.)
function Post.CheckNew(d, now)
  local ok, err = Post.Validate(d)
  if not ok then return false, err end
  if d.start ~= nil then
    if d.start <= now then return false, "start in past" end
    if d.start > now + MAX_START_AHEAD then return false, "start too far" end
  end
  return true
end

-- An edit of one of our own posts: Validate, and CheckNew's start window when the edit moves start.
function Post.CheckEdit(old, d, now)
  if type(old) == "table" and d ~= nil and type(d) == "table" and d.start ~= old.start then
    return Post.CheckNew(d, now)
  end
  return Post.Validate(d)
end

local function expOf(d, now)
  if d.start ~= nil then return d.start + START_TTL end
  return (d.created or now) + NOW_TTL
end

-- Session counter, module level, so ids never depend on local history (see Observations).
local session = { at = nil, n = 0 }

function Post.NextN(now)
  local at = math.floor(now)
  if session.at ~= at then session.at, session.n = at, 0 end
  session.n = session.n + 1
  return session.n
end

function Post.Id(profileId, now, n)
  return string.format("%s:g%d_%d", profileId, math.floor(now), n)
end

-- Returns the owner profile id when id has the post shape, else nil.
function Post.OwnerOfId(id)
  if type(id) ~= "string" or #id > 64 then return nil end
  local p, at, n = id:match("^([%w_%-]+):g(%d+)_(%d+)$")
  if not p or not isProfileId(p) or #at > 12 or #n > 9 then return nil end
  return p
end

function Post.New(d, profileId, char, now, n)
  local payload = copy(d)
  payload.created = now
  return {
    id = Post.Id(profileId, now, n),
    v = 1, t = now, by = profileId, char = char,
    exp = expOf(payload, now), del = false, d = payload,
  }
end

-- Poster-only edits. The result is validated by the caller.
function Post.Assign(rec, profileId, role, char, now)
  local n = copy(rec)
  n.d = copy(rec.d)
  n.d.assign = n.d.assign or {}
  n.d.assign[profileId] = role
  if next(n.d.assign) == nil then n.d.assign = nil end
  n.v, n.t, n.char = rec.v + 1, now, char
  return n
end

function Post.Close(rec, char, now)
  local n = copy(rec)
  n.v, n.t, n.char, n.del = rec.v + 1, now, char, true
  return n
end

local REC_KEYS = { id = true, v = true, t = true, by = true, char = true, exp = true, del = true, d = true }

-- Checks common to all three sets. Returns ok, err.
local function checkShape(rec, existing)
  if type(rec) ~= "table" then return false, "bad record" end
  if not onlyKeys(rec, REC_KEYS) then return false, "unknown record field" end
  if type(rec.char) ~= "string" or rec.char == "" or #rec.char > 64 then return false, "bad char" end
  if not isProfileId(rec.by) then return false, "bad by" end
  if existing and rec.by ~= existing.by then return false, "not owner" end
  if rec.del ~= nil and type(rec.del) ~= "boolean" then return false, "bad del" end
  if not (isInt(rec.v) and rec.v >= 1) then return false, "bad version" end
  if not isInt(rec.t) or not isInt(rec.exp) then return false, "bad times" end
  return true
end

function Post.CheckIncoming(rec, existing)
  local ok, err = checkShape(rec, existing)
  if not ok then return false, err end
  if type(rec.id) ~= "string" or Post.OwnerOfId(rec.id) ~= rec.by then return false, "bad id" end
  if rec.del == true and rec.d == nil then
    if rec.exp > rec.t + MAX_START_AHEAD + START_TTL then return false, "exp too far" end
    return true
  end
  local vok, verr = Post.Validate(rec.d)
  if not vok then return false, verr end
  if rec.d.created == nil then return false, "bad created" end
  if rec.d.created > rec.t then return false, "created in the future" end
  if rec.exp > expOf(rec.d, rec.t) then return false, "exp too far" end
  return true
end

-- Signup ids are "<postId>|<profile>".
function Post.SignupId(postId, profileId) return postId .. "|" .. profileId end

local function splitSignupId(id)
  if type(id) ~= "string" or #id > 64 then return nil end
  local postId, prof = id:match("^(.+)|([^|]+)$")
  if not postId or Post.OwnerOfId(postId) == nil or not isProfileId(prof) then return nil end
  return postId, prof
end

function Post.SignupPostId(id)
  return (splitSignupId(id))
end

local SIGNUP_KEYS = { roles = true, withdrawn = true, at = true }

function Post.ValidateSignup(d)
  if type(d) ~= "table" then return false, "payload not a table" end
  if not onlyKeys(d, SIGNUP_KEYS) then return false, "unknown field" end
  if not checkRoleSet(d.roles) then return false, "bad roles" end
  if d.withdrawn ~= nil and type(d.withdrawn) ~= "boolean" then return false, "bad withdrawn" end
  if not (isInt(d.at) and d.at >= 0) then return false, "bad at" end
  return true
end

function Post.NewSignup(postId, roles, profileId, char, now, postExp, old)
  local d = { roles = copy(roles), at = now }
  return {
    id = Post.SignupId(postId, profileId), v = old and old.v + 1 or 1, t = now, by = profileId, char = char,
    exp = postExp, del = false, d = d,
  }
end

-- ctx: now (function), postExp(postId) -> number|nil for a known post.
function Post.CheckIncomingSignup(rec, existing, ctx)
  local ok, err = checkShape(rec, existing)
  if not ok then return false, err end
  local postId, prof = splitSignupId(rec.id)
  if not postId then return false, "bad id" end
  if prof ~= rec.by then return false, "signup not by author" end
  if rec.del ~= true or rec.d ~= nil then
    local vok, verr = Post.ValidateSignup(rec.d)
    if not vok then return false, verr end
  end
  local postExp = ctx and ctx.postExp and ctx.postExp(postId)
  local limit
  if postExp then limit = postExp + SIGNUP_SLACK
  else limit = rec.t + SIGNUP_UNKNOWN end
  if rec.exp > limit then return false, "exp too far" end
  return true
end

local READY_KEYS = { roles = true, level = true }

function Post.ValidateReady(d)
  if type(d) ~= "table" then return false, "payload not a table" end
  if not onlyKeys(d, READY_KEYS) then return false, "unknown field" end
  if not checkRoleSet(d.roles) then return false, "bad roles" end
  if not (isInt(d.level) and d.level >= 1 and d.level <= 80) then return false, "bad level" end
  return true
end

function Post.ClampReady(forSeconds)
  if type(forSeconds) ~= "number" or forSeconds ~= forSeconds or forSeconds == math.huge
      or forSeconds == -math.huge then
    return READY_DEFAULT
  end
  forSeconds = math.floor(forSeconds)
  if forSeconds < 1 then return 1 end
  if forSeconds > READY_MAX then return READY_MAX end
  return forSeconds
end

function Post.CheckIncomingReady(rec, existing)
  local ok, err = checkShape(rec, existing)
  if not ok then return false, err end
  if rec.id ~= rec.by then return false, "bad id" end
  if rec.del ~= true or rec.d ~= nil then
    local vok, verr = Post.ValidateReady(rec.d)
    if not vok then return false, verr end
  end
  if rec.exp > rec.t + READY_MAX then return false, "exp too far" end
  return true
end

ns.Groups.Post = Post
