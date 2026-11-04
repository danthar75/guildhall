local ADDON, ns = ...

-- Queue of mail drafts to pre-fill at the next mailbox. The store is a
-- SavedVariables array, mutated in place: drafts are appended in FIFO order,
-- and store.nextId holds the next draft id (monotonically increasing integer,
-- never reused even after removals).
ns.Exchange = ns.Exchange or {}

local MailDrafts = {}
MailDrafts.__index = MailDrafts

function MailDrafts.new(store)
  return setmetatable({ store = store }, MailDrafts)
end

local function nextId(store)
  local n = store.nextId
  if type(n) ~= "number" then
    n = 1
    for _, d in ipairs(store) do
      if type(d.id) == "number" and d.id >= n then n = d.id + 1 end
    end
  end
  store.nextId = n + 1
  return n
end

-- Returns the new draft, or nil when listingId is already queued.
function MailDrafts:Add(to, subject, body, listingId)
  local store = self.store
  if listingId ~= nil then
    for _, d in ipairs(store) do
      if d.listingId == listingId then return nil end
    end
  end
  local draft = { id = nextId(store), to = to, subject = subject, body = body, listingId = listingId }
  if _G.time then draft.t = _G.time() end
  store[#store + 1] = draft
  return draft
end

function MailDrafts:Next()
  return self.store[1]
end

function MailDrafts:Remove(draftId)
  for i, d in ipairs(self.store) do
    if d.id == draftId then
      table.remove(self.store, i)
      return
    end
  end
end

function MailDrafts:Count()
  return #self.store
end

ns.Exchange.MailDrafts = MailDrafts
