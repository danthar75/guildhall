-- Both TOCs (Forever and Classic Era) load the same files, in the same order, and every one exists.
describe("TOC files", function()
  local function files(path)
    local f = assert(io.open(path))
    local out = {}
    for line in f:lines() do
      line = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" and line:sub(1, 1) ~= "#" then out[#out + 1] = line end
    end
    f:close()
    return out
  end

  local forever = files("Guildhall/Guildhall.toc")
  local vanilla = files("Guildhall/Guildhall_Vanilla.toc")

  it("list the same files in the same order", function()
    assert.is_true(#forever > 0)
    assert.same(forever, vanilla)
  end)

  it("list only files that exist, each once", function()
    local seen = {}
    for _, rel in ipairs(forever) do
      assert.is_nil(seen[rel], "listed twice: " .. rel)
      seen[rel] = true
      local f = io.open("Guildhall/" .. rel:gsub("\\", "/"))
      assert.is_not_nil(f, "missing: " .. rel)
      if f then f:close() end
    end
  end)

  it("list every Lua file in the addon, with Init first and Boot last", function()
    local listed = {}
    for _, rel in ipairs(forever) do listed[rel] = true end
    local p = assert(io.popen("cd Guildhall && find . -name '*.lua' | sort"))
    for path in p:lines() do
      local rel = path:gsub("^%./", "")
      assert.is_true(listed[rel] == true, "not in the TOC: " .. rel)
    end
    p:close()
    assert.equal("Core/Init.lua", forever[1])
    assert.equal("Core/Boot.lua", forever[#forever])
  end)
end)
