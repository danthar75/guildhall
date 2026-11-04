describe("Roster", function()
  local fakes = require("spec.helpers.fakes")
  local Roster

  local function make(rows, overrides, cache)
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    loadAddonFile(ns, "Guildhall/Core/Compat.lua")
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    Roster = ns.Roster
    local e = {
      UnitName = function() return "Me" end,
      GetNormalizedRealmName = function() return "Realm" end,
      GetNumGuildMembers = function() return #rows end,
      GetGuildRosterInfo = function(i)
        local r = rows[i]
        return r.name, "Rank", r.rank, 80, "Mage", "Zone", "", "", r.online
      end,
      C_GuildInfo = { GetInfoText = function() return "Hello [Guildhall officers=3]" end, GuildRoster = function() end },
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    local c = fakes.compat(e)
    cache = cache or {}
    return Roster.new(c, cache), cache
  end

  it("ParseTag reads officers=3", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    local r = ns.Roster.ParseTag("x [Guildhall officers=3 mode=fast] y")
    assert.equal(3, r.officers)
    assert.equal("fast", r.mode)
  end)

  it("ParseTag tolerates spaces after commas", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    local r = ns.Roster.ParseTag("[Guildhall donations=3, 4 bankexclude=0 ,1 officers=2]")
    assert.equal("3,4", r.donations)
    assert.equal("0,1", r.bankexclude)
    assert.equal(2, r.officers)
  end)

  it("ParseTag keeps settings separated by a comma", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    local r = ns.Roster.ParseTag("[Guildhall donations=3,4, officers=2]")
    assert.equal("3,4", r.donations)
    assert.equal(2, r.officers)
    local r2 = ns.Roster.ParseTag("[Guildhall officers=2, mode=fast]")
    assert.equal(2, r2.officers)
    assert.equal("fast", r2.mode)
    assert.equal("3,4", ns.Roster.ParseTag("[Guildhall donations=3, 4]").donations)
  end)

  it("ParseTag ignores text without tag", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    assert.same({}, ns.Roster.ParseTag("no tag here"))
    assert.same({}, ns.Roster.ParseTag("[guildhall officers=3]"))
    assert.same({}, ns.Roster.ParseTag(nil))
    assert.same({}, ns.Roster.ParseTag(42))
  end)

  it("ParseTag merges two tags; ConfigList parses lists", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    local text = "[Guildhall officers=3] notes [Guildhall donations=3,4 bankexclude=0]"
    local t = ns.Roster.ParseTag(text)
    assert.equal(3, t.officers)
    assert.equal("3,4", t.donations)
    local r = make({}, { C_GuildInfo = { GetInfoText = function() return text end, GuildRoster = function() end } })
    r:Refresh()
    assert.same({ 3, 4 }, r:ConfigList("donations"))
    assert.same({ 0 }, r:ConfigList("bankexclude"))
    assert.same({ 3 }, r:ConfigList("officers"))
    assert.same({}, r:ConfigList("nope"))
  end)

  it("IsOfficer uses threshold rank < N", function()
    local r = make({
      { name = "Boss-Realm", rank = 0, online = true },
      { name = "Off-Realm", rank = 2, online = true },
      { name = "Grunt-Realm", rank = 3, online = false },
    })
    r:Refresh()
    assert.equal(3, r:OfficerThreshold())
    assert.is_true(r:IsOfficer("Boss-Realm"))
    assert.is_true(r:IsOfficer("Off-Realm"))
    assert.is_false(r:IsOfficer("Grunt-Realm"))
    assert.is_false(r:IsOnline("Grunt-Realm"))
    assert.is_true(r:IsOnline("Boss"))
  end)

  it("defaults threshold to 2 and normalizes non-ASCII names", function()
    local r = make({ { name = "Thálwyn-Realm", rank = 1, online = true } },
      { C_GuildInfo = { GetInfoText = function() return "" end } })
    r:Refresh()
    assert.equal(2, r:OfficerThreshold())
    assert.equal(1, r:RankIndex("Thálwyn"))
    assert.is_true(r:IsOfficer("Thálwyn-Realm"))
  end)

  it("roster returns nil for secret values", function()
    local r = make({ { name = "A-Realm", rank = 1, online = "SECRET" } },
      { issecretvalue = function(v) return v == "SECRET" end })
    assert.has_no.errors(function() r:Refresh() end)
    assert.is_nil(r:IsOnline("A-Realm"))
    assert.equal(1, r:RankIndex("A-Realm"))
  end)

  it("skips a row with a secret name or rank without error", function()
    local r, cache = make({
      { name = "SECRET", rank = 1, online = true },
      { name = "B-Realm", rank = "SECRET", online = true },
      { name = "C-Realm", rank = 1, online = true },
    }, { issecretvalue = function(v) return v == "SECRET" end })
    assert.has_no.errors(function() r:Refresh() end)
    assert.is_nil(r:RankIndex("B-Realm"))
    assert.is_nil(r:IsOnline("B-Realm"))
    assert.is_true(r:IsOnline("C-Realm"))
    assert.same({ ["C-Realm"] = 1 }, cache.ranks)
  end)

  it("keeps cached guild config when restricted", function()
    local cache = { guildConfig = { officers = 5 }, ranks = { ["Old-Realm"] = 5 } }
    local r = make({}, {
      Enum = { AddOnRestrictionType = { Map = 7 } },
      C_RestrictedActions = { GetAddOnRestrictionState = function() return 2 end },
      GetNumGuildMembers = function() return 0 end,
    }, cache)
    r:Refresh()
    assert.equal(5, r:OfficerThreshold())
    assert.equal(5, r:RankIndex("Old-Realm"))
    assert.is_false(r:IsOfficer("Old-Realm"))
  end)

  it("unknown member returns nil", function()
    local r = make({ { name = "A-Realm", rank = 0, online = true } })
    r:Refresh()
    assert.is_nil(r:IsOnline("Nobody-Realm"))
    assert.is_nil(r:RankIndex("Nobody"))
    assert.is_nil(r:IsOfficer("Nobody"))
  end)
  it("HasRanks is false until a roster with rows has been read", function()
    local r = make({})
    r:Refresh()
    assert.is_false(r:HasRanks())
    local r2 = make({ { name = "Bob", rank = 1, online = true } })
    assert.is_false(r2:HasRanks())
    r2:Refresh()
    assert.is_true(r2:HasRanks())
  end)

  it("RankNames reads the game's ranks and caches them", function()
    local live = { "Guild Master", "Officer", "Member" }
    local r, cache = make({}, { GuildControlGetNumRanks = function() return #live end,
      GuildControlGetRankName = function(i) return live[i] end })
    assert.same({ "Guild Master", "Officer", "Member" }, r:RankNames())
    live = {} -- the game stops answering (secret or not loaded): the cache answers
    assert.same({ "Guild Master", "Officer", "Member" }, r:RankNames())
    assert.equal("Officer", cache.rankNames[1])
  end)

  it("RankNames falls back to rank names seen in the roster, with Rank N for a gap", function()
    local r = make({ { name = "A", rank = 0 }, { name = "B", rank = 2 } })
    assert.same({}, r:RankNames())
    r:Refresh()
    assert.same({ "Rank", "Rank 1", "Rank" }, r:RankNames())
  end)
end)
