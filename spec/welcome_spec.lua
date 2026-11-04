-- Welcome screen and About tab: WhatsNew data, when the screen shows, and the shared content.
-- Only bytes below 0x80, plus the exact sequences for U+00B7 and U+00D7.
local function isAllowed(s)
  s = s:gsub("\194\183", ""):gsub("\195\151", "")
  return not s:find("[\128-\255]")
end

describe("WhatsNew", function()
  local ns
  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/WhatsNew.lua")
  end)

  it("compares versions numerically by dotted parts", function()
    local C = ns.WhatsNew.Compare
    assert.equal(1, C("0.10.0", "0.9.9"))
    assert.equal(-1, C("0.9.9", "0.10.0"))
    assert.equal(0, C("1.2", "1.2.0"))
    assert.equal(-1, C("0.1.0", "0.2.0"))
  end)

  it("has an entry for the first release with the group finder lines", function()
    local first = ns.WhatsNew.ENTRIES[#ns.WhatsNew.ENTRIES]
    assert.equal("0.1.0", first.version)
    assert.equal(3, #first.lines)
  end)

  it("keeps entries newest first", function()
    local e = ns.WhatsNew.ENTRIES
    for i = 1, #e - 1 do assert.equal(1, ns.WhatsNew.Compare(e[i].version, e[i + 1].version)) end
  end)

  describe("gnomes", function()
    local saved
    before_each(function() saved = ns.WhatsNew.ENTRIES end)
    after_each(function() ns.WhatsNew.ENTRIES = saved end)

    it("0.1.0 reads 10 and 20", function()
      local lo, hi = ns.WhatsNew.Gnomes("0.1.0")
      assert.equal(10, lo); assert.equal(20, hi)
    end)
    it("creeps up with each release", function()
      ns.WhatsNew.ENTRIES = { { version = "0.3.0", lines = {} }, { version = "0.2.0", lines = {} }, { version = "0.1.0", lines = {} } }
      local lo, hi = ns.WhatsNew.Gnomes("0.2.0")
      assert.equal(12, lo); assert.equal(23, hi)
      lo, hi = ns.WhatsNew.Gnomes("0.3.0")
      assert.equal(14, lo); assert.equal(26, hi)
    end)
    it("an override wins", function()
      ns.WhatsNew.ENTRIES = { { version = "0.2.0", lines = {}, gnomes = { 1, 2 } }, { version = "0.1.0", lines = {} } }
      local lo, hi = ns.WhatsNew.Gnomes("0.2.0")
      assert.equal(1, lo); assert.equal(2, hi)
    end)
  end)

  describe("Unseen", function()
    local saved
    before_each(function()
      saved = ns.WhatsNew.ENTRIES
      ns.WhatsNew.ENTRIES = {
        { version = "0.4.0", lines = {} },
        { version = "0.3.0", lines = { "c" } },
        { version = "0.2.0", lines = { "b" } },
        { version = "0.1.0", lines = {} },
      }
    end)
    after_each(function() ns.WhatsNew.ENTRIES = saved end)

    it("lists newer entries with lines, newest first", function()
      local u = ns.WhatsNew.Unseen("0.1.0", "0.4.0")
      assert.equal(2, #u)
      assert.equal("0.3.0", u[1].version)
      assert.equal("0.2.0", u[2].version)
    end)
    it("skips entries at or below the last seen and above the current", function()
      local u = ns.WhatsNew.Unseen("0.2.0", "0.3.0")
      assert.equal(1, #u)
      assert.equal("0.3.0", u[1].version)
    end)
    it("is empty when only empty entries are new", function()
      assert.same({}, ns.WhatsNew.Unseen("0.3.0", "0.4.0"))
    end)
  end)

  it("WhatsNew lines are ASCII (plus middle dot and multiplication sign)", function()
    for _, e in ipairs(ns.WhatsNew.ENTRIES) do
      for _, l in ipairs(e.lines) do assert.is_true(isAllowed(l), l) end
    end
  end)
end)

describe("Welcome", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, personal, version, errors
  local GLOBALS = { "CreateFrame", "UIParent", "UISpecialFrames", "GuildhallDB", "GetAddOnMetadata" }
  local saved = {}

  local function allText()
    local out = {}
    for _, t in ipairs(ns.texts) do out[#out + 1] = tostring(t.text) end
    return table.concat(out, "\n")
  end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    _G.UIParent = W.new("Frame")
    _G.UISpecialFrames = {}
    version = "0.1.0"
    _G.GetAddOnMetadata = function() return version end
    personal = {}
    _G.GuildhallDB = { personal = personal }
    errors = {}
    ns = { texts = {} }
    ns.OnError = function(e) errors[#errors + 1] = e end
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/WhatsNew.lua")
    ns.UI = {
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Personal = function() return personal end,
      Text = function(_, _, text)
        local t = W.new("FontString"); t.text = text; ns.texts[#ns.texts + 1] = t; return t
      end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; b.label = text; return b
      end,
      CreatePanel = function(name, w, h, title)
        local f = W.new("Frame"); f.name = name; f.title = title; return f
      end,
      Tabard = function() return W.new("Frame") end,
      ApplyTabard = function() return false end,
      LOGO = "logo",
    }
    ns.Modules = function() return { "Exchange", "Leaderboard" } end
    local defs = {
      Exchange = { about = { title = "Exchange", order = 10, lines = { "Post what you want." } } },
      Leaderboard = { about = { title = "Leaderboard", order = 30, lines = { "Gold kept." } } },
    }
    ns.GetModule = function(n) return defs[n] end
    ns.CoreAbout = { { title = "Linked characters", order = 20, lines = { "Reach you anywhere." } } }
    loadAddonFile(ns, "Guildhall/Core/UI/Welcome.lua")
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  it("shows on the first open and not on the second", function()
    ns.UI.Welcome:MaybeShow()
    assert.is_true(ns.UI.Welcome:IsShown())
    assert.equal("0.1.0", personal.welcome.seen)
    ns.UI.Welcome:Hide()
    ns.UI.Welcome:MaybeShow()
    assert.is_false(ns.UI.Welcome:IsShown())
  end)

  it("shows again for a version with lines", function()
    ns.UI.Welcome:MaybeShow()
    ns.UI.Welcome:Hide()
    ns.WhatsNew.ENTRIES = { { version = "0.2.0", lines = { "Shiny new thing" } }, { version = "0.1.0", lines = {} } }
    version = "0.2.0"
    ns.UI.Welcome:MaybeShow()
    assert.is_true(ns.UI.Welcome:IsShown())
    assert.equal("0.2.0", personal.welcome.seen)
    assert.is_truthy(allText():find("In 0.2.0", 1, true))
    assert.is_truthy(allText():find("Shiny new thing", 1, true))
  end)

  it("a version with empty lines does not reopen it, but records the version", function()
    ns.UI.Welcome:MaybeShow()
    ns.UI.Welcome:Hide()
    ns.WhatsNew.ENTRIES = { { version = "0.2.0", lines = {} }, { version = "0.1.0", lines = {} } }
    version = "0.2.0"
    ns.UI.Welcome:MaybeShow()
    assert.is_false(ns.UI.Welcome:IsShown())
    assert.equal("0.2.0", personal.welcome.seen)
  end)

  it("Show always shows, with no news section for a first open", function()
    ns.UI.Welcome:Show()
    assert.is_true(ns.UI.Welcome:IsShown())
    assert.is_nil(allText():find("What's new", 1, true))
  end)

  it("shows the gnome line, the credit and the module lines", function()
    ns.UI.Welcome:Show()
    local text = allText()
    assert.is_truthy(text:find("No gnomes were harmed during the creation of this add-on. I mean, no more than 10 or 20 so almost none.", 1, true))
    assert.is_truthy(text:find("Made by Dor, a real-life senior software developer. Built with Claude, reviewed by a human.", 1, true))
    local ex, linked, lb = text:find("Post what you want.", 1, true), text:find("Reach you anywhere.", 1, true), text:find("Gold kept.", 1, true)
    assert.is_truthy(ex and linked and lb)
    assert.is_true(ex < linked and linked < lb)
  end)

  it("the About content lists every entry, newest first", function()
    ns.WhatsNew.ENTRIES = {
      { version = "0.3.0", lines = { "third" } },
      { version = "0.2.0", lines = { "second" } },
      { version = "0.1.0", lines = {} },
    }
    version = "0.3.0"
    ns.UI.AboutContent(W.new("Frame"), { allNews = true })
    local text = allText()
    local a, b = text:find("In 0.3.0", 1, true), text:find("In 0.2.0", 1, true)
    assert.is_truthy(a and b and a < b)
    assert.is_truthy(text:find("In 0.1.0", 1, true))
    assert.is_truthy(text:find("third", 1, true) and text:find("second", 1, true))
  end)

  it("the show-next-time checkbox clears and restores the seen flag", function()
    ns.UI.Welcome:MaybeShow()
    assert.equal("0.1.0", personal.welcome.seen)
    local check = ns.UI.Welcome.check
    local onClick
    for _, c in ipairs(check.calls.SetScript) do if c[1] == "OnClick" then onClick = c[2] end end
    check.checked = true
    onClick(check)
    assert.is_nil(personal.welcome.seen)
    check.checked = false
    onClick(check)
    assert.equal("0.1.0", personal.welcome.seen)
  end)

  it("a manual reopen keeps a checked show-next-time", function()
    ns.UI.Welcome:MaybeShow()
    ns.UI.Welcome:SetShowNext(true)
    ns.UI.Welcome:Show()
    assert.is_nil(personal.welcome.seen)
    assert.is_true(ns.UI.Welcome.check.checked)
  end)

  it("reopening with the same news builds the content once", function()
    ns.UI.Welcome:Show()
    local n = #W.created
    ns.UI.Welcome:Hide(); ns.UI.Welcome:Show()
    ns.UI.Welcome:Hide(); ns.UI.Welcome:Show()
    assert.equal(n, #W.created)
  end)

  it("shows the beta label and note while ns.BETA is set, and neither once it is off", function()
    -- The real values come from Init.lua; check them there, then render with them.
    local init = {}
    loadAddonFile(init, "Guildhall/Core/Init.lua")
    assert.is_true(init.BETA)
    assert.is_true(isAllowed(init.BETA_NOTE))
    ns.BETA, ns.BETA_NOTE = init.BETA, init.BETA_NOTE
    ns.UI.Welcome:Show()
    local text = allText()
    assert.is_truthy(text:find("(beta)", 1, true))
    assert.is_truthy(text:find(init.BETA_NOTE, 1, true))
  end)

  it("shows no beta label when ns.BETA is off", function()
    ns.BETA, ns.BETA_NOTE = nil, "Should not show"
    ns.UI.Welcome:Show()
    local text = allText()
    assert.is_nil(text:find("(beta)", 1, true))
    assert.is_nil(text:find("Should not show", 1, true))
  end)

  it("welcome and module text is allowed glyphs only", function()
    ns.UI.Welcome:Show()
    for _, t in ipairs(ns.texts) do assert.is_true(isAllowed(tostring(t.text)), tostring(t.text)) end
    for _, s in ipairs(ns.CoreAbout) do for _, l in ipairs(s.lines) do assert.is_true(isAllowed(l), l) end end
  end)

  it("registers for Esc", function()
    ns.UI.Welcome:Show()
    assert.equal("GuildhallWelcomeFrame", _G.UISpecialFrames[#_G.UISpecialFrames])
  end)
end)

describe("release check", function()
  local function run(version)
    local p = io.popen("bash tools/check-release.sh " .. version .. " 2>&1; echo EXIT:$?")
    local out = p:read("*a"); p:close()
    return tonumber(out:match("EXIT:(%d+)")), out
  end
  it("passes for a version with a WhatsNew entry", function()
    assert.equal(0, (run("0.1.0")))
  end)
  it("fails for a version without one", function()
    local code, out = run("9.9.9")
    assert.is_not.equal(0, code)
    assert.is_truthy(out:find("WhatsNew", 1, true))
  end)
  it("the current TOC version has an entry", function()
    local code = run("")
    assert.equal(0, code)
  end)
end)

describe("real about text", function()
  local function isAllowedReal(s)
    s = s:gsub("\194\183", ""):gsub("\195\151", "")
    return not s:find("[\128-\255]")
  end
  local function check(path)
    local f = assert(io.open(path)); local src = f:read("*a"); f:close()
    for str in src:gmatch('"([^"\n]*)"') do assert.is_true(isAllowedReal(str), path .. ": " .. str) end
  end
  it("Init, Exchange, Leaderboard and Welcome sources use allowed glyphs only", function()
    for _, p in ipairs({ "Guildhall/Core/Init.lua", "Guildhall/Core/UI/Welcome.lua", "Guildhall/Core/WhatsNew.lua",
      "Guildhall/Modules/Exchange/Exchange.lua", "Guildhall/Core/Leaderboard/Module.lua" }) do check(p) end
  end)
end)
