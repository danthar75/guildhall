-- Exchange board additions: the Record a deal panel and the prompt line, under fake frames.
describe("Exchange board deal UI", function()
  local fakes = require("spec.helpers.fakes")
  local ns, W, Board, Details, buttons, texts, picked, errors, recorded, recordResult
  local pending, soldQueue, removed, declined, confirmed, profiles, me
  local GLOBALS = { "CreateFrame", "UISpecialFrames", "GetItemInfoInstant" }
  local saved = {}
  local LINK = "|cffffffff|Hitem:2589::::::::60:::::|h[Runecloth]|h|r"

  local function listing(by, kind)
    return { id = by .. ":1", by = by, char = by .. "-Realm", t = 100, exp = 999999,
      d = { kind = kind or "WTS", item = LINK, qty = 40, mats = false, cod = false } }
  end

  before_each(function()
    for _, k in ipairs(GLOBALS) do saved[k] = _G[k] end
    W = fakes.widgets()
    _G.CreateFrame = W.CreateFrame
    _G.UISpecialFrames = nil
    buttons, texts, errors, recorded, picked = {}, {}, {}, nil, nil
    recordResult, pending, soldQueue, removed, declined, confirmed = { true }, {}, {}, {}, {}, {}
    me = "pMe"
    profiles = {
      { id = "pMe", exp = 9e9 }, { id = "pZed", exp = 9e9 }, { id = "pBrakka", exp = 9e9 },
      { id = "pGone", exp = 9e9, del = true }, { id = "pOld", exp = 5 }, { id = "pHidden", exp = 9e9 },
    }
    ns = {}
    loadAddonFile(ns, "Guildhall/Core/Util.lua")
    ns.OnError = function(e) errors[#errors + 1] = e end
    ns.UI = {
      BACKDROP_TEMPLATE = nil,
      ApplyBackdrop = function() end,
      ItemIcon = function() end,
      ItemTooltip = function() end,
      Try = function(fn, ...)
        local ok, res = pcall(fn, ...)
        if not ok then ns.OnError(res); return nil end
        return res
      end,
      Text = function(_, _, text) local t = W.new("FontString"); t.text = text; texts[#texts + 1] = t; return t end,
      Button = function(_, text, _, onClick)
        local b = W.new("Button"); b.onClick = onClick; buttons[text] = b; b.text = text; return b
      end,
      CreatePanel = function() local p = W.new("Frame"); return p end,
      PickList = function(anchor, items, onPick, current) picked = { items = items, onPick = onPick } end,
    }
    local names = { pZed = "Zed", pBrakka = "Brakka", pHidden = "Hidden", pMe = "Dor", pOld = "Old", pGone = "Gone" }
    ns.LbConfig = { _displayName = function(_, id) return names[id] or id end }
    ns.Exchange = { Form = { HandleError = function(e) return "ERR " .. tostring(e) end } }
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Category.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/Listing.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/UI/Board.lua")
    loadAddonFile(ns, "Guildhall/Modules/Exchange/UI/Details.lua")
    Board, Details = ns.Exchange.Board, ns.Exchange.BoardDetails
    ns.services = {
      now = function() return 1000 end, playerChar = "Dor-Realm",
      roster = { IsOfficer = function() return false end },
      profile = {
        Id = function() return me end,
        IsMine = function(_, id) return id == me end,
        CharsOf = function() return {} end,
        set = { List = function() return profiles end },
      },
    }
    local mine = listing("pMe")
    ns.exchange = {
      Get = function(_, id) return id == mine.id and mine or nil end,
      List = function() return { mine } end,
      Status = function() return "online", "Dor-Realm" end,
      Contact = function() end,
      _isImported = function() return false end,
      RecordDeal = function(_, ...) recorded = { ... }; return recordResult[1], recordResult[2] end,
      PendingConfirmations = function() return pending end,
      NextSoldPrompt = function() return table.remove(soldQueue, 1) end,
      ConfirmDeal = function(_, id) confirmed[#confirmed + 1] = id; return true end,
      DeclineDeal = function(_, id) declined[#declined + 1] = id; return true end,
      Remove = function(_, id) removed[#removed + 1] = id; return true end,
    }
  end)

  after_each(function()
    for _, k in ipairs(GLOBALS) do _G[k] = saved[k] end
  end)

  local function box(i) return W.ofKind("EditBox")[i] end
  local function textOf(fs) return fs.text end

  describe("Record a deal", function()
    it("the payload matches the inputs", function()
      Details.OpenRecordDeal(listing("pMe"))
      assert.equal("40", box(1):GetText()) -- quantity starts at the listing's
      picked = nil
      buttons["Choose a player"].onClick()
      picked.onPick("pBrakka", picked.items[1])
      box(1):SetText("25")
      box(2):SetText("1.5")
      buttons["Record"].onClick()
      assert.same({ "pMe:1", "pBrakka", 25, 15000 }, recorded)
      assert.same({}, errors)
    end)

    it("lists other guild profiles by name, hidden ones included", function()
      local items = Details.PartnerItems()
      local labels = {}
      for _, it in ipairs(items) do labels[#labels + 1] = it.label end
      assert.same({ "Brakka", "Hidden", "Zed" }, labels)
      assert.equal("pBrakka", items[1].value)
    end)

    it("on someone else's listing the partner is its owner", function()
      Details.OpenRecordDeal(listing("pBrakka", "LF"))
      box(2):SetText("40")
      buttons["Record"].onClick()
      assert.same({ "pBrakka:1", "pBrakka", 40, 400000 }, recorded)
    end)

    it("bad input shows a message and records nothing", function()
      Details.OpenRecordDeal(listing("pMe"))
      buttons["Record"].onClick()
      assert.is_nil(recorded) -- no partner yet
      picked = nil
      buttons["Choose a player"].onClick()
      picked.onPick("pZed", picked.items[3])
      for _, bad in ipairs({ { "0", "5" }, { "x", "5" }, { "5", "" }, { "5", "-1" }, { "5", "0" } }) do
        box(1):SetText(bad[1]); box(2):SetText(bad[2])
        buttons["Record"].onClick()
        assert.is_nil(recorded)
      end
    end)

    it("an exchange refusal is shown in the panel", function()
      recordResult = { false, "already recorded" }
      Details.OpenRecordDeal(listing("pBrakka"))
      box(2):SetText("5")
      buttons["Record"].onClick()
      local shown
      for _, t in ipairs(texts) do if t.text == "That deal was already recorded." then shown = true end end
      assert.is_true(shown)
    end)
  end)

  describe("prompt line", function()
    local function build()
      local view = Board.Build(W.new("Frame"))
      view.search:SetText("") -- the fake box answers GetText only after a SetText
      view.refresh()
      return view
    end
    local function pend(by, buyer, seller)
      return { obs = { id = "o1", by = by, d = { buyer = buyer, seller = seller, count = 40, copper = 400000, item = 2589 } },
        listing = listing(seller) }
    end

    it("the confirm line appears for the partner only", function()
      -- Brakka recorded: I bought. The exchange lists it for me, not for Brakka.
      pending = { pend("pBrakka", "pMe", "pBrakka") }
      local view = build()
      assert.equal("Brakka says you bought 40 Runecloth for 40g. Confirm?", view.banner.text.text)
      assert.is_true(view.banner.shown)
      assert.equal("Confirm", view.banner.yes.text)
      assert.equal("Not me", view.banner.no.text)
      -- the recorder's own client has nothing pending
      pending = {}
      Board.Refresh()
      assert.is_false(view.banner.shown)
      assert.is_nil(Board.Prompt())
    end)

    it("every listing gets a Record a deal button", function()
      local view = build()
      assert.is_true(view.btn.record.shown)
    end)

    it("Confirm and Not me answer the exchange", function()
      pending = { pend("pBrakka", "pMe", "pBrakka") }
      build()
      Board.AnswerPrompt(true)
      assert.same({ "o1" }, confirmed)
      Board.AnswerPrompt(false)
      assert.same({ "o1" }, declined)
    end)

    it("the sold prompt shows once per deal", function()
      soldQueue = { { ref = "deal:pMe:1:o1", listing = listing("pMe") } }
      local view = build()
      assert.equal("Sold? Runecloth", view.banner.text.text)
      assert.equal("Remove listing", view.banner.yes.text)
      Board.Refresh() -- stays up while unanswered
      assert.is_true(view.banner.shown)
      Board.AnswerPrompt(false) -- Keep it up
      assert.is_false(view.banner.shown)
      assert.same({}, removed)
      Board.Refresh()
      assert.is_false(view.banner.shown) -- the exchange offers it no more
    end)

    it("Remove listing uses the normal remove path", function()
      soldQueue = { { ref = "deal:pMe:1:o1", listing = listing("pMe") } }
      build()
      Board.AnswerPrompt(true)
      assert.same({ "pMe:1" }, removed)
    end)

    it("a confirmation outranks the sold question", function()
      pending = { pend("pBrakka", "pMe", "pBrakka") }
      soldQueue = { { ref = "r", listing = listing("pMe") } }
      local view = build()
      assert.is_truthy(view.banner.text.text:find("Confirm?", 1, true))
    end)
  end)
end)
