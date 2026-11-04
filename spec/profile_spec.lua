describe("Profile", function()
  local fakes = require("spec.helpers.fakes")
  local ns, now, set, store, online, personal

  local function mk(extra)
    local o = {
      personal = personal, set = set, now = function() return now end,
      random = math.random, playerChar = "Me-Realm", defaultRealm = "Realm", guildKey = "GuildA-Realm",
      roster = { IsOnline = function(_, n) return online[n] end },
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return ns.Profile.new(o)
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/DB.lua")
    loadAddonFile(ns, "Guildhall/Core/ReplicatedSet.lua")
    loadAddonFile(ns, "Guildhall/Core/Profile.lua")
    now = 1000
    store, online = {}, {}
    personal = ns.DB.Init().personal
    set = ns.ReplicatedSet.new("profiles", store, { now = function() return now end })
  end)

  local function peer(id, t, chars)
    local rec = { id = id, v = 1, t = t, by = id, exp = now + 5000, d = { chars = chars } }
    assert.equal("accepted", (set:Apply(rec)))
    return rec
  end

  it("Id is stable once generated", function()
    local p = mk()
    local id = p:Id()
    assert.truthy(id:match("^%x%x%x%x%x%x%x%x%x%x%x%x$"))
    assert.equal(id, p:Id())
    assert.equal(id, mk():Id())
  end)

  it("no Record before consent", function()
    local p = mk()
    p:SeeCharacter("Me-Realm")
    assert.is_nil(p:Record())
    assert.is_true(p:NeedsConsent())
  end)

  it("excluded chars are not published", function()
    local p = mk()
    p:SeeCharacter("Me-Realm"); p:SeeCharacter("Alt-Realm"); p:SeeCharacter("Bank-Realm")
    p:Consent({ "Bank-Realm" })
    local r = p:Record()
    assert.same({ "Alt-Realm", "Me-Realm" }, r.d.chars)
    assert.equal(p:Id(), r.id); assert.equal(p:Id(), r.by)
    assert.equal(1, r.v); assert.equal(now + 2592000, r.exp); assert.equal("Me-Realm", r.char)
    assert.is_false(p:NeedsConsent())
    assert.same({ "Bank-Realm" }, personal.profile.excluded)
  end)

  it("no Record while logged in on an excluded character (O1: would reveal the link)", function()
    personal = ns.DB.Init().personal
    local main = mk()
    main:SeeCharacter("Me-Realm"); main:SeeCharacter("Hidden-Realm")
    main:Consent({ "Hidden-Realm" })
    local onHidden = mk({ playerChar = "Hidden-Realm" })
    assert.is_nil(onHidden:Record())
    assert.is_not_nil(main:Record())
  end)

  it("a new alt after consent makes NeedsConsent true again", function()
    local p = mk()
    p:SeeCharacter("Me-Realm"); p:Consent({})
    assert.is_false(p:NeedsConsent())
    p:SeeCharacter("New-Realm")
    assert.is_true(p:NeedsConsent())
    assert.same({ "New-Realm" }, p:PendingChars())
    p:Consent({ "New-Realm" })
    assert.is_false(p:NeedsConsent())
    assert.same({ "Me-Realm" }, p:Record().d.chars)
  end)

  it("OnlineChar picks an online alt", function()
    peer("aaaaaaaaaaaa", 10, { "A-Realm", "B-Realm" })
    online["B-Realm"] = true; online["A-Realm"] = false
    local p = mk()
    assert.equal("B-Realm", p:OnlineChar("aaaaaaaaaaaa"))
    online["B-Realm"] = nil
    assert.is_nil(p:OnlineChar("aaaaaaaaaaaa"))
  end)

  it("OwnerOf resolves conflicting claims by latest t", function()
    peer("aaaaaaaaaaaa", 10, { "X-Realm" })
    peer("bbbbbbbbbbbb", 20, { "X-Realm" })
    local p = mk()
    assert.equal("bbbbbbbbbbbb", p:OwnerOf("X-Realm"))
    assert.is_nil(p:OwnerOf("Nobody-Realm"))
  end)

  it("OwnerOf matches realm-less and realm names via FullName", function()
    peer("aaaaaaaaaaaa", 10, { "X" })
    local p = mk()
    assert.equal("aaaaaaaaaaaa", p:OwnerOf("X-Realm"))
    assert.equal("aaaaaaaaaaaa", p:OwnerOf("X"))
  end)

  it("OwnerOf does not raise on malformed peer records", function()
    peer("aaaaaaaaaaaa", 10, "notatable")
    store["bbbbbbbbbbbb"] = { id = "bbbbbbbbbbbb", v = 1, t = 5, exp = now + 99, d = "str" }
    store["cccccccccccc"] = { id = "cccccccccccc", v = 1, t = 5, exp = now + 99 }
    peer("dddddddddddd", 10, { 5, {}, false, "X-Realm" })
    local p = mk()
    assert.equal("dddddddddddd", p:OwnerOf("X-Realm"))
    assert.same({}, p:CharsOf("aaaaaaaaaaaa"))
    assert.same({ "X-Realm" }, p:CharsOf("dddddddddddd"))
  end)

  it("own chars count offline and IsMine works", function()
    local p = mk()
    p:SeeCharacter("Me-Realm"); p:Consent({})
    assert.equal(p:Id(), p:OwnerOf("Me"))
    assert.is_true(p:IsMine(p:Id()))
    assert.is_false(p:IsMine("zzz"))
    assert.same({ "Me-Realm" }, p:CharsOf(p:Id()))
  end)
  -- I2: characters are scoped to the guild they were seen in.
  it("Record for guild A lists only characters seen in guild A", function()
    local a = mk({ guildKey = "GuildA-Realm", playerChar = "Main-Realm" })
    a:SeeCharacter("Main-Realm"); a:Consent({})
    local b = mk({ guildKey = "GuildB-Realm", playerChar = "Alt-Realm" })
    b:SeeCharacter("Alt-Realm")
    assert.same({ "Alt-Realm" }, b:PendingChars()) -- Main is not asked about in guild B
    b:Consent({})
    assert.same({ "Alt-Realm" }, b:Record().d.chars)
    assert.same({ "Main-Realm" }, a:Record().d.chars)
    assert.same({ "Main-Realm" }, a:GuildChars())
    assert.same({ "Alt-Realm" }, b:GuildChars())
    assert.equal("GuildA-Realm", personal.profile.chars["Main-Realm"].guild)
    assert.equal("GuildB-Realm", personal.profile.chars["Alt-Realm"].guild)
    assert.is_nil(a:OwnerOf("Alt-Realm"))
  end)

  it("legacy entries without a guild key are not shared and are re-asked when next seen", function()
    personal.profile.consented = true
    personal.profile.chars["Old-Realm"] = { included = true }
    personal.profile.chars["Me-Realm"] = { included = true }
    local p = mk()
    assert.is_false(p:NeedsConsent())
    assert.same({}, p:Record().d.chars)
    assert.same({}, p:GuildChars())
    p:SeeCharacter("Me-Realm") -- logged in with this guild: stamped, pending again
    assert.equal("GuildA-Realm", personal.profile.chars["Me-Realm"].guild)
    assert.same({ "Me-Realm" }, p:PendingChars())
    p:Consent({})
    assert.same({ "Me-Realm" }, p:Record().d.chars)
    assert.is_nil(personal.profile.chars["Old-Realm"].guild) -- untouched until it logs in
  end)

  it("a character seen in a different guild moves to it and is re-asked", function()
    local a = mk({ guildKey = "GuildA-Realm" })
    a:SeeCharacter("Me-Realm"); a:Consent({})
    local b = mk({ guildKey = "GuildB-Realm" })
    b:SeeCharacter("Me-Realm")
    assert.same({ "Me-Realm" }, b:PendingChars())
    assert.same({}, a:Record().d.chars)
  end)
  it("IsExcluded reflects this guild's decision only", function()
    local p = mk()
    p:SeeCharacter("Me-Realm"); p:SeeCharacter("Bank-Realm")
    p:Consent({ "Bank-Realm" })
    assert.is_true(p:IsExcluded("Bank-Realm"))
    assert.is_false(p:IsExcluded("Me-Realm"))
    assert.is_false(p:IsExcluded("Nobody-Realm"))
    assert.is_false(mk({ guildKey = "Other-Realm" }):IsExcluded("Bank-Realm"))
  end)
end)
