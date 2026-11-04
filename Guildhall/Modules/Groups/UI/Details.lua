local ADDON, ns = ...

-- Groups tab, details pane: one post or calendar event, on the right of the board.
--   Dungeon post: header, "Needs: [item]" (searches the Exchange), the group so far, signups waiting
--     (the poster gets role buttons and Invite, which only fills the chat box), the credit footnote and
--     the poster's or the member's buttons.
--   Raid post or calendar event: header line, checklist picker and summary, the roster (one column per
--     checklist line, Prepared, Flex), the footnote, "Confirm all checked" and "Edit checklist".
-- Details.Build(view, panel, width) makes the widgets (view.d); Details.Show(entry) fills them, entry =
-- { kind = "post", post } or { kind = "calendar", ev }, or nil for nothing.
-- Shared display helpers (names, server time, role tags, permissions) live here too; View uses them.
-- Reads only through ns.groups services, ns.services and ns.leaderboard; never invites anyone.
ns.Groups = ns.Groups or {}
local UI = ns.UI
local Util = ns.Util
local Details = ns.Groups.Details or {}
ns.Groups.Details = Details

local GOLD, GRAY, TAN = { 1, 0.82, 0 }, { 0.62, 0.62, 0.62 }, { 0.78, 0.73, 0.54 }
local ROLES = { "t", "h", "d" }
local LETTER = { t = "T", h = "H", d = "D" }
local ROLE_NAME = { t = "Tank", h = "Healer", d = "DPS" }
local NEED_WORD = { t = "tank", h = "healer", d = "DPS" }
local GROUP_ROWS, SIGN_ROWS, ROSTER_ROWS, LINE_COLS = 5, 3, 6, 3
-- Dungeon pane, y from the panel's top: the signups header line (with "+N more" at its right), the
-- rows, then the footnote (2 wrapped lines, FOOT_H reserved) above the 22 px buttons 8 px from the
-- bottom. Details.LAYOUT exposes these for the overlap test.
local SIGN_HEAD_Y, SIGN_Y, SIGN_H, FOOT_Y, FOOT_H, BUTTON_H, BUTTON_GAP = 184, 202, 22, 272, 28, 22, 8
Details.LAYOUT = { signHead = SIGN_HEAD_Y, signTop = SIGN_Y, signRow = SIGN_H, signRows = SIGN_ROWS,
  foot = FOOT_Y, footH = FOOT_H, button = BUTTON_H, buttonGap = BUTTON_GAP }
local ACTIVE = 7200 -- a raid within 2 h of its start counts the current group as its roster

local DUNGEON_FOOT = "Credit when the group kills the last boss with 3+ guild members. Once per dungeon per player per day."
local RAID_FOOT = "Ticks are pre-filled from each raider's own bag and gear check. Only your tick earns \"prepared\" "
  .. "credit. Every change is in the change history."
local ERRORS = {
  consent = "Choose which characters to share first (Settings).",
  trial = "Trial accounts can't post or sign up.",
  excluded = "This character isn't shared with the guild.",
  ["not owner"] = "Only the poster can do that.",
  ["no permission"] = "You don't have permission for that.",
  ["unknown post"] = "That run has closed.",
}

local view -- the Groups view this pane belongs to

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

-- Shared helpers ------------------------------------------------------------------------------

local function services() return ns.services end
local function lb() return ns.leaderboard end

function Details.Now()
  local s = services()
  return s and s.now() or 0
end

function Details.Tz()
  local s, l = services(), lb()
  local cfg = l and (l.realConfig or l.config)
  return ns.Scoring.Clock(cfg, s and s.compat, Details.Now()).tz or 0
end

