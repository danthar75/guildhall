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

  it("ParseTag ignores text without tag", function()
    local ns = {}
    loadAddonFile(ns, "Guildhall/Core/Roster.lua")
    assert.same({}, ns.Roster.ParseTag("no tag here"))
    assert.same({}, ns.Roster.ParseTag("[guildhall officers=3]"))
    assert.same({}, ns.Roster.ParseTag(nil))
    assert.same({}, ns.Roster.ParseTag(42))
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
end)
