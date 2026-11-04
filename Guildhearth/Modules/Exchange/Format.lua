local ADDON, ns = ...

-- Pure text formatting for Exchange listings: Discord copy text, whisper text
-- and mail subject/body. Guildhall never sends anything; callers only pre-fill.
ns.Exchange = ns.Exchange or {}

local Format = {}

Format.DEFAULTS = {
  whisperLF = "Hi! Saw your Guildhall listing for {item}. Are you still looking?",
  whisperWTS = "Hi! Saw your Guildhall listing for {item}. Is it still available?",
  mailSubject = "Guildhall: {itemName}",
  mailBodyLF = "Hi! Saw your Guildhall listing for {itemName}. Are you still looking?",
  mailBodyWTS = "Hi! Saw your Guildhall listing for {itemName}. Is it still available?",
  discord = "{kind} {itemName}{qtySuffix}{matsLine}\nI am {codWord} to CoD{noteLine}\n({char}, in game via Guildhall)",
}

local function usable(s)
  return type(s) == "string" and s ~= "" and s or nil
end

-- Text before the first "-" (byte-wise; "-" is ASCII so UTF-8 safe).
local function bareName(s)
  local n = usable(s)
  if not n then return nil end
  return usable(n:match("^([^%-]*)"))
end

function Format.Vars(rec)
  local d = rec.d or {}
  local item = tostring(d.item or "")
  local char = bareName(rec.char)
  if not char and d.src == "discord" then char = bareName(d.poster) end
  return {
    item = item,
    itemName = ns.Util.ItemName(item),
    qtySuffix = d.qty and (" x" .. d.qty) or "",
    matsWord = d.mats and "will" or "will not",
    -- Empty when the materials question doesn't apply to this item (d.mats == nil).
    matsLine = d.mats == nil and "" or ("\nI " .. (d.mats and "will" or "will not") .. " provide materials"),
    codWord = d.cod and "open" or "not open",
    noteLine = usable(d.note) and ("\nNote: " .. d.note) or "",
    char = char or "",
    kind = d.kind,
  }
end

local function tpl(templates, key)
  local v = type(templates) == "table" and templates[key]
  if type(v) == "string" then return v end
  return Format.DEFAULTS[key]
end

-- Fill is a single pass with function replacement, so "%" and "{...}" inside
-- values (e.g. a player-written note) are emitted literally.
local function render(rec, templates, key)
  return ns.Util.Fill(tpl(templates, key), Format.Vars(rec))
end

function Format.Discord(rec, templates)
  return render(rec, templates, "discord")
end

function Format.Whisper(rec, templates)
  return render(rec, templates, rec.d.kind == "WTS" and "whisperWTS" or "whisperLF")
end

function Format.Mail(rec, templates)
  return render(rec, templates, "mailSubject"),
    render(rec, templates, rec.d.kind == "WTS" and "mailBodyWTS" or "mailBodyLF")
end

ns.Exchange.Format = Format
