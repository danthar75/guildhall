describe("Exchange.Format", function()
  local F, ns
  local LINK = "|cff0070dd|Hitem:14152::::::::60:::::|h[Robe of the Archmage]|h|r"
  local function rec(d, char)
    local x = { id = "p1:1", v = 1, t = 1, by = "p1", char = char or "Thalwyn-Realm", exp = 99, del = false,
      d = { kind = "LF", item = LINK, mats = true, cod = true } }
    for k, v in pairs(d or {}) do x.d[k] = v end
    return x
  end

  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Modules/Exchange/Format.lua")
    F = ns.Exchange.Format
  end)

  it("Discord matches pinned format for LF", function()
    local out = F.Discord(rec({ note = "have the cloth, need a tailor. Tipping 20g." }))
    assert.are.equal("LF Robe of the Archmage\nI will provide materials\nI am open to CoD\n"
      .. "Note: have the cloth, need a tailor. Tipping 20g.\n(Thalwyn, in game via Guildhearth)", out)
  end)

  it("Discord WTS with qty and no note", function()
    local out = F.Discord(rec({ kind = "WTS", item = "Runecloth", qty = 40, mats = false, cod = false }))
    assert.are.equal("WTS Runecloth x40", out:match("^[^\n]*"))
    assert.is_nil(out:find("Note:", 1, true))
    assert.is_truthy(out:find("I will not provide materials", 1, true))
    assert.is_truthy(out:find("I am not open to CoD", 1, true))
  end)

  it("Discord leaves out the materials line when it doesn't apply", function()
    local r = rec({ kind = "WTS", item = "Runecloth", qty = 40, cod = true })
    r.d.mats = nil
    local out = F.Discord(r)
    assert.is_nil(out:find("provide materials", 1, true))
    assert.equal("WTS Runecloth x40\nI am open to CoD\n(Thalwyn, in game via Guildhearth)", out)
  end)

  it("Whisper keeps item link", function()
    assert.is_truthy(F.Whisper(rec()):find(LINK, 1, true))
    assert.is_truthy(F.Whisper(rec({ kind = "WTS" })):find("still available", 1, true))
  end)

  it("Mail subject is plain name", function()
    local s, b = F.Mail(rec())
    assert.are.equal("Guildhearth: Robe of the Archmage", s)
    assert.is_nil(b:find("|H", 1, true))
    assert.is_truthy(b:find("Robe of the Archmage", 1, true))
  end)

  it("custom template overrides one key", function()
    local out = F.Whisper(rec(), { whisperLF = "yo {item}" })
    assert.are.equal("yo " .. LINK, out)
    assert.are.equal("Guildhearth: Robe of the Archmage", (F.Mail(rec(), { whisperLF = "x" })))
    assert.are.equal("Guildhearth: Robe of the Archmage", (F.Mail(rec(), { mailSubject = 5 })))
  end)

  it("note with % and {item} appears literally", function()
    local note = "100% sure {item} %1 %s {char}"
    local out = F.Discord(rec({ note = note }))
    assert.is_truthy(out:find("Note: " .. note, 1, true))
    local out2 = F.Discord(rec(), { discord = "{note}" })
    assert.are.equal("{note}", out2)
  end)

  it("char strips realm, falls back to poster for imports, is byte-safe", function()
    assert.are.equal("Thalwyn", F.Vars(rec()).char)
    assert.are.equal("Ünïcode", F.Vars(rec(nil, "Ünïcode-Realm")).char)
    local imp = rec({ src = "discord", poster = "Bob" }, "")
    assert.are.equal("Bob", F.Vars(imp).char)
    local imp2 = rec({ src = "discord", poster = "Bob" }, nil)
    imp2.char = nil
    assert.are.equal("Bob", F.Vars(imp2).char)
  end)
end)
