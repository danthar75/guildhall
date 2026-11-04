local ADDON, ns = ...

-- Groups: the new post form. Form.Open(prefill) shows it; prefill = { instance?, role? }.
--   Run (dungeons by name, then raids by tier), your role, "Still need" (filled from the run's size
--   and your role, editable), When (Now, or Scheduled: a day in the next 14 and an "HH:MM" server
--   time), a 120-byte note, "Run needs" (an item slot or a typed name), "Remind signups 15 min
--   before" and a preview line. Post sends the payload to ns.groups.svc:Post, which does all the
--   validation; its error codes are shown with the form's copy (Form.ErrorText).
-- Scheduled times are realm wall-clock: converted to epoch with the realm offset
-- (Compat:ServerOffset, the calendar's rule). An unknown offset refuses to post rather than guess.
-- Item input: shift-click (post-hook on ChatFrameUtil.InsertLink, Classic: ChatEdit_InsertLink),
-- drag and drop onto the slot, or a typed name. A link posts as its item id, a name as typed.
-- Form.ListenLinks(fn) shares that hook with the checklist editor.
-- Named global frame: "GuildhearthUIGroupsForm" (UISpecialFrames needs a name for ESC to close it).
ns.Groups = ns.Groups or {}
local UI = ns.UI
local Util = ns.Util
local Form = {}
ns.Groups.Form = Form

local WIDTH, HEIGHT = 440, 470
local NOTE_MAX, DAYS = 120, 14
local ROLES = { "t", "h", "d" }
local ROLE_NAME = { t = "Tank", h = "Healer", d = "DPS" }
local NEED_WORD = { t = "tank", h = "healer", d = "DPS" }
local EMPTY_ICON = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local NEED_HINT = "Filled from the run size and your role. Change if friends are coming."

local ERRORS = {
  ["bad instance"] = "Pick a run.",
  ["need exceeds size"] = "That's more people than the run allows.",
  ["start in past"] = "Pick a time in the future.",
  ["bad note"] = "Note is too long.",
  ["start too far"] = "Pick a time within the next 14 days.",
  ["bad need"] = "Still need takes whole numbers from 0 to 39.",
  ["bad role"] = "Pick your role.",
  ["bad want"] = "The item name is too long (64 bytes at most).",
}

local frame
local f = {} -- widgets and state
Form._f = f -- for the specs

local function on(w, event, fn)
  w:SetScript(event, function(...) return UI.Try(fn, ...) end)
end

local function services() return ns.services end

local function now()
  local s = services()
  return s and s.now and s.now() or 0
end

local function compat()
  local s = services()
  return s and s.compat
end

-- Friendly text for a Groups service error code.
function Form.ErrorText(err)
  if ERRORS[err] then return ERRORS[err] end
  local D = ns.Groups.Details
  if D and D.ErrorText then return D.ErrorText(err) end
  return "That didn't work: " .. tostring(err)
end

-- The default "Still need" for a run size and your role: tanks = max(1, size/20 rounded), healers =
-- size/5 rounded, the rest DPS (5: 1/1/3, 40: 2/8/30), less the one slot you fill yourself.
function Form.DefaultNeed(size, role)
  local t = math.max(1, math.floor(size / 20 + 0.5))
  local h = math.floor(size / 5 + 0.5)
  local need = { t = t, h = h, d = math.max(0, size - t - h) }
  if need[role] then need[role] = math.max(0, need[role] - 1) end
  return need
end

-- Shift-click hook -------------------------------------------------------------------------------

local listeners, hooked, splitHooked, linkAt = {}, false, false, nil

local function scanInsertLink(...)
  local c = compat()
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if c and c.Safe then v = c:Safe(v) end
    if type(v) == "string" and v:find("|H", 1, true) then
      -- The first listener that takes the link wins, so one shift-click fills one form.
      for _, fn in ipairs(listeners) do
        if UI.Try(fn, v) == true then
          linkAt = GetTime and GetTime() or nil
          return
        end
      end
      return
    end
  end
end

-- With no chat box open, shift-clicking a bag stack also opens the stack-split popup. When that
-- click just loaded an item into a Groups form, close it (the Exchange form does the same).
local function onSplitShow(self)
  if linkAt and GetTime and GetTime() == linkAt then self:Hide() end
end

-- Runs inside Blizzard's InsertLink call, so nothing may escape.
local function onInsertLink(...) UI.Try(scanInsertLink, ...) end

-- fn(link) runs for an inserted link (each listener checks its own frame is shown) and returns
-- true when it took the link; later listeners then don't see it. Post-hook only, installed once.
function Form.ListenLinks(fn)
  local known = false
  for _, l in ipairs(listeners) do if l == fn then known = true end end
  if not known then listeners[#listeners + 1] = fn end
  if not splitHooked and StackSplitFrame and StackSplitFrame.HookScript then
    StackSplitFrame:HookScript("OnShow", function(self) UI.Try(onSplitShow, self) end)
    splitHooked = true
  end
  if hooked or not hooksecurefunc then return end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then
    hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink)
    hooked = true
  elseif ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", onInsertLink)
    hooked = true
  end
end

-- The item under the cursor as a link, or nil (clears the cursor when it held an item).
function Form.CursorLink()
  if not GetCursorInfo then return nil end
  local c = compat()
  local kind, id, link = GetCursorInfo()
  if c and c.Safe then kind, id, link = c:Safe(kind), c:Safe(id), c:Safe(link) end
  if kind ~= "item" then return nil end
  if ClearCursor then ClearCursor() end
  if Util.IsItemLink(link) then return link end
  return nil
end

function Form.ItemIcon(id)
  if not id then return nil end
  local api = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  if not api then return nil end
  local ok, icon = pcall(api, id)
  local c = compat()
  if ok and c and c.Safe then icon = c:Safe(icon) end
  return ok and icon or nil
end

-- Time --------------------------------------------------------------------------------------------

-- The wall-clock offset for the day labels (Details.WallTz, Ruling T11c).
local function labelOffset()
  local D = ns.Groups.Details
  return D and D.WallTz and D.WallTz() or 0
end

-- Server midnight of today (as an epoch shifted by the offset, i.e. realm wall-clock seconds).
local function wallMidnight(off)
  local wall = now() + off
  return wall - wall % 86400
end

local function dayLabel(i)
  if i == 0 then return "Today" end
  if i == 1 then return "Tomorrow" end
  local fmt = date or os.date
  return fmt("!%a %d %b", wallMidnight(labelOffset()) + i * 86400)
end

-- "HH:MM" -> hours, minutes, or nil.
local function parseTime(s)
  local h, m = tostring(s or ""):match("^%s*(%d%d?):(%d%d)%s*$")
  h, m = tonumber(h), tonumber(m)
  if not h or h > 23 or m > 59 then return nil end
  return h, m
end

-- Epoch of the scheduled day and time, or nil, error text.
local function scheduledStart()
  local h, m = parseTime(f.time:GetText())
  if not h then return nil, "Enter the time as HH:MM, server time." end
  -- Details.WallTz's rule, but posting never falls back to the leaderboard clock: an unknown realm
  -- offset refuses rather than guess.
  local c = compat()
  local off = c and c.ServerOffset and c:ServerOffset()
  if type(off) ~= "number" then
    return nil, "The server time isn't known yet. Try again in a moment, or post for Now."
  end
  return wallMidnight(off) + f.day * 86400 + h * 3600 + m * 60 - off
end

-- State ---------------------------------------------------------------------------------------------

local function setError(text) f.error:SetText(text or "") end

local function needCounts()
  local out = {}
  for _, r in ipairs(ROLES) do
    local n = tonumber(f.need[r]:GetText() or "")
    out[r] = n or 0
  end
  return out
end

local function preview()
  if not f.preview then return end
  local entry = f.instance and ns.Instances.Get(f.instance)
  if not entry then f.preview:SetText("Preview: pick a run"); return end
  local when = "Now"
  if f.when == "scheduled" then
    local h, m = parseTime(f.time:GetText())
    when = dayLabel(f.day) .. " " .. (h and string.format("%02d:%02d", h, m) or "--:--") .. " server time"
  end
  local need, parts = needCounts(), {}
  for _, r in ipairs(ROLES) do
    if need[r] > 0 then parts[#parts + 1] = need[r] .. " " .. NEED_WORD[r] end
  end
  local needText = #parts > 0 and ("need " .. table.concat(parts, ", ")) or "full"
  f.preview:SetText("Preview: " .. entry.name .. " · " .. when .. " · " .. needText)
end

local function fillNeed()
  local entry = f.instance and ns.Instances.Get(f.instance)
  if not entry then return end
  local need = Form.DefaultNeed(entry.size, f.role)
  f.filling = true
  for _, r in ipairs(ROLES) do f.need[r]:SetText(tostring(need[r])) end
  f.filling = nil
  preview()
end

local function setRun(key)
  local entry = key and ns.Instances.Get(key)
  f.instance = entry and key or nil
  f.runBtn:SetText(entry and entry.name or "Pick a run")
  fillNeed()
  preview()
end

local function setRole(role)
  f.role = role
  for _, r in ipairs(ROLES) do f.roles[r]:SetChecked(r == role) end
  fillNeed()
end

local function setWhen(when)
  f.when = when
  f.nowRadio:SetChecked(when == "now")
  f.scheduled:SetChecked(when == "scheduled")
  for _, w in ipairs({ f.dayBtn, f.time, f.timeLabel }) do
    if when == "scheduled" then w:Show() else w:Hide() end
  end
  preview()
end

local function setDay(i)
  f.day = i
  f.dayBtn:SetText(dayLabel(i))
  preview()
end

local function runItems()
  local items = {}
  for _, kind in ipairs({ "dungeon", "raid" }) do
    for _, e in ipairs(ns.Instances.ForPicker(kind)) do
      local label = e.name
      if e.size ~= 5 then label = label .. " (" .. e.size .. ")" end
      items[#items + 1] = { label = label, value = e.key }
    end
  end
  return items
end

local function dayItems()
  local items = {}
  for i = 0, DAYS - 1 do items[#items + 1] = { label = dayLabel(i), value = i } end
  return items
end

-- Run needs: the slot shows a link; typing a different name drops it.
local function showWant()
  local link = f.wantLink
  if link then
    f.icon:SetTexture(Form.ItemIcon(Util.ItemIdFromLink(link)) or UNKNOWN_ICON)
  else
    f.icon:SetTexture(EMPTY_ICON)
  end
end

local function setWantLink(link)
  f.wantLink = link
  f.wantName:SetText(link and Util.ItemName(link) or "")
  showWant()
end

local function want()
  local name = Util.Trim(f.wantName:GetText() or "")
  if f.wantLink and name == Util.ItemName(f.wantLink) then
    local id = tonumber(Util.ItemIdFromLink(f.wantLink))
    if id then return id end
  end
  if name == "" then return nil end
  return name
end

local function payload()
  local note = Util.Trim(f.note:GetText() or "")
  local d = {
    instance = f.instance,
    role = f.role,
    need = needCounts(),
    note = note ~= "" and note or nil,
    want = want(),
  }
  if not f.remind:GetChecked() then d.remind = false end
  if f.when == "scheduled" then
    local start, err = scheduledStart()
    if not start then return nil, err end
    d.start = start
  end
  return d
end

local function submit()
  local g = ns.groups
  if not (g and g.svc) then setError("Guildhearth isn't ready yet. Try again in a moment."); return end
  local d, perr = payload()
  if not d then setError(perr); return end
  local ok, res = g.svc:Post(d)
  if not ok then
    if res == "consent" and ns.Boot and ns.Boot.ShowConsent then ns.Boot.ShowConsent() end
    setError(Form.ErrorText(res))
    return
  end
  setError(nil)
  frame:Hide()
  local View = ns.Groups.View
  if View and View.Refresh then View.Refresh() end
end

local function onLink(link)
  if not (frame and frame:IsShown()) then return end
  if not Util.IsItemLink(link) then return false end
  setWantLink(link)
  return true
end

-- Build ---------------------------------------------------------------------------------------------

local function label(text, x, y, font)
  local t = UI.Text(frame, font or "GameFontNormal", text)
  t:SetPoint("TOPLEFT", x, y)
  return t
end

local function radio(text, x, y, fn)
  local r = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
  r:SetSize(16, 16)
  r:SetPoint("TOPLEFT", x, y)
  local t = UI.Text(frame, "GameFontHighlight", text)
  t:SetPoint("LEFT", r, "RIGHT", 4, 0)
  on(r, "OnClick", fn)
  return r
end

local function input(width)
  local e = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  e:SetSize(width, 20)
  e:SetAutoFocus(false)
  on(e, "OnEscapePressed", function(self) self:ClearFocus() end)
  on(e, "OnEnterPressed", function(self) self:ClearFocus() end)
  return e
end

local function takeCursor()
  local link = Form.CursorLink()
  if link then setWantLink(link) end
end

local function build()
  if frame then return end
  frame = UI.CreatePanel("GuildhearthUIGroupsForm", WIDTH, HEIGHT, "New group post")
  f.frame = frame
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhearthUIGroupsForm") end

  label("Run:", 20, -50)
  f.runBtn = UI.Button(frame, "Pick a run", 240, function()
    UI.PickList(f.runBtn, runItems(), function(key) setRun(key) end, f.instance)
  end)
  f.runBtn:SetPoint("TOPLEFT", 110, -44)

  label("Your role:", 20, -80)
  f.roles = {}
  for i, r in ipairs(ROLES) do
    f.roles[r] = radio(ROLE_NAME[r], 110 + (i - 1) * 90, -79, function() setRole(r) end)
  end

  label("Still need:", 20, -110)
  f.need = {}
  for i, r in ipairs(ROLES) do
    local x = 110 + (i - 1) * 90
    local t = UI.Text(frame, "GameFontHighlight", ROLE_NAME[r])
    t:SetPoint("TOPLEFT", x, -110)
    local e = input(28)
    e:SetNumeric(true)
    e:SetMaxLetters(2)
    e:SetPoint("TOPLEFT", x + 50, -106)
    on(e, "OnTextChanged", function() if not f.filling then preview() end end)
    f.need[r] = e
  end
  local hint = label(NEED_HINT, 20, -130, "GameFontDisableSmall")
  hint:SetWidth(WIDTH - 40)

  label("When:", 20, -158)
  f.nowRadio = radio("Now", 110, -157, function() setWhen("now") end)
  f.scheduled = radio("Scheduled", 200, -157, function() setWhen("scheduled") end)
  f.dayBtn = UI.Button(frame, "Today", 130, function()
    UI.PickList(f.dayBtn, dayItems(), function(i) setDay(i) end, f.day)
  end)
  f.dayBtn:SetPoint("TOPLEFT", 110, -178)
  f.time = input(52)
  f.time:SetMaxLetters(5)
  f.time:SetPoint("TOPLEFT", 252, -180)
  on(f.time, "OnTextChanged", function() preview() end)
  f.timeLabel = UI.Text(frame, "GameFontDisableSmall", "HH:MM server time")
  f.timeLabel:SetPoint("LEFT", f.time, "RIGHT", 8, 0)

  label("Note (optional):", 20, -214)
  f.count = UI.Text(frame, "GameFontDisableSmall")
  f.count:SetPoint("TOPRIGHT", -20, -216)
  f.note = input(WIDTH - 48)
  f.note:SetMaxBytes(NOTE_MAX + 1) -- bytes + terminator, matching Validate and the counter
  f.note:SetPoint("TOPLEFT", 24, -232)
  on(f.note, "OnTextChanged", function(self)
    f.count:SetText(string.format("%d/%d", #(self:GetText() or ""), NOTE_MAX))
  end)

  label("Run needs (optional):", 20, -264)
  f.slot = CreateFrame("Button", nil, frame)
  f.slot:SetSize(32, 32)
  f.slot:SetPoint("TOPLEFT", 20, -282)
  f.slot:RegisterForClicks("LeftButtonUp")
  f.icon = f.slot:CreateTexture(nil, "ARTWORK")
  f.icon:SetAllPoints(f.slot)
  on(f.slot, "OnReceiveDrag", takeCursor)
  on(f.slot, "OnClick", takeCursor)
  on(f.slot, "OnEnter", function(self)
    if not (f.wantLink and GameTooltip) then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(f.wantLink)
    GameTooltip:Show()
  end)
  on(f.slot, "OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
  f.wantName = input(240)
  f.wantName:SetMaxBytes(65) -- 64 bytes + terminator, matching Validate
  f.wantName:SetPoint("TOPLEFT", 64, -288)
  on(f.wantName, "OnTextChanged", function() showWant() end)
  local wantHint = label("Shows as a link that searches the Exchange.", 64, -310, "GameFontDisableSmall")
  wantHint:SetWidth(WIDTH - 84)

  f.remind = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  f.remind:SetSize(24, 24)
  f.remind:SetPoint("TOPLEFT", 16, -330)
  local rt = UI.Text(f.remind, "GameFontHighlight", "Remind signups 15 min before")
  rt:SetPoint("LEFT", f.remind, "RIGHT", 4, 0)

  f.preview = UI.Text(frame, "GameFontHighlightSmall")
  f.preview:SetPoint("TOPLEFT", 20, -364)
  f.preview:SetWidth(WIDTH - 40)
  f.preview:SetJustifyH("LEFT")

  f.error = UI.Text(frame, "GameFontNormalSmall")
  f.error:SetPoint("TOPLEFT", 20, -392)
  f.error:SetWidth(WIDTH - 40)
  f.error:SetJustifyH("LEFT")
  f.error:SetTextColor(1, 0.35, 0.35)

  f.submit = UI.Button(frame, "Post", 100, submit)
  f.submit:SetPoint("BOTTOMRIGHT", -16, 14)
  local cancel = UI.Button(frame, "Cancel", 90, function() frame:Hide() end)
  cancel:SetPoint("RIGHT", f.submit, "LEFT", -8, 0)

  on(frame, "OnHide", function()
    if UI.ClosePickList then UI.ClosePickList() end
    for _, e in ipairs({ f.time, f.note, f.wantName, f.need.t, f.need.h, f.need.d }) do e:ClearFocus() end
  end)
end

-- The first of your usual roles (Settings), tank first; DPS when none.
local function usualRole()
  local D = ns.Groups.Details
  local roles = D and D.PersonalRoles and D.PersonalRoles() or {}
  for _, r in ipairs(ROLES) do if roles[r] then return r end end
  return "d"
end

-- Opens a fresh form. prefill = { instance = key?, role = "t"|"h"|"d"? }.
function Form.Open(prefill)
  prefill = type(prefill) == "table" and prefill or {}
  build()
  Form.ListenLinks(onLink)
  f.instance, f.wantLink = nil, nil
  f.role = (prefill.role == "t" or prefill.role == "h" or prefill.role == "d") and prefill.role or usualRole()
  for _, r in ipairs(ROLES) do
    f.roles[r]:SetChecked(r == f.role)
    f.need[r]:SetText("")
  end
  f.time:SetText("")
  f.note:SetText("")
  f.count:SetText(string.format("0/%d", NOTE_MAX))
  setWantLink(nil)
  f.remind:SetChecked(true)
  setDay(0)
  setWhen("now")
  setRun(prefill.instance)
  setError(nil)
  frame:ClearAllPoints()
  frame:SetPoint("CENTER")
  frame:Show()
end

function Form.IsShown() return frame ~= nil and frame:IsShown() end

function Form.Hide() if frame then frame:Hide() end end
