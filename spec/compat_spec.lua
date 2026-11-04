describe("Compat", function()
  local fakes = require("spec.helpers.fakes")
  local Compat

  before_each(function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Compat.lua")
    Compat = ns.Compat
  end)

  local function sendEnv(result, extra)
    local env = { sent = 0 }
    env.C_ChatInfo = { SendAddonMessage = function() env.sent = env.sent + 1; return result end }
    env.Enum = { SendAddonMessageResult = { Success = 0 } }
    for k, v in pairs(extra or {}) do env[k] = v end
    return env
  end

  it("loads and creates ns.compat without WoW APIs", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Compat.lua")
    assert.is_table(ns.compat)
  end)

  it("Safe hides secret/inaccessible values and passes through when APIs are absent", function()
    local c = Compat.new({ issecretvalue = function(v) return v == "s" end })
    assert.is_nil(c.Safe(c, "s"))
    assert.equal("x", c:Safe("x"))
    local c2 = Compat.new({ canaccessvalue = function(v) return v ~= "n" end })
    assert.is_nil(c2:Safe("n"))
    assert.equal("x", Compat.new({}):Safe("x"))
  end)

  it("IsRestricted is false without C_RestrictedActions, true when active", function()
    assert.is_false(Compat.new({}):IsRestricted("Chat"))
    local state = 0
    local env = {
      Enum = { AddOnRestrictionType = { Chat = 5 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function(t) assert.equal(5, t); return state end },
    }
    local c = Compat.new(env)
    assert.is_false(c:IsRestricted("Chat"))
    state = 1; assert.is_true(c:IsRestricted("Chat"))
    state = 2; assert.is_true(c:IsRestricted("Chat"))
  end)

  it("SendAddon maps results", function()
    assert.equal("ok", Compat.new(sendEnv(0)):SendAddon("P", "m"))
    assert.equal("ok", Compat.new(sendEnv(true)):SendAddon("P", "m"))
    assert.equal("lockdown", Compat.new(sendEnv(11)):SendAddon("P", "m"))
    assert.equal("throttle", Compat.new(sendEnv(3)):SendAddon("P", "m"))
    assert.equal("throttle", Compat.new(sendEnv(8)):SendAddon("P", "m"))
    assert.equal("error", Compat.new(sendEnv(2)):SendAddon("P", "m"))
    assert.equal("error", Compat.new(sendEnv(false)):SendAddon("P", "m"))
  end)

  it("SendAddon returns lockdown without calling the API when Chat is restricted", function()
    local env = sendEnv(0, {
      Enum = { AddOnRestrictionType = { Chat = 5 }, SendAddonMessageResult = { Success = 0 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function() return 2 end },
    })
    assert.equal("lockdown", Compat.new(env):SendAddon("P", "m"))
    assert.equal(0, env.sent)
  end)

  it("RegisterPrefix, Now, IsTrial", function()
    local got
    local c = Compat.new({
      C_ChatInfo = { RegisterAddonMessagePrefix = function(p) got = p end },
      GetServerTime = function() return 42 end,
      IsVeteranTrialAccount = function() return true end,
    })
    c:RegisterPrefix("GH")
    assert.equal("GH", got)
    assert.equal(42, c:Now())
    assert.is_true(c:IsTrial())
    assert.is_false(Compat.new({}):IsTrial())
  end)

  it("GuildKey is nil when not in a guild or secret, else full name", function()
    assert.is_nil(Compat.new({ GetGuildInfo = function() return nil end }):GuildKey())
    assert.is_nil(Compat.new({}):GuildKey())
    local env = {
      GetGuildInfo = function() return "Emergence", "Rank", 1, "Argent Dawn" end,
      GetNormalizedRealmName = function() return "Home" end,
    }
    assert.equal("Emergence-ArgentDawn", Compat.new(env):GuildKey())
    env.GetGuildInfo = function() return "Emergence" end
    assert.equal("Emergence-Home", Compat.new(env):GuildKey())
    env.issecretvalue = function() return true end
    assert.is_nil(Compat.new(env):GuildKey())
  end)

  it("PlayerFullName", function()
    local env = { UnitName = function() return "Thalwyn" end, GetNormalizedRealmName = function() return "ArgentDawn" end }
    assert.equal("Thalwyn-ArgentDawn", Compat.new(env):PlayerFullName())
  end)

  it("OpenChat prefers ChatFrameUtil.OpenChat, falls back to ChatFrame_OpenChat", function()
    local a, b
    Compat.new({ ChatFrameUtil = { OpenChat = function(t) a = t end }, ChatFrame_OpenChat = function(t) b = t end }):OpenChat("/w X hi")
    assert.equal("/w X hi", a); assert.is_nil(b)
    Compat.new({ ChatFrame_OpenChat = function(t) b = t end }):OpenChat("/w Y")
    assert.equal("/w Y", b)
    assert.has_no.errors(function() Compat.new({}):OpenChat("x") end)
  end)

  it("mailbox flag", function()
    local c = Compat.new({})
    assert.is_false(c:MailboxOpen())
    c:SetMailboxOpen(true); assert.is_true(c:MailboxOpen())
    c:SetMailboxOpen(false); assert.is_false(c:MailboxOpen())
  end)

  it("FillSendMail fills the fields, never sends", function()
    local function box() local b = {}; function b:SetText(t) self.text = t end; return b end
    local env
    env = {
      MailFrameTab_OnClick = function(_, tab) env.tab = tab end,
      SendMailNameEditBox = box(), SendMailSubjectEditBox = box(), SendMailBodyEditBox = box(),
      SendMail = function() error("must not send") end,
    }
    assert.is_true(Compat.new(env):FillSendMail("Bob-Realm", "Subj", "Body"))
    assert.equal(2, env.tab)
    assert.equal("Bob-Realm", env.SendMailNameEditBox.text)
    assert.equal("Subj", env.SendMailSubjectEditBox.text)
    assert.equal("Body", env.SendMailBodyEditBox.text)
  end)

  it("FillSendMail returns false when a frame is missing", function()
    local function box() local b = {}; function b:SetText(t) self.text = t end; return b end
    local env = { MailFrameTab_OnClick = function() end, SendMailNameEditBox = box(), SendMailSubjectEditBox = box() }
    assert.is_false(Compat.new(env):FillSendMail("a", "b", "c"))
    assert.is_false(Compat.new({}):FillSendMail("a", "b", "c"))
  end)

  it("fakes.compat returns a real Compat over a fake env", function()
    local c, env = fakes.compat({ GetServerTime = function() return 7 end })
    assert.equal(7, c:Now())
    assert.equal(0, env.sent)
  end)
end)
