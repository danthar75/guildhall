local ADDON, ns = ...

-- Log tab: filter box, scrolling read-only text of Log:Export lines, Export button.
-- Named global: "GuildhallUILogScroll" (scroll frame template needs a name on some clients).
local UI = ns.UI
local LogView = {}
UI.LogView = LogView

local MAX_SHOWN = 500 -- entries rendered in the tab; Export always includes every match
local OBSERVATIONS = "core.observations"

-- Who sees the payload of observation entries. Task 16 may swap this for a rank permission.
local function canSeeDetail()
  local s = ns.services
  return s ~= nil and s.roster ~= nil and s.roster:IsOfficer(s.playerChar) == true
end

-- Text for a list of entries (newest first). Without detail access, each run of consecutive
-- observation entries becomes one line of counts: "<time> | observations | received N (trade 2, bank 10)".
function LogView.Export(log, list, seeDetail)
  if seeDetail then return log:Export(list) end
  local out, run = {}, nil
  local function flush()
    if not run then return end
    local parts = {}
    for _, kind in ipairs(run.kinds) do parts[#parts + 1] = kind .. " " .. run.counts[kind] end
    local line = table.concat({ run.time, "observations", "received " .. run.n }, " | ")
    if #parts > 0 then line = line .. " (" .. table.concat(parts, ", ") .. ")" end
    out[#out + 1] = line
    run = nil
  end
  for _, e in ipairs(list) do
    if e.set == OBSERVATIONS then
      -- only accepted records count as received; ignored or rejected ones are left out
      local kind = type(e.after) == "table" and e.after.kind or nil
      if e.result == "accepted" and type(kind) == "string" then
        if not run then
          local ts = type(e.t) == "number" and log.fmtTime(e.t) or tostring(e.t or "")
          run = { time = ts, n = 0, kinds = {}, counts = {} }
        end
        run.n = run.n + 1
        if not run.counts[kind] then run.counts[kind] = 0; run.kinds[#run.kinds + 1] = kind end
        run.counts[kind] = run.counts[kind] + 1
      end
    else
      flush()
      out[#out + 1] = log:Export({ e })
    end
  end
  flush()
  return table.concat(out, "\n")
end

local function matches(e, needle, seeDetail)
  if needle == "" then return true end
  if e.set == OBSERVATIONS and not seeDetail then return false end -- ids and names stay hidden
  for _, k in ipairs({ "id", "author", "authorChar", "relayer" }) do
    local v = e[k]
    if v ~= nil and string.find(string.lower(tostring(v)), needle, 1, true) then return true end
  end
  return false
end

local function filtered(view)
  local s = ns.services
  if not (s and s.log) then return nil end
  local needle = string.lower(ns.Util.Trim(view.filter:GetText() or ""))
  local out, seeDetail = {}, canSeeDetail()
  for _, e in ipairs(s.log:Query()) do
    if type(e) == "table" and matches(e, needle, seeDetail) then out[#out + 1] = e end
  end
  return out
end

function LogView.Build(parent)
  local view = {}

  local label = UI.Text(parent, "GameFontNormal", "Filter:")
  label:SetPoint("TOPLEFT", 4, -6)

  view.filter = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  view.filter:SetSize(260, 20)
  view.filter:SetAutoFocus(false)
  view.filter:SetPoint("LEFT", label, "RIGHT", 10, 0)
  view.filter:SetScript("OnTextChanged", function() UI.Try(view.refresh, view) end)
  view.filter:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  view.filter:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

  local help = UI.Text(parent, "GameFontDisableSmall", "Listing ID, profile or character")
  help:SetPoint("LEFT", view.filter, "RIGHT", 10, 0)

  local export = UI.Button(parent, "Export", 90, function()
    local list = filtered(view) or {}
    UI.CopyBox:Show("Guildhall log", LogView.Export(ns.services.log, list, canSeeDetail()))
  end)
  export:SetPoint("TOPRIGHT", -4, -2)

  view.count = UI.Text(parent, "GameFontDisableSmall")
  view.count:SetPoint("BOTTOMLEFT", 4, 2)

  local scroll
  scroll, view.edit = UI.ScrollText(parent, "GuildhallUILogScroll")
  scroll:SetPoint("TOPLEFT", 4, -34)
  scroll:SetPoint("BOTTOMRIGHT", -26, 18)

  function view.refresh()
    local list = filtered(view)
    if not list then
      UI.SetReadOnlyText(view.edit, UI.NO_GUILD_TEXT)
      view.count:SetText("")
      return
    end
    local shown = list
    if #list > MAX_SHOWN then
      shown = {}
      for i = 1, MAX_SHOWN do shown[i] = list[i] end
    end
    local text = LogView.Export(ns.services.log, shown, canSeeDetail())
    if text == "" then text = "No log entries." end
    UI.SetReadOnlyText(view.edit, text)
    if #list > MAX_SHOWN then
      view.count:SetText(string.format("Showing newest %d of %d entries. Export includes all.", MAX_SHOWN, #list))
    else
      view.count:SetText(string.format("%d entries", #list))
    end
  end

  return view
end
