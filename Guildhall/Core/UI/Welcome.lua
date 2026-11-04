local ADDON, ns = ...

-- Welcome screen and About tab. Both build their content with UI.AboutContent, so they can't
-- drift apart. Shows on the first open of the window on an account, and again when a version
-- with a "What's new" entry arrives. Saved as personal.welcome = { seen = "<last version seen>" }.
-- Named global: "GuildhallWelcomeFrame" (so Esc closes it via UISpecialFrames).
-- Only plain ASCII (plus the middle dot and multiplication sign) in any text here.
local UI = ns.UI
local Welcome = {}
UI.Welcome = Welcome

local WIDTH = 440
local CREDIT = "Made by Dor, a real-life senior software developer. Built with Claude, reviewed by a human."
local GNOME = "No gnomes were harmed during the creation of this add-on. I mean, no more than %d or %d so almost none."

-- The installed version, from the TOC; falls back to the newest WhatsNew entry.
function Welcome.Version()
  local getter = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  if type(getter) == "function" then
    local ok, v = pcall(getter, "Guildhall", "Version")
    if ok and type(v) == "string" and v ~= "" then return v end
  end
  local newest = ns.WhatsNew.ENTRIES[1]
  return newest and newest.version or "0.0.0"
end

-- Module sections: every module's def.about plus the core ones (ns.CoreAbout), by def.about.order.
local function sections()
  local list = {}
  for _, s in ipairs(ns.CoreAbout or {}) do list[#list + 1] = s end
  for _, name in ipairs(ns.Modules()) do
    local def = ns.GetModule(name)
    if type(def) == "table" and type(def.about) == "table" then list[#list + 1] = def.about end
  end
  for i, s in ipairs(list) do s._i = i end
  table.sort(list, function(a, b)
    local oa, ob = a.order or 100, b.order or 100
    if oa ~= ob then return oa < ob end
    return a._i < b._i
  end)
  return list
end

-- Builds the shared content inside a new frame under `parent`.
-- opts.news: array of WhatsNew entries to show under "What's new" (highlighted, at the top).
-- opts.allNews: true lists every WhatsNew entry, newest first, as a history instead.
-- Sets the returned frame's height to fit the text.
function UI.AboutContent(parent, opts)
  opts = opts or {}
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetWidth(WIDTH)
  local version = Welcome.Version()
  local height = 0
  local prev

  local function put(fs, gap)
    if prev then fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -(gap or 6)) else fs:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0) end
    fs:SetWidth(WIDTH)
    height = height + (prev and (gap or 6) or 0) + (fs:GetStringHeight() or 14)
    prev = fs
  end
  local function text(font, str, gap, color)
    local fs = UI.Text(frame, font, str)
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    put(fs, gap)
    return fs
  end

  -- Header: logo, then tabard and guild name when in a guild, then the version.
  local guild = ns.compat and ns.compat.GuildName and ns.compat:GuildName()
  local logo = frame:CreateTexture(nil, "ARTWORK")
  logo:SetTexture(UI.LOGO)
  logo:SetSize(48, 48)
  logo:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  local left = 56
  if guild and UI.Tabard then
    local tabard = UI.Tabard(frame, 48)
    tabard:SetPoint("TOPLEFT", frame, "TOPLEFT", 56, 0)
    if UI.ApplyTabard(tabard) then left = 112 end
  end
  local title = UI.Text(frame, "GameFontNormalLarge", (guild and (ns.Util.Escape(guild) .. "  ") or "") .. "Guildhall")
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -4)
  local accent = ns.Theme and ns.Theme.Get and ns.Theme.Get("accent")
  if accent then title:SetTextColor(accent[1], accent[2], accent[3]) end
  local ver = UI.Text(frame, "GameFontHighlight", "Version " .. version)
  ver:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -28)
  height = 56
  -- Anchor point for the stacked text: a spacer under the header.
  prev = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  prev:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -56)
  prev:SetText(" ")

  -- What's new.
  local news = opts.news
  if opts.allNews then
    news = {}
    for _, e in ipairs(ns.WhatsNew.ENTRIES) do news[#news + 1] = e end
    table.sort(news, function(a, b) return ns.WhatsNew.Compare(a.version, b.version) > 0 end)
  end
  if news and #news > 0 then
    text("GameFontNormalLarge", "What's new", 10, { 1, 0.82, 0 })
    for _, e in ipairs(news) do
      text("GameFontNormal", "In " .. e.version, 8, { 1, 0.82, 0 })
      if #e.lines == 0 then
        text("GameFontDisable", "  (small fixes)", 2)
      else
        for _, line in ipairs(e.lines) do text("GameFontHighlight", "  · " .. line, 2) end
      end
    end
  end

  -- What Guildhall does.
  text("GameFontNormalLarge", "What Guildhall does", 14)
  for _, s in ipairs(sections()) do
    text("GameFontNormal", s.title or "", 8)
    for _, line in ipairs(s.lines or {}) do text("GameFontHighlight", line, 2) end
  end

  local lo, hi = ns.WhatsNew.Gnomes(version)
  text("GameFontDisable", string.format(GNOME, lo, hi), 16)
  text("GameFontDisable", CREDIT, 6)

  frame:SetHeight(height + 14)
  return frame
end

-- Welcome window ----------------------------------------------------------------

local panel -- { frame, scroll, content, check }

local function state()
  local p = UI.Personal()
  if not p then return nil end
  if type(p.welcome) ~= "table" then p.welcome = {} end
  return p.welcome
end

local function build()
  if panel then return end
  local f = UI.CreatePanel("GuildhallWelcomeFrame", WIDTH + 70, 520, "Welcome to Guildhall")
  if UISpecialFrames then table.insert(UISpecialFrames, "GuildhallWelcomeFrame") end
  local scroll = CreateFrame("ScrollFrame", "GuildhallWelcomeScroll", f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -44)
  scroll:SetPoint("BOTTOMRIGHT", -34, 44)
  local close = UI.Button(f, "Close", 90, function() Welcome:Hide() end)
  close:SetPoint("BOTTOMRIGHT", -14, 12)
  local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  check:SetPoint("BOTTOMLEFT", 12, 12)
  local label = UI.Text(f, "GameFontHighlightSmall", "Show this next time")
  label:SetPoint("LEFT", check, "RIGHT", 2, 0)
  check:SetScript("OnClick", function(self)
    UI.Try(function() Welcome:SetShowNext(self:GetChecked() and true or false) end)
  end)
  panel = { frame = f, scroll = scroll, check = check }
  Welcome.check = check
end

local function present(news)
  build()
  -- One content tree per distinct set of news versions; reopening reuses it.
  local ids = {}
  for _, e in ipairs(news) do ids[#ids + 1] = e.version end
  local sig = table.concat(ids, ",")
  panel.cache = panel.cache or {}
  if panel.content then panel.content:Hide() end
  local content = panel.cache[sig]
  if not content then
    content = UI.AboutContent(panel.scroll, { news = news })
    panel.cache[sig] = content
  end
  content:Show()
  panel.content = content
  panel.scroll:SetScrollChild(content)
  local s = state()
  panel.check:SetChecked(not (s and s.seen))
  panel.frame:Show()
end

-- Opens the screen with no "What's new" (a manual reopen; the About tab has the history).
-- Does not change the seen flag.
function Welcome:Show()
  present({}) -- leaves the seen flag alone, so a checked "Show this next time" stays checked
end

-- A true value means: show this screen again next time the window opens (clears the seen flag).
function Welcome:SetShowNext(on)
  local s = state()
  if not s then return end
  s.seen = (not on) and Welcome.Version() or nil
end

function Welcome:Hide()
  if panel then panel.frame:Hide() end
end

function Welcome:IsShown()
  return panel ~= nil and panel.frame:IsShown() == true
end

-- Called when the main window opens: first open on the account, or news the player hasn't seen.
function Welcome:MaybeShow()
  local s = state()
  if not s then return end
  local version = Welcome.Version()
  if s.seen == nil then
    s.seen = version
    present({})
    return
  end
  local news = ns.WhatsNew.Unseen(s.seen, version)
  if ns.WhatsNew.Compare(version, s.seen) > 0 then s.seen = version end
  if #news > 0 then present(news) end
end

-- About tab: the same content with every WhatsNew entry, plus a button to open the welcome screen.
function Welcome.BuildAbout(parent)
  local scroll = CreateFrame("ScrollFrame", "GuildhallAboutScroll", parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 4, -34)
  scroll:SetPoint("BOTTOMRIGHT", -26, 4)
  local content = UI.AboutContent(scroll, { allNews = true })
  scroll:SetScrollChild(content)
  local b = UI.Button(parent, "Show welcome screen", 160, function() Welcome:Show() end)
  b:SetPoint("TOPLEFT", 4, -4)
  return {}
end
