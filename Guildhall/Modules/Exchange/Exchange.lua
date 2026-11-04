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
  self.db = db
  self.listings = ns.ReplicatedSet.new(SET_NAME, db.listings, { now = ctx.now })
  self.imported = ns.ReplicatedSet.new("exchange.imported", db.imported, { now = ctx.now })
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
        now = self.now(),
      })
    end,
    onApplied = logApplied,
  })
  return self
end

function Ex:Start()
  self.listings:Purge()
  self.imported:Purge()
  self.sync:Start()
end

function Ex:_gate()
  if self.compat:IsTrial() then return "trial" end
  if self.profile:NeedsConsent() then return "consent" end
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

function Ex:Get(id)
  return self.listings:Get(id) or self.imported:Get(id)
end

function Ex:RemoveImported(id)
  self.db.imported[id] = nil
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

if ns.RegisterModule then
  ns.RegisterModule("Exchange", {
    OnLogin = function(n)
      if not n.services then return end
      n.exchange = n.Exchange.Create(n.services)
      n.exchange:Start()
    end,
    tab = { title = "Exchange", build = function(parent) return ns.Exchange.Board.Build(parent) end },
  })
end
