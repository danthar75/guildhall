describe("Exchange.MailDrafts", function()
  local ns, M
  before_each(function()
    ns = {}
    loadAddonFile(ns, "Guildhearth/Core/Util.lua")
    loadAddonFile(ns, "Guildhearth/Modules/Exchange/MailDrafts.lua")
    M = ns.Exchange.MailDrafts
  end)

  it("drafts are FIFO and deduplicated by listing", function()
    local store = {}
    local d = M.new(store)
    local a = d:Add("Bob", "s1", "b1", "L1")
    d:Add("Cy", "s2", "b2", "L2")
    assert.is_nil(d:Add("Bob", "s1x", "b1x", "L1"))
    assert.are.equal(2, d:Count())
    assert.are.equal("Bob", d:Next().to)
    d:Remove(a.id)
    assert.are.equal("Cy", d:Next().to)
    d:Remove(9999)
    assert.are.equal(1, d:Count())
    d:Remove(d:Next().id)
    assert.is_nil(d:Next())
    assert.are.equal(0, d:Count())
  end)

  it("nil listingId is never deduplicated; ids stay monotonic; state lives in store", function()
    local store = {}
    local d = M.new(store)
    local a = d:Add("A", "s", "b")
    local b = d:Add("A", "s", "b")
    assert.are_not.equal(a.id, b.id)
    d:Remove(b.id)
    local c = d:Add("A", "s", "b")
    assert.is_true(c.id > b.id)
    local d2 = M.new(store)
    assert.are.equal(2, d2:Count())
  end)
end)