-- Server-time text of an epoch second (the leaderboard's rule).
function Details.ServerDate(t, fmt)
  local f = date or os.date
  return f("!" .. fmt, t + Details.Tz())
end

-- Ruling T11c: one wall-clock rule. Post and event start times are realm wall-clock, so they are
-- shown (and, in the form, entered) with the real realm offset, Compat:ServerOffset(); the
-- leaderboard clock (Details.Tz) only when that is unknown. Details.Tz (cfg:Tz) stays for day and
-- month boundary keys.
function Details.WallTz()
  local s = services()
  local c = s and s.compat
  local off = c and c.ServerOffset and c:ServerOffset() or nil
  if type(off) == "number" then return off end
  return Details.Tz()
end

-- Server wall-clock text of a start time.
function Details.StartDate(t, fmt)
  local f = date or os.date
  return f("!" .. fmt, t + Details.WallTz())
end

function Details.Today() return ns.Scoring.DayKey(Details.Now(), Details.Tz()) end

local function profiles()
  local s = services()
  return s and s.profile
end

-- A profile's character: online, else the one on its record, else its first.
function Details.CharOf(profileId)
  local p = profiles()
  if not p then return nil end
  local char = p:OnlineChar(profileId)
  if not char and p.set then
    local rec = p.set:Get(profileId)
    char = rec and rec.char
  end
  return char or (p:CharsOf(profileId) or {})[1]
end

-- Escaped display name of a profile or a character.
function Details.NameOf(profileId)
  return Util.Escape(Util.DisplayName(Details.CharOf(profileId) or tostring(profileId)))
end

function Details.CharName(char) return Util.Escape(Util.DisplayName(char)) end

function Details.Online(profileId)
  local p = profiles()
  return p ~= nil and p:OnlineChar(profileId) ~= nil
end

function Details.MyId()
  local p = profiles()
  return p and p:Id()
end

-- "T/D" for a role set.
function Details.RoleText(roles)
  local out = {}
  for _, r in ipairs(ROLES) do
    if type(roles) == "table" and roles[r] then out[#out + 1] = LETTER[r] end
  end
  return table.concat(out, "/")
end

-- Role tags of a post: "T full  H 1  D 3" for each role the run has a slot for.
function Details.Tags(post, filled)
  local d, out = post.d, {}
  for _, r in ipairs(ROLES) do
    local slots = (d.need[r] or 0) + (d.role == r and 1 or 0)
    if slots > 0 then
      local open = filled.open[r] or 0
      out[#out + 1] = LETTER[r] .. " " .. (open == 0 and "full" or tostring(open))
    end
  end
  return table.concat(out, "  ")
end

function Details.Dot(tex, online)
  if online then tex:SetColorTexture(0.25, 0.82, 0.25) else tex:SetColorTexture(0.4, 0.4, 0.4) end
end

function Details.ErrorText(err)
  return ERRORS[err] or ("That didn't work: " .. tostring(err or "unknown error"))
end

local function perms()
  local l = lb()
  return l and (l.realPermissions or l.permissions)
end

-- Whether this character holds a group permission tonight in an instance (a raidlead grant counts
-- on nights it led or assisted a verified kill there).
function Details.Can(key, instance)
  local s, p = services(), perms()
  if not (s and p and instance) then return false end
  local leaders = ns.Groups.Credit and ns.Groups.Credit.RaidLeaders(instance, Details.Today()) or {}
  return p:Can(s.playerChar, key, { raidLeaders = leaders }) == true
end

-- An item's plain name for an id, link or typed name; nil for an id the client hasn't cached.
function Details.ItemName(item)
  if type(item) == "number" then
    local s = services()
    return s and s.compat and s.compat.ItemName and s.compat:ItemName(item) or nil
  end
  if type(item) ~= "string" then return nil end
  return Util.ItemName(item)
end

-- Widgets -------------------------------------------------------------------------------------

local function text(parent, font, x, y, width, color)
  local fs = UI.Text(parent, font)
  fs:SetPoint("TOPLEFT", x, -y)
  if width then fs:SetWidth(width) end
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  fs:SetJustifyH("LEFT")
  if color then fs:SetTextColor(color[1], color[2], color[3]) end
  return fs
end

local function wrapped(fs)
  if fs.SetWordWrap then fs:SetWordWrap(true) end
  return fs
end

local function frameRow(parent, x, y, width, height)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(width, height)
  row:SetPoint("TOPLEFT", x, -y)
  row:Hide()
  return row
end

local function dot(parent, x)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(8, 8)
  t:SetPoint("LEFT", x, 0)
  return t
end

-- Actions -------------------------------------------------------------------------------------

local function say(textOrNil, isError) if view and view.say then view.say(textOrNil, isError) end end
local function refresh() if view and view.refresh then view.refresh() end end

local function result(ok, err, done)
  if ok then say(done) else say(Details.ErrorText(err), true) end
  refresh()
end

local function svc() return ns.groups and ns.groups.svc end

local function personalRoles()
  local db = GuildhallDB
  local g = type(db) == "table" and type(db.personal) == "table" and db.personal.groups
  return type(g) == "table" and type(g.roles) == "table" and g.roles or { d = true }
end

-- Role choices for Sign up and Ready now: one per role, plus the usual roles when they are several.
function Details.RoleItems()
  local items = {}
  for _, r in ipairs(ROLES) do items[#items + 1] = { label = ROLE_NAME[r], value = { [r] = true } } end
  local usual = personalRoles()
  local n = 0
  for _, r in ipairs(ROLES) do if usual[r] then n = n + 1 end end
  if n > 1 then
    local set = {}
    for _, r in ipairs(ROLES) do if usual[r] then set[r] = true end end
    items[#items + 1] = { label = "My usual roles (" .. Details.RoleText(set) .. ")", value = set }
  end
  return items
end
Details.PersonalRoles = personalRoles

-- "LFM Stratholme (Undead): need 1 healer, 3 DPS. Whisper Dor." (plain chat text, nothing escaped)
local function chatLine(post, filled)
  local d = post.d
  local entry = ns.Instances.Get(d.instance)
  local need = {}
  for _, r in ipairs(ROLES) do
    local n = filled.open[r] or 0
    if n > 0 then need[#need + 1] = n .. " " .. NEED_WORD[r] end
  end
  local when = d.start and (" " .. Details.StartDate(d.start, "%a %H:%M") .. " server time") or ""
  local who = Util.DisplayName(post.char or Details.CharOf(post.by) or "")
  if #need == 0 then return entry.name .. when .. ": group full." end
  return "LFM " .. entry.name .. when .. ": need " .. table.concat(need, ", ") .. ". Whisper " .. who .. "."
end

-- Dungeon pane ----------------------------------------------------------------------------------

local function agoText(t)
  local mins = math.max(0, math.floor((Details.Now() - (t or 0)) / 60))
  if mins < 60 then return mins .. " min ago" end
  return math.floor(mins / 60) .. " h ago"
end

local function whenText(start)
  if start == nil then return "Now" end
  return Details.StartDate(start, "%a %d %b %H:%M")
end

local function showDungeon(post)
  local d, g = view.d, svc()
  local pd = post.d
  local entry = ns.Instances.Get(pd.instance)
  local me = Details.MyId()
  local mine = post.by == me
  local filled = g:Filled(post)
  d.title:SetText(Util.Escape(entry.name) .. " · " .. whenText(pd.start))
  d.title:Show()
  local sub = "Posted by " .. Details.NameOf(post.by) .. " " .. agoText(pd.created or post.t)
  if type(pd.note) == "string" and pd.note ~= "" then sub = sub .. " · \"" .. Util.Escape(pd.note) .. "\"" end
  d.sub:SetText(sub)
  d.sub:Show()
  if pd.want ~= nil then
    local want = Details.ItemName(pd.want)
    if want then
      d.needs.label:SetText("Needs: [" .. Util.Escape(want) .. "]")
      d.needs.label:SetTextColor(0.5, 0.78, 1)
      d.needs.search = want
    else -- an item the client hasn't cached: plain text, nothing to search for
      d.needs.label:SetText("Needs: item")
      d.needs.label:SetTextColor(GRAY[1], GRAY[2], GRAY[3])
    end
    d.needs:Show()
  end

  -- the group so far, by role
  local people, online = {}, 0
  for _, r in ipairs(ROLES) do
    for _, pid in ipairs(filled[r]) do
      people[#people + 1] = { pid = pid, role = r }
      if Details.Online(pid) then online = online + 1 end
    end
  end
  d.groupHead:SetText("Group (" .. #people .. " of " .. entry.size .. ") · " .. online .. " online")
  d.groupHead:Show()
  for i, row in ipairs(d.groupRows) do
    local p = people[i]
    if p and not (i == GROUP_ROWS and #people > GROUP_ROWS) then
      Details.Dot(row.dot, Details.Online(p.pid))
      row.name:SetText(Details.NameOf(p.pid))
      row.role:SetText(ROLE_NAME[p.role])
      row.dot:Show()
      row:Show()
    elseif p then
      row.dot:Hide()
      row.name:SetText("+" .. (#people - GROUP_ROWS + 1) .. " more")
      row.role:SetText("")
      row:Show()
    end
  end

  -- signups not yet in the group
  local waiting, signedUp = {}, false
  local assign = pd.assign or {}
  for _, su in ipairs(g:Signups(post.id)) do
    if su.profile == me then signedUp = true end
    if su.profile ~= post.by and assign[su.profile] == nil then waiting[#waiting + 1] = su end
  end
  if #waiting > 0 then
    d.signHead:SetText("Signups waiting")
    d.signHead:Show()
  end
  for i, row in ipairs(d.signRows) do
    local su = waiting[i]
    row.signup = su or false
    if su then
      Details.Dot(row.dot, Details.Online(su.profile))
      row.name:SetText(Details.CharName(su.char or Details.CharOf(su.profile) or su.profile))
      row.offer:SetText(Details.RoleText(su.roles))
      for _, r in ipairs(ROLES) do
        local b = row.roles[r]
        if mine then
          b:Show()
          if su.roles[r] then b:Enable() else b:Disable() end
        else
          b:Hide()
        end
      end
      if mine then row.invite:Show() else row.invite:Hide() end
      row:Show()
    end
  end
  if #waiting > SIGN_ROWS then
    d.signMore:SetText("+" .. (#waiting - SIGN_ROWS) .. " more")
    d.signMore:Show()
  end

  d.foot:SetText(DUNGEON_FOOT)
  d.foot:Show()
  if mine then
    d.postLF:Show(); d.copy:Show(); d.close:Show()
  elseif signedUp then
    d.withdraw:Show()
  else
    d.signup:Show()
  end
  d.post, d.filled = post, filled
end

-- Raid pane -------------------------------------------------------------------------------------

local function ownChars()
  local s, p = services(), profiles()
  local own = {}
  if s and s.playerChar then own[s.playerChar] = true end
  if p then
    for _, ch in ipairs(p:CharsOf(p:Id()) or {}) do own[ch] = true end
  end
  return own
end

-- The checklist shown for an instance: the one picked here if still live, else the active one.
local function checklistFor(instance)
  local cl = ns.groups.checklist
  local id = view.clPick[instance]
  if id and cl.Get then
    local c = cl:Get(id)
    if c and c.instance == instance then return c end
  end
  return cl:Active(instance, nil)
end

local function lineLabel(l)
  if l.kind == "item" then
    return l.count .. "x " .. Util.Escape(Details.ItemName(l.item) or "?")
  elseif l.kind == "enchants" then
    return "All gear enchanted"
  end
  return Util.Escape(tostring(l.text or ""))
end

local function summary(c)
  if not c then return "No checklist for this raid yet." end
  local parts = {}
  for i, l in ipairs(c.lines or {}) do
    if i > LINE_COLS then
      parts[#parts + 1] = "+" .. (#c.lines - LINE_COLS) .. " more"
      break
    end
    parts[#parts + 1] = i .. ": " .. lineLabel(l)
  end
  if #parts == 0 then return "This checklist has no lines." end
  return table.concat(parts, " · ")
end

local function rosterOf(entry)
  local chars, seen = {}, {}
  local function add(ch)
    if type(ch) == "string" and ch ~= "" and not seen[ch] then seen[ch] = true; chars[#chars + 1] = ch end
  end
  local start = entry.kind == "post" and entry.post.d.start or (entry.ev and entry.ev.start)
  local s = services()
  local snap = s and s.compat and s.compat.GroupSnapshot and s.compat:GroupSnapshot() or nil
  if snap and (start == nil or math.abs(start - Details.Now()) <= ACTIVE) then
    for _, ch in ipairs(snap.members) do add(ch) end
  end
  if entry.kind == "post" then
    local post = entry.post
    add(post.char or Details.CharOf(post.by))
    for _, su in ipairs(svc():Signups(post.id)) do add(su.char or Details.CharOf(su.profile)) end
  else
    local cal = ns.groups.calendar
    for _, ch in ipairs(cal.Attendees and cal:Attendees(entry.ev.title, entry.ev.start) or {}) do add(ch) end
  end
  table.sort(chars, function(a, b)
    local an, bn = Util.DisplayName(a), Util.DisplayName(b)
    if an ~= bn then return an < bn end
    return a < b
  end)
  return chars, snap
end

local function tickKey(instance) return tostring(instance) .. "|" .. Details.Today() end

-- The Prepared box for a raider: this client's unsaved tick, else the newest confirmation, else
-- the raider's own check.
local function boxValue(instance, char, night)
  local ticks = view.ticks[tickKey(instance)]
  if ticks and ticks[char] ~= nil then return ticks[char] end
  local n = night[char]
  if n and n.confirmed ~= nil then return n.confirmed end
  return n ~= nil and n.ok == true
end

local function cellText(char, i, line, night, mineCheck)
  if mineCheck then
    local r = mineCheck.lines[i]
    if r and r.ok == true then return "ok" elseif r and r.ok == false then return "no" end
    return "?"
  end
  local n = night[char]
  if n and n.ok == true and line.kind ~= "manual" then return "ok" end
  return "?"
end

local function showRaid(entry)
  local d, g = view.d, ns.groups
  local instance = entry.kind == "post" and entry.post.d.instance or entry.ev.instance
  local inst = instance and ns.Instances.Get(instance) or nil
  if not inst then instance = nil end
  local title = entry.kind == "post" and Util.Escape(inst.name) or Util.Escape(entry.ev.title)
  if entry.kind == "calendar" then title = title .. "  |cff9d9d9dCalendar|r" end
  d.title:SetText(title)
  d.title:Show()

  local chars, snap = rosterOf(entry)
  local start = entry.kind == "post" and entry.post.d.start or entry.ev.start
  local accepted = entry.kind == "post" and (1 + #svc():Signups(entry.post.id)) or (entry.ev.accepted or 0)
  local inRaid, guild = 0, 0
  local s = services()
  if snap then
    inRaid = #snap.members
    for _, ch in ipairs(snap.members) do
      if s.roster and s.roster.IsMember and s.roster:IsMember(ch) == true then guild = guild + 1 end
    end
  end
  local head = (start and (Details.StartDate(start, "%a %d %b %H:%M") .. " server time") or "Now")
    .. " · " .. accepted .. " accepted · in raid now: " .. inRaid .. " (" .. guild .. " guild)"
  if inst then
    local k = g.credit and g.credit.Bosses and g.credit:Bosses(instance, Details.Today()) or 0
    head = head .. " · bosses " .. k .. " / " .. #inst.bosses
  end
  d.raidSub:SetText(head)
  d.raidSub:Show()

  local c = instance and checklistFor(instance) or nil
  if instance then
    d.clBtn:SetText("Checklist: " .. (c and Util.Escape(c.name) or "none"))
    d.clBtn:Show()
    d.clSummary:SetText(summary(c))
    d.clSummary:Show()
  end
  local lines = c and c.lines or {}
  local cols = math.min(#lines, LINE_COLS)
  d.hRaider:Show()
  for i, h in ipairs(d.hLines) do
    if i <= cols then h:SetText(tostring(i)); h:Show() end
  end
  if instance then d.hPrepared:Show(); d.hFlex:Show() end

  local night = instance and g.checklist.Night and g.checklist:Night(instance) or {}
  local flex = instance and g.flex and g.flex.Status and g.flex:Status(instance) or {}
  local canPrep = instance ~= nil and Details.Can("prepared", instance)
  local canFlex = instance ~= nil and Details.Can("flex", instance)
  local own = ownChars()
  local mineCheck = c and g.checklist.SelfCheck and g.checklist:SelfCheck(c) or nil
  view.rosterOffset = math.max(0, math.min(view.rosterOffset or 0, #chars - ROSTER_ROWS))
  for i, row in ipairs(d.roster) do
    local char = chars[view.rosterOffset + i]
    row.char, row.instance = char or false, instance or false
    if char then
      row.name:SetText(Details.CharName(char))
      for j, cell in ipairs(row.cells) do
        if j <= cols then
          cell:SetText(cellText(char, j, lines[j], night, own[char] and mineCheck or nil))
          cell:Show()
        else
          cell:Hide()
        end
      end
      if instance then
        row.check:SetChecked(boxValue(instance, char, night))
        if canPrep then row.check:Enable() else row.check:Disable() end
        row.check:Show()
      else
        row.check:Hide()
      end
      local st = flex[char]
      row.flex:Hide()
      row.flexText:SetText("")
      row.flexAsk = false
      if instance and not own[char] then
        if st and st.done then
          row.flexText:SetText("Switched")
        elseif st and st.mine then
          row.flex:SetText("Mark switched")
          row.flexAsk = st.ask
          row.flex:Show()
        elseif st then
          row.flexText:SetText("Asked")
        elseif canFlex then
          row.flex:SetText("Ask to switch")
          row.flex:Show()
        end
      end
      row:Show()
    else
      row:Hide()
    end
  end
  if #chars == 0 then
    d.rosterEmpty:SetText("Nobody has signed up yet.")
    d.rosterEmpty:Show()
  end
  d.raidFoot:SetText(RAID_FOOT)
  d.raidFoot:Show()
  if canPrep and #chars > 0 then d.confirmAll:Show() end
  if instance and Details.Can("checklists", instance) then d.editCl:Show() end
  d.raid = { instance = instance, chars = chars, night = night, checklist = c }
end

-- Clear / show ----------------------------------------------------------------------------------

local function clear()
  local d = view.d
  for _, w in ipairs(d.hideable) do w:Hide() end
  d.post, d.filled, d.raid = nil, nil, nil
  -- false, not nil: these are fields on frames
  d.needs.search = false
  for _, row in ipairs(d.signRows) do row.signup = false end
  for _, row in ipairs(d.roster) do row.char, row.instance, row.flexAsk = false, false, false end
end

function Details.Show(entry)
  if not view then return end
  clear()
  if not entry or not ns.groups then return end
  if entry.kind == "post" then
    local inst = ns.Instances.Get(entry.post.d.instance)
    if inst and inst.kind == "raid" then showRaid(entry) else showDungeon(entry.post) end
  else
    showRaid(entry)
  end
end

-- Build -----------------------------------------------------------------------------------------

-- Hands the boxes to the Checklist service, which decides what to publish.
local function confirmAll()
  local r = view.d.raid
  if not (r and r.instance) then return end
  local ticks = view.ticks[tickKey(r.instance)] or {}
  local boxes = {}
  for _, char in ipairs(r.chars) do
    boxes[char] = { checked = boxValue(r.instance, char, r.night) == true, changed = ticks[char] ~= nil }
  end
  local _, err = ns.groups.checklist:ConfirmTicks(r.instance, boxes)
  view.ticks[tickKey(r.instance)] = nil
  result(err == nil, err, "Prepared ticks confirmed.")
end

function Details.Build(v, panel, width, height)
  view = v
  Details.LAYOUT.panel = height or 336
  local d = { hideable = {}, groupRows = {}, signRows = {}, roster = {}, hLines = {} }
  v.d = d
  v.clPick = v.clPick or {}
  v.ticks = v.ticks or {}
  local W = width - 24
  local function keep(w) d.hideable[#d.hideable + 1] = w; return w end

  d.title = keep(text(panel, "GameFontNormalLarge", 12, 10, W, GOLD))
  d.sub = keep(text(panel, "GameFontNormal", 12, 34, W, TAN))

  -- Needs: [item] (a link-styled button)
  d.needs = keep(CreateFrame("Button", nil, panel))
  d.needs:SetSize(W, 18)
  d.needs:SetPoint("TOPLEFT", 12, -52)
  d.needs.label = UI.Text(d.needs, "GameFontHighlight")
  d.needs.label:SetPoint("LEFT", 0, 0)
  d.needs.label:SetWidth(W)
  if d.needs.label.SetWordWrap then d.needs.label:SetWordWrap(false) end
  d.needs.label:SetJustifyH("LEFT")
  d.needs.label:SetTextColor(0.5, 0.78, 1)
  on(d.needs, "OnClick", function(self)
    if self.search and ns.ExchangeUI and ns.ExchangeUI.Search then ns.ExchangeUI.Search(self.search) end
  end)

  d.groupHead = keep(text(panel, "GameFontNormal", 12, 76, W, GOLD))
  for i = 1, GROUP_ROWS do
    local row = keep(frameRow(panel, 12, 94 + (i - 1) * 17, W, 17))
    row.dot = dot(row, 2)
    row.name = text(row, "GameFontHighlightSmall", 16, 2, 150)
    row.role = text(row, "GameFontNormalSmall", 172, 2, 80, GRAY)
    d.groupRows[i] = row
  end

  d.signHead = keep(text(panel, "GameFontNormal", 12, SIGN_HEAD_Y, 200, GOLD))
  d.signMore = keep(text(panel, "GameFontDisableSmall", 0, 0, 120))
  d.signMore:ClearAllPoints()
  d.signMore:SetPoint("TOPRIGHT", -12, -(SIGN_HEAD_Y + 2))
  d.signMore:SetJustifyH("RIGHT")
  for i = 1, SIGN_ROWS do
    local row = keep(frameRow(panel, 12, SIGN_Y + (i - 1) * SIGN_H, W, SIGN_H))
    row.dot = dot(row, 2)
    row.name = text(row, "GameFontHighlightSmall", 16, 5, 110)
    row.offer = text(row, "GameFontNormalSmall", 130, 5, 50, GRAY)
    row.roles = {}
    local x = 184
    for _, r in ipairs(ROLES) do
      local role = r
      local b = UI.Button(row, LETTER[r], 28, function()
        local su = row.signup
        local post = view.d.post
        if not (su and post) then return end
        local ok, err = svc():Assign(post.id, su.profile, role)
        result(ok, err, Details.NameOf(su.profile) .. " added as " .. ROLE_NAME[role] .. ".")
      end)
      b:SetPoint("LEFT", x, 0)
      x = x + 30
      row.roles[r] = b
    end
    row.invite = UI.Button(row, "Invite", 64, function()
      local su = row.signup
      if not su then return end
      local s = services()
      local char = su.char or Details.CharOf(su.profile)
      if s and s.compat and char then s.compat:OpenChat("/invite " .. Util.DisplayName(char)) end
    end)
    row.invite:SetPoint("LEFT", x + 4, 0)
    d.signRows[i] = row
  end
  d.foot = keep(wrapped(text(panel, "GameFontNormalSmall", 12, FOOT_Y, W, GRAY)))

  -- Raid pane
  d.raidSub = keep(wrapped(text(panel, "GameFontNormal", 12, 32, W, TAN)))
  d.clBtn = keep(UI.Button(panel, "Checklist: none", 230, function()
    local r = view.d.raid
    if not (r and r.instance) then return end
    local items = {}
    for _, c in ipairs(ns.groups.checklist:List(r.instance)) do
      items[#items + 1] = { label = Util.Escape(c.name), value = c.id }
    end
    if #items == 0 then items[1] = { label = "No checklists for this raid yet", value = false } end
    UI.PickList(view.d.clBtn, items, function(id)
      if not id then return end
      view.clPick[r.instance] = id
      refresh()
    end, r.checklist and r.checklist.id)
  end))
  d.clBtn:SetPoint("TOPLEFT", 12, -62)
  d.clSummary = keep(text(panel, "GameFontNormalSmall", 12, 88, W, GRAY))

  -- roster columns: Raider 100, three line columns of 36, Prepared 56, Flex 112
  local COL_LINE, COL_PREP, COL_FLEX = 112, 240, 300
  d.hRaider = keep(text(panel, "GameFontNormalSmall", 12, 108, 96, GRAY))
  d.hRaider:SetText("Raider")
  for i = 1, LINE_COLS do
    local h = keep(text(panel, "GameFontNormalSmall", COL_LINE + (i - 1) * 40, 108, 36, GRAY))
    h:SetJustifyH("CENTER")
    d.hLines[i] = h
  end
  d.hPrepared = keep(text(panel, "GameFontNormalSmall", COL_PREP, 108, 56, GRAY))
  d.hPrepared:SetText("Prepared")
  d.hFlex = keep(text(panel, "GameFontNormalSmall", COL_FLEX, 108, 112, GRAY))
  d.hFlex:SetText("Flex")
  for i = 1, ROSTER_ROWS do
    local row = keep(frameRow(panel, 0, 124 + (i - 1) * 20, width, 20))
    row.name = text(row, "GameFontHighlightSmall", 12, 4, 96)
    row.cells = {}
    for j = 1, LINE_COLS do
      local cell = text(row, "GameFontHighlightSmall", COL_LINE + (j - 1) * 40, 4, 36)
      cell:SetJustifyH("CENTER")
      row.cells[j] = cell
    end
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("TOPLEFT", COL_PREP + 14, 0)
    on(row.check, "OnClick", function(self)
      if not (row.char and row.instance) then return end
      local key = tickKey(row.instance)
      view.ticks[key] = view.ticks[key] or {}
      view.ticks[key][row.char] = self:GetChecked() and true or false
    end)
    row.flex = UI.Button(row, "Ask to switch", 108, function()
      if not (row.char and row.instance) then return end
      local fx = ns.groups.flex
      if row.flexAsk then
        local ok, err = fx:Tick(row.flexAsk)
        result(ok, err, "Marked as switched.")
      else
        local ok, err = fx:Ask(row.char, row.instance)
        result(ok, err, "Asked " .. Details.CharName(row.char) .. " to switch spec.")
      end
    end)
    row.flex:SetPoint("TOPLEFT", COL_FLEX, 0)
    row.flexText = text(row, "GameFontNormalSmall", COL_FLEX, 4, 108, GRAY)
    d.roster[i] = row
  end
  d.rosterEmpty = keep(text(panel, "GameFontDisable", 12, 128, W))
  panel:EnableMouseWheel(true)
  on(panel, "OnMouseWheel", function(_, delta)
    if not view.d.raid then return end
    view.rosterOffset = (view.rosterOffset or 0) - delta
    refresh()
  end)
  d.raidFoot = keep(wrapped(text(panel, "GameFontNormalSmall", 12, 250, W, GRAY)))

  -- Buttons along the bottom
  local function bottom(label, w, fn, anchor)
    local b = keep(UI.Button(panel, label, w, fn))
    if anchor then b:SetPoint("LEFT", anchor, "RIGHT", 6, 0) else b:SetPoint("BOTTOMLEFT", 12, BUTTON_GAP) end
    return b
  end
  d.postLF = bottom("Post LF on Exchange", 150, function()
    local post = view.d.post
    if not (post and ns.ExchangeUI and ns.ExchangeUI.OpenForm) then return end
    ns.ExchangeUI.OpenForm({ kind = "LF", item = post.d.want })
  end)
  d.copy = bottom("Copy for chat", 110, function()
    local post, s = view.d.post, services()
    if post and s and s.compat then s.compat:OpenChat(chatLine(post, view.d.filled)) end
  end, d.postLF)
  d.close = bottom("Close post", 96, function()
    local post = view.d.post
    if not post then return end
    local ok, err = svc():Close(post.id)
    result(ok, err, "Post closed.")
  end, d.copy)
  d.signup = bottom("Sign up", 110, function()
    local post = view.d.post
    if not post then return end
    UI.PickList(view.d.signup, Details.RoleItems(), function(roles)
      local ok, err = svc():SignUp(post.id, roles)
      result(ok, err, "Signed up.")
    end)
  end)
  d.withdraw = bottom("Withdraw", 110, function()
    local post = view.d.post
    if not post then return end
    local ok, err = svc():Withdraw(post.id)
    result(ok, err, "Signup withdrawn.")
  end)
  d.confirmAll = bottom("Confirm all checked", 150, confirmAll)
  d.editCl = bottom("Edit checklist", 120, function()
    local r = view.d.raid
    if not (r and r.instance) then return end
    local ed = ns.Groups.ChecklistEditor
    if ed and ed.Open then
      ed.Open(r.instance, r.checklist and r.checklist.id or nil)
    else
      say("The checklist editor isn't available in this version.", true)
    end
  end, d.confirmAll)
  clear()
  return d
end
