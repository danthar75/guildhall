# Guildhall Core + Exchange Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Guildhall addon core and its first module, the Exchange: an in-game, guild-synced buy/sell board with whisper/mail pre-fill, Discord copy-out, player (alt-aware) ownership and a local audit log.

**Architecture:** One addon folder `Guildhall/`. Pure-Lua logic (serialization, replicated record sets, sync, comms chunking/queueing, audit log, guild config parsing, profiles, listing model, formatting, mail drafts) lives in files that touch WoW only through an injected `Compat` object, so it can be unit-tested outside the game with busted. Thin WoW-facing files (UI, event wiring) are verified by a syntax check plus a manual in-game checklist (Classic Era first, Forever at launch). The Exchange is a module registered with the core. Listings and player profiles both sync through one generic `ReplicatedSet` + `Sync` mechanism, which later modules reuse.

**Tech Stack:** Lua 5.1 (WoW dialect), WoW Mainline API (Forever 1.60.1 / TOC 16001), busted for unit tests, hererocks (via Python venv) for a local Lua 5.1 + LuaRocks. **No third-party WoW libraries** (decision: removes the risk of a library not loading on Forever, and the needs here are small).

**Spec:** `docs/superpowers/specs/2026-11-02-guildhall-exchange-design.md`. Restrictions research: `reference/notes/restrictions-summary.md`.

## Global Constraints

- Release TOC: `## Interface: 16001`, `## AllowLoadGameType: forever`, `## ExcludeLoadGameType: standard, classic`. Folder `Guildhall/`, file `Guildhall/Guildhall.toc`.
- Dev-only Classic Era TOC `Guildhall/Guildhall_Vanilla.toc`. It is never shipped in a release zip.
- Every file starts with `local ADDON, ns = ...` and exports through `ns`. No new globals except `GuildhallDB` (SavedVariables) and the slash command globals.
- **Guildhall never sends a whisper, a mail or a chat message by itself.** It only pre-fills; the user presses Enter or Send.
- No Emergence-specific values in code. Guild-wide values come from the Guild Info tag; personal values come from `GuildhallDB`.
- Comms only via `C_ChatInfo.SendAddonMessage` on `"GUILD"`. Prefix `"Guildhall"`. Messages ≤ 255 bytes, no `\0`.
- Any value from guild, club, chat or calendar APIs may be secret. Pass it through `Compat.Safe` before comparing or storing it. Never write a secret to SavedVariables.
- Time is server time (`GetServerTime()` via `Compat.Now()`). Listing lifetime `604800` s (7 days). Profile lifetime `2592000` s (30 days). Log cap `2592000` s (30 days) or `5000` entries.
- Default officer threshold: rank index `< 2` (the top two ranks). Guild Info tag format `[Guildhall officers=N]`.
- Older clients ignore unknown message kinds and log them; they never raise Lua errors.

## Review Focus

1. **Secret or missing roster/guild data inside instances.** The expected behavior is "unknown" status (grey "?" dot) and cached officer config, never a Lua error. Pinned in Task 8 (`roster returns nil for secret values`).
2. **Bad timestamps from other clients** (expiry already passed, `t` more than 1 day in the future, `exp` more than 8 days ahead for a listing). These are rejected and logged. Pinned in Task 4 (`Apply rejects future-dated records`) and Task 10 (`rejects listing with exp beyond 8 days`).
3. **The same listing edited from two alts at once.** Every client must pick the same deterministic winner. Pinned in Task 4 (`tie on version breaks by t then char`).
4. **Malformed, truncated or unknown-version messages.** These are ignored, reported via `onIgnored`, and never error. Pinned in Task 2 (`decode returns nil on garbage`) and Task 5 (`drops incomplete chunk sets after 30s`, `ignores unknown module/kind`).
5. **Character names with and without a realm suffix, and non-ASCII names** (for example `Thálwyn`). These must match the same profile and roster entry. Pinned in Task 2 (`FullName normalizes`).

---

## File Structure

```
.gitignore                         .superpowers/, .tools/, *.zip
.busted                            busted config (ROOT = spec, lpath = Guildhall/?.lua)
tools/setup.sh                     creates .tools/ (venv → hererocks → Lua 5.1 + busted)
tools/check.sh                     luac -p on every Guildhall/**/*.lua, then busted
spec/helpers/load.lua              loadAddonFile(ns, path) — runs a file with ("Guildhall", ns)
spec/helpers/fakes.lua             fake Compat, fake clock, fake timer queue
spec/*_spec.lua                    one spec per pure module
Guildhall/Guildhall.toc            release TOC (Forever)
Guildhall/Guildhall_Vanilla.toc    dev TOC (Classic Era)
Guildhall/Core/Init.lua            ns setup, module registry, event bus
Guildhall/Core/Util.lua            string/table helpers, FullName, item-link parsing
Guildhall/Core/Serialize.lua       encode/decode Lua values ↔ strings
Guildhall/Core/Compat.lua          every WoW API touch point (secret-safe, client differences)
Guildhall/Core/DB.lua              SavedVariables layout, per-guild scoping, defaults
Guildhall/Core/Theme.lua           theme tokens
Guildhall/Core/ReplicatedSet.lua   versioned records, tombstones, expiry, digests
Guildhall/Core/Comm.lua            envelope, chunking, reassembly, throttled queue, dispatch
Guildhall/Core/Sync.lua            REQ/REC protocol over Comm for one ReplicatedSet
Guildhall/Core/Log.lua             audit log
Guildhall/Core/Roster.lua          guild roster cache, Guild Info tag, officer check
Guildhall/Core/Profile.lua         player profile, alt linking, consent
Guildhall/Core/Boot.lua            event wiring: login, roster, CHAT_MSG_ADDON, restriction lift
Guildhall/Core/UI/Window.lua       main window shell, tab registry (module tabs + Log + Settings)
Guildhall/Core/UI/CopyBox.lua      select-all copy dialog
Guildhall/Core/UI/Launcher.lua     minimap button, slash commands /gh /guildhall
Guildhall/Core/UI/LogView.lua      Log tab
Guildhall/Core/UI/SettingsView.lua Settings tab (modules add sections)
Guildhall/Core/UI/Consent.lua      alt-link consent dialog
Guildhall/Modules/Exchange/Listing.lua   listing model, validation, permissions
Guildhall/Modules/Exchange/Format.lua    Discord / whisper / mail text
Guildhall/Modules/Exchange/MailDrafts.lua draft queue
Guildhall/Modules/Exchange/Exchange.lua  module registration, actions, sync wiring
Guildhall/Modules/Exchange/UI/Board.lua  list + details pane (layout B)
Guildhall/Modules/Exchange/UI/Form.lua   new/edit listing form (item slot: shift-click / drag to load)
Guildhall/Modules/Exchange/Import.lua    Discord paste parser (Task 16, deferred)
Guildhall/Modules/Exchange/UI/ImportPreview.lua  import preview (Task 16, deferred)
docs/testing/in-game-checklist.md        manual checklist (Classic Era vs Forever-only items)
```

TOC load order is the order above: Core (Init, Util, Serialize, Compat, DB, Theme, ReplicatedSet, Comm, Sync, Log, Roster, Profile), Core/UI/*, Modules/Exchange (Listing, Format, MailDrafts, Exchange, UI/Form, UI/Board), then Core/Boot.lua last.

---

### Task 1: Tooling, scaffold, module registry

**Files:**
- Create: `.gitignore`, `.busted`, `tools/setup.sh`, `tools/check.sh`, `spec/helpers/load.lua`, `spec/helpers/fakes.lua`, `Guildhall/Guildhall.toc`, `Guildhall/Guildhall_Vanilla.toc`, `Guildhall/Core/Init.lua`
- Test: `spec/init_spec.lua`

**Interfaces:**
- Produces:
  - `loadAddonFile(ns, relPath)` (global in spec helpers)
  - `fakes.clock(start) -> {now=fn, advance=fn(s)}`
  - `fakes.timers() -> {after=fn(delay, cb), run=fn(clock)}` (runs callbacks whose due time ≤ clock.now())
  - `fakes.compat(overrides) -> Compat-shaped table` (Task 3 defines the shape; until then, a table of overrides)
  - `ns.RegisterModule(name, def)` and `ns.GetModule(name)`. `def` may define `OnInit(ns)`, `OnLogin(ns)`, `tab = {title, build=fn(parent)}` and `settings = {build=fn(parent)}`.
  - `ns.Modules()` returns registered names in registration order.
  - `ns.Events:On(event, fn)`, `ns.Events:Fire(event, ...)`

- [ ] **Step 1: Init git and ignore files.** Run `git init` in the project root. `.gitignore` contains `.superpowers/`, `.tools/` and `*.zip`. Then `git add -A && git commit -m "chore: initial reference snapshot and design docs"`.
- [ ] **Step 2: Write `tools/setup.sh`.** It must be idempotent and do: `python3 -m venv .tools/venv`, `.tools/venv/bin/pip install hererocks`, `.tools/venv/bin/hererocks .tools/lua -l5.1 -rlatest`, `.tools/lua/bin/luarocks install busted`. Run it. Expected: `.tools/lua/bin/busted --version` prints a version.
- [ ] **Step 3: Write `tools/check.sh`.** It runs `.tools/lua/bin/luac -p` on every `Guildhall/**/*.lua` (failing on the first error), then `.tools/lua/bin/busted`. `.busted` sets `ROOT = {"spec"}` and `helper = "spec/helpers/load.lua"`.
- [ ] **Step 4: Write the TOCs.** `Guildhall.toc` uses the release header from Global Constraints plus `## Title: Guildhall`, `## SavedVariables: GuildhallDB`, `## Version: 0.1.0`, and the file list in the load order from File Structure. `Guildhall_Vanilla.toc` has the same file list with `## Interface: 11507` and no game-type lines. Add the comment line `# Dev only. Check the value with /dump select(4, GetBuildInfo()) on Classic Era.`
- [ ] **Step 5: Write the failing test** `spec/init_spec.lua`:

```lua
describe("module registry", function()
  local ns
  before_each(function() ns = {}; loadAddonFile(ns, "Guildhall/Core/Init.lua") end)
  it("registers and returns modules in order", function()
    ns.RegisterModule("Exchange", { tab = { title = "Exchange" } })
    ns.RegisterModule("Later", {})
    assert.same({ "Exchange", "Later" }, ns.Modules())
    assert.equal("Exchange", ns.GetModule("Exchange").tab.title)
  end)
  it("rejects duplicate names", function()
    ns.RegisterModule("Exchange", {})
    assert.has_error(function() ns.RegisterModule("Exchange", {}) end)
  end)
  it("event bus calls handlers with args", function()
    local got
    ns.Events:On("X", function(a, b) got = a + b end)
    ns.Events:Fire("X", 2, 3)
    assert.equal(5, got)
  end)
end)
```

- [ ] **Step 6: Run** `tools/check.sh`. Expected: FAIL (Init.lua missing).
- [ ] **Step 7: Implement `Guildhall/Core/Init.lua`.** The registry and event bus are plain tables. A handler error inside `Fire` is caught with `pcall` and passed to `ns.OnError(err)` (default: `print`).
- [ ] **Step 8: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 9: Commit** `git add -A && git commit -m "feat(core): scaffold, tooling, module registry"`

### Task 2: Util and Serialize

**Files:**
- Create: `Guildhall/Core/Util.lua`, `Guildhall/Core/Serialize.lua`
- Test: `spec/util_spec.lua`, `spec/serialize_spec.lua`

**Interfaces:**
- Produces:
  - `ns.Util.FullName(name, realm, defaultRealm) -> "Name-Realm"`. If `name` already contains `-` it is returned unchanged. Realm spaces and apostrophes are stripped (WoW's normalized realm form).
  - `ns.Util.ItemName(linkOrName) -> string`: the plain name from `|h[Name]|h`, otherwise the input trimmed.
  - `ns.Util.IsItemLink(s) -> bool`
  - `ns.Util.ItemIdFromLink(s) -> number | nil`: the item ID from `|Hitem:<id>:`, nil for non-item links (used by the form's item slot to look up the icon)
  - `ns.Util.Trim(s)`, `ns.Util.DeepCopy(t)`
  - `ns.Util.Fill(template, vars) -> string`: replaces `{key}`. Unknown keys are left as they are.
  - `ns.Serialize.Encode(v) -> string` and `ns.Serialize.Decode(s) -> v | nil, err`. Supported types: nil, boolean, number (including negatives and floats), string, and tables with string or number keys, nested. Output never contains `\0`.

- [ ] **Step 1: Write failing tests.**

```lua
-- util_spec.lua
it("FullName normalizes", function()
  assert.equal("Thálwyn-ArgentDawn", U.FullName("Thálwyn", "Argent Dawn"))
  assert.equal("Brakka-Realm", U.FullName("Brakka-Realm", "Other"))
  assert.equal("Mireth-Home", U.FullName("Mireth", nil, "Home"))
end)
it("ItemName strips links", function()
  local link = "|cffa335ee|Hitem:14152::::::::60:::::|h[Robe of the Archmage]|h|r"
  assert.equal("Robe of the Archmage", U.ItemName(link))
  assert.is_true(U.IsItemLink(link))
  assert.equal("Runecloth", U.ItemName("  Runecloth "))
end)
it("ItemIdFromLink reads item links only", function()
  assert.equal(14152, U.ItemIdFromLink("|cffa335ee|Hitem:14152::::::::60:::::|h[Robe of the Archmage]|h|r"))
  assert.is_nil(U.ItemIdFromLink("|cffffd000|Henchant:7418|h[Enchanting: Runed Copper Rod]|h|r"))
  assert.is_nil(U.ItemIdFromLink("Runecloth"))
end)
it("Fill replaces known keys only", function()
  assert.equal("a X {y}", U.Fill("a {x} {y}", { x = "X" }))
end)
-- serialize_spec.lua
it("round-trips nested values", function()
  local v = { id = "p1:2", v = 3, del = false, d = { note = "a|b\n:{}\\", qty = -4.5, list = { 1, "two" } } }
  assert.same(v, S.Decode(S.Encode(v)))
end)
it("never emits NUL", function()
  assert.is_nil(S.Encode({ s = "x\0y" }):find("\0", 1, true))
  assert.equal("x\0y", S.Decode(S.Encode({ s = "x\0y" })).s)
end)
it("decode returns nil on garbage", function()
  assert.is_nil((S.Decode("}{not valid")))
  assert.is_nil((S.Decode("")))
end)
```

- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement both files.** Serialize uses a compact tagged format of the builder's choice; it must escape `\0` and its own delimiters. `Decode` is wrapped in `pcall` and returns `nil, err` on failure. It never evaluates code (no `loadstring`).
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): util helpers and serializer`

### Task 3: Compat (all WoW touch points)

**Files:**
- Create: `Guildhall/Core/Compat.lua`
- Modify: `spec/helpers/fakes.lua` (make `fakes.compat` return a real `Compat.new(fakeEnv)`)
- Test: `spec/compat_spec.lua`

**Interfaces:**
- Produces `ns.Compat.new(env) -> compat` (`env` defaults to `_G`; tests pass a fake), and `ns.compat` (the live instance, created at load time). Methods:
  - `Safe(v) -> v | nil`: nil when `env.issecretvalue(v)` is true or `env.canaccessvalue(v)` is false. Both are treated as absent on Classic Era.
  - `IsRestricted(kind) -> bool`, where `kind` is one of `"Chat"`, `"Map"`, `"Combat"`, `"Encounter"`. It uses `env.C_RestrictedActions.GetAddOnRestrictionState(env.Enum.AddOnRestrictionType[kind])` and treats any non-zero/non-inactive state as restricted. Missing API → false.
  - `Now() -> number` (`env.GetServerTime()`)
  - `RegisterPrefix(prefix)`
  - `SendAddon(prefix, msg) -> "ok" | "lockdown" | "throttle" | "error"`. It maps `Enum.SendAddonMessageResult`: 0 → ok; 11 → lockdown; 3 and 8 → throttle; anything else → error. A legacy boolean `true` return → ok. If `IsRestricted("Chat")` it returns `"lockdown"` without calling the API.
  - `IsTrial() -> bool` (`IsTrialAccount()` or `IsVeteranTrialAccount()`)
  - `OpenChat(text)`: `env.ChatFrameUtil.OpenChat(text)` if present, else `env.ChatFrame_OpenChat(text)`
  - `MailboxOpen() -> bool`: tracked by Boot from `MAIL_SHOW` / `MAIL_CLOSED` via `compat:SetMailboxOpen(bool)`
  - `FillSendMail(to, subject, body) -> bool`: switches to the Send Mail tab and sets the recipient, subject and body edit boxes. The builder looks up the frame names in the `forever` branch FrameXML (`Interface/AddOns/Blizzard_MailFrame`) and falls back gracefully (returns false) if a frame is missing.
  - `GuildKey() -> string | nil`: `Util.FullName(guildName, guildRealm, playerRealm)` from `GetGuildInfo("player")`, nil when not in a guild or when the value is secret
  - `PlayerFullName() -> string`

- [ ] **Step 1: Write failing tests.** Cover:
  - `Safe` returns nil for a value the fake marks as secret, and returns the value when `issecretvalue` is absent.
  - `IsRestricted("Chat")` is false when `C_RestrictedActions` is absent.
  - `SendAddon` returns `"lockdown"` for result 11, `"throttle"` for 3, `"ok"` for 0 and for `true`.
  - `SendAddon` returns `"lockdown"` without calling the API when the Chat restriction is active (assert that the fake's send counter stays 0).
  - `GuildKey` returns nil when `GetGuildInfo` returns nil.
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement** `Compat.lua` against `env`, never touching `_G` directly inside methods.
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): compat layer for secrets, restrictions and client differences`

### Task 4: ReplicatedSet

**Files:**
- Create: `Guildhall/Core/ReplicatedSet.lua`
- Test: `spec/replicatedset_spec.lua`

**Interfaces:**
- Record shape (shared by every synced thing):

  | Field | Type | Meaning |
  |---|---|---|
  | `id` | string | |
  | `v` | integer | version |
  | `t` | number | server time of the last change |
  | `by` | string | author profile ID |
  | `char` | string | author character, full name |
  | `exp` | number | expiry time |
  | `del` | boolean | tombstone |
  | `d` | table | payload |

- Produces `ns.ReplicatedSet.new(name, store, opts) -> set`. `store` is a plain table (SavedVariables-backed) that holds records by id. `opts`:
  - `now` (function)
  - `maxFuture` (seconds, default 86400)
  - `onChange(rec, old)`
  - `validate(rec) -> ok, reason`, optional, for payload checks

  Methods:
  - `:Get(id)`
  - `:List(includeDeleted) -> array`, sorted by `t` descending
  - `:Apply(rec) -> status, old`, where status is `"accepted"`, `"stale"`, `"expired"`, `"future"` or `"invalid"`
  - `:Purge() -> n`
  - `:Digest() -> {[id] = v}`
  - `:Missing(digest) -> array of records`: records this set has that the digest lacks, or holds at a lower version
  - `:NextVersion(id) -> integer`

- **Merge rule:** incoming beats local when the tuple `(v, t, del and 1 or 0, char)` compares greater, comparing left to right.
- **Rejections:**
  - `exp <= now` → `"expired"`
  - `t > now + maxFuture` → `"future"`
  - missing `id`, `v`, `t` or `exp` → `"invalid"`
  - `opts.validate` failing → `"invalid"`
- `Purge` removes every record (including tombstones) with `exp <= now`.

- [ ] **Step 1: Write failing tests:**
  - `Apply accepts new record and fires onChange`
  - `higher version wins`
  - `lower version is stale`
  - `tie on version breaks by t then char` (two records with the same `v`: the later `t` wins; with equal `t`, the greater `char` string wins; the outcome is the same whichever order they're applied in)
  - `tombstone beats live record at same v and t`
  - `Apply rejects expired records`
  - `Apply rejects future-dated records` (`t = now + 86401` → `"future"`)
  - `Purge drops expired records and tombstones`
  - `Missing returns records peer lacks or has older`
  - `store table is mutated in place` (so SavedVariables persist)
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): replicated record set with deterministic merge`

### Task 5: Comm (envelope, chunking, queue, dispatch)

**Files:**
- Create: `Guildhall/Core/Comm.lua`
- Test: `spec/comm_spec.lua`

**Interfaces:**
- Consumes: `compat:SendAddon`, `compat:IsRestricted`, `ns.Serialize`
- Produces `ns.Comm.new(opts) -> comm`. `opts`:
  - `compat`, `now`, `after(delay, cb)`
  - `prefix` (default `"Guildhall"`)
  - `maxBytes` (default 255)
  - `burst` (default 10), `refill` (messages per second, default 1)
  - `onIgnored(sender, reason)`

  Methods:
  - `:On(module, kind, handler(payload, sender))`
  - `:Send(module, kind, payload)`: enqueue, then pump
  - `:Receive(prefix, msg, channel, sender)`: wired to `CHAT_MSG_ADDON` by Boot; it ignores other prefixes, non-`GUILD` channels and the player's own messages
  - `:Pump()`
  - `:Pending() -> n`
- **Envelope:** `Serialize.Encode({pv = 1, m = module, k = kind, p = payload})`.
- **Chunk wire format:** `"<seq>:<i>/<n>:" .. slice`, where `seq` is a per-sender counter mod 1000 and the whole line is ≤ `maxBytes`.
- **Reassembly:** keyed by `sender .. seq`. Incomplete sets are dropped 30 s after their first chunk.
- **Queue behavior:**
  - a token bucket limits sends
  - a `"throttle"` result requeues at the front and retries after 2 s
  - a `"lockdown"` result keeps the queue and retries every 5 s
  - an `"error"` result drops the message and calls `onIgnored(nil, "send error")`
- **Dispatch:**
  - unknown module/kind → `onIgnored(sender, "unknown " .. m .. "/" .. k)`
  - `pv` greater than 1 → still dispatched (forward compatible: handlers ignore fields they don't know)
  - a decode failure → `onIgnored(sender, "bad payload")`

- [ ] **Step 1: Write failing tests** (fake compat records sent lines, fake clock and timers):
  - `small message is one line ≤ 255 bytes`
  - `large payload splits and reassembles in order`
  - `reassembles out-of-order chunks`
  - `drops incomplete chunk sets after 30s` (and calls nothing)
  - `ignores unknown module/kind` (onIgnored is called; no error)
  - `ignores own messages and other prefixes`
  - `burst then throttles at refill rate` (12 sends: 10 go immediately, then 1 per second)
  - `lockdown keeps queue and retries until lifted`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): addon comms with chunking, throttling and lockdown queue`

### Task 6: Sync

**Files:**
- Create: `Guildhall/Core/Sync.lua`
- Test: `spec/sync_spec.lua`

**Interfaces:**
- Consumes: `comm:On/Send`, `set:Digest/Missing/Apply`
- Produces `ns.Sync.new(opts) -> sync`. `opts`:
  - `comm`, `set`, `module` (comm module name, for example `"exchange.listings"`)
  - `after(delay, cb)`, `random(lo, hi)`
  - `onApplied(rec, status, old, sender)`: Exchange and Profile use it to write log entries
  - `validate(rec, existing, sender) -> ok, reason`, optional: called before `set:Apply`. A failure skips the Apply and reports status `"invalid"` with that reason to `onApplied`. An accepted record whose `reason` is non-nil (for example `"officer unverified"`) is still applied, and the reason is passed through.
  - `onApplied` takes a fifth argument, `reason`

  Methods:
  - `:Start()`: sends `REQ {have = set:Digest()}`
  - `:Publish(rec)`: applies locally and sends `REC {rs = {rec}}`
- **Protocol:**
  - On a `REQ` from a peer: after `random(1, 5)` seconds, send `REC` messages with `set:Missing(have)`, in batches of 5 records per message.
  - During that wait, any record seen in another peer's `REC` at an equal or higher version is removed from the pending reply (duplicate suppression).
  - On a `REC`: `set:Apply` each record, then call `onApplied(rec, status, old, sender)` for **every** record, including stale and invalid ones, so they can be logged.

- [ ] **Step 1: Write failing tests** (two or three sync instances on a shared fake "guild bus"):
  - `validate failure skips apply and reports invalid with reason`
  - `late joiner receives missing records after REQ`
  - `peer reply is suppressed when another peer already sent the record`
  - `Publish reaches peers and applies locally`
  - `onApplied reports stale and invalid with sender`
  - `newer local edit is not overwritten by older relayed copy`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): set sync protocol (REQ/REC with suppression)`

### Task 7: Audit log

**Files:**
- Create: `Guildhall/Core/Log.lua`
- Test: `spec/log_spec.lua`

**Interfaces:**
- Produces `ns.Log.new(store, now) -> log`, where `store` is an array table in SavedVariables. Entry fields:
  - `t`, `action`, `set`, `id`, `v`
  - `author` (profile ID), `authorChar`, `relayer`
  - `result` (`"accepted"`, `"stale"`, `"rejected"` or `"ignored"`), `reason`
  - `before`, `after` (`d` payloads, for edits)

  Methods:
  - `:Add(entry)`: stamps `t` if it's missing, then prunes
  - `:Prune()`: removes entries older than 2592000 s, then the oldest beyond 5000
  - `:Query(filter) -> array`, newest first. `filter` keys are `id`, `author` and `char`; `char` matches either `authorChar` or `relayer`.
  - `:Export(entries) -> string`: one line per entry, `YYYY-MM-DD HH:MM:SS | action | result | id vN | author/authorChar via relayer | reason`, followed by `  before: …` / `  after: …` lines for edits (fields shown as `key=value`)

- [ ] **Step 1: Write failing tests:**
  - `Add stamps time`
  - `prunes by age`
  - `prunes beyond 5000 oldest first`
  - `Query filters by char matching author or relayer`
  - `Export includes relayer and before/after`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use `os.date` through an injectable `fmtTime` (WoW has `date`).
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): local audit log`

### Task 8: Roster and Guild Info config

**Files:**
- Create: `Guildhall/Core/Roster.lua`
- Test: `spec/roster_spec.lua`

**Interfaces:**
- Consumes: `compat` (it adds `compat:GetNumGuildMembers()`, `compat:GetGuildRosterInfo(i)`, `compat:RequestRoster()` and `compat:GetGuildInfoText()` to Compat in this task; each one passes its returns through `Safe`)
- Produces:
  - `ns.Roster.ParseTag(text) -> table`: from `[Guildhall key=val key2=val]`. Numbers are converted. Returns `{}` when there's no tag.
  - `ns.Roster.new(compat, cache) -> roster`, where `cache` is a per-guild DB table holding `guildConfig` and `ranks`. Methods:
    - `:Refresh()`: re-reads the roster and Guild Info. Skips Guild Info while `IsRestricted("Map")`. On success it stores the parsed tag in `cache.guildConfig`, and each member's rank index in `cache.ranks`.
    - `:IsOnline(fullName) -> true | false | nil` (nil = unknown)
    - `:RankIndex(fullName) -> number | nil`
    - `:OfficerThreshold() -> number`: `cache.guildConfig.officers`, or 2
    - `:IsOfficer(fullName) -> true | false | nil`

- [ ] **Step 1: Write failing tests:**
  - `ParseTag reads officers=3`
  - `ParseTag ignores text without tag`
  - `IsOfficer uses threshold rank < N`
  - `roster returns nil for secret values` (the fake marks the online flag as secret → `IsOnline` returns nil, with no error)
  - `keeps cached guild config when restricted`
  - `unknown member returns nil`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): guild roster cache and Guild Info tag config`

### Task 9: DB, Theme, Profile

**Files:**
- Create: `Guildhall/Core/DB.lua`, `Guildhall/Core/Theme.lua`, `Guildhall/Core/Profile.lua`
- Test: `spec/db_spec.lua`, `spec/profile_spec.lua`

**Interfaces:**
- Produces:
  - `ns.DB.Init(sv) -> sv`: applies defaults in place. Layout:

    ```
    GuildhallDB = {
      schema = 1,
      personal = { profile = { id, consented, excluded = {} }, templates = {}, window = {} },
      guilds = { [guildKey] = { sets = {}, log = {}, cache = {}, modules = {} } },
    }
    ```

  - `ns.DB.Guild(sv, guildKey) -> table`, created on demand
  - `ns.DB.Module(sv, guildKey, moduleName) -> table`
  - `ns.Theme.Get(key)`: defaults are `title = "Guildhall"`, `accent = {1, 0.82, 0}`, `border = {0.42, 0.35, 0.23}`, `logo = nil`, `banner = nil`. `ns.Theme.Set(overrides)`.
  - `ns.Profile.new(opts) -> profile`. `opts`: `personal` (`DB.personal`), `set` (the ReplicatedSet `"profiles"`), `roster`, `now`, `random`, `playerChar`.

    Methods:
    - `:Id()`: lazily generates 12 random hex characters and stores them
    - `:SeeCharacter(fullName)`: records an account character in `personal.profile.chars`
    - `:NeedsConsent() -> bool`
    - `:PendingChars() -> array`
    - `:Consent(excludedArray)`
    - `:Record() -> rec | nil`: the profile record to publish, with `d = {chars = included}` and `exp = now + 2592000`; nil before consent
    - `:OwnerOf(fullName) -> profileId | nil`
    - `:CharsOf(profileId) -> array`
    - `:OnlineChar(profileId) -> fullName | nil`: the first linked character with `roster:IsOnline == true`
    - `:IsMine(profileId) -> bool`
  - **Character claim conflict:** when two profiles list the same character, `OwnerOf` returns the profile whose record has the greater `(t, id)`.

- [ ] **Step 1: Write failing tests:**
  - `DB.Init fills defaults without clobbering existing`
  - `Guild scoping isolates guilds`
  - `Id is stable once generated`
  - `no Record before consent`
  - `excluded chars are not published`
  - `OnlineChar picks an online alt`
  - `OwnerOf resolves conflicting claims by latest t`
  - `OwnerOf matches realm-less and realm names via FullName`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(core): saved variables layout, theme tokens, player profiles`

### Task 10: Exchange listing model and permissions

**Files:**
- Create: `Guildhall/Modules/Exchange/Listing.lua`
- Test: `spec/listing_spec.lua`

**Interfaces:**
- Payload `d`:

  | Field | Type | Rule |
  |---|---|---|
  | `kind` | `"LF"` or `"WTS"` | |
  | `item` | string | link or name; 1–255 bytes |
  | `qty` | integer, optional | 1–9999 |
  | `mats` | boolean | |
  | `cod` | boolean | |
  | `note` | string, optional | ≤ 200 bytes |
  | `offRemove` | boolean, optional | set by an officer removal |
  | `src` | `"discord"`, optional | set on imported listings (Task 16); absent for in-game posts |
  | `poster` | string, optional | Discord display name of an imported listing's author, ≤ 64 bytes |

- Produces `ns.Exchange.Listing`:
  - `.Validate(d) -> ok, err`
  - `.New(d, profileId, char, now, idCounter) -> rec`: id is `profileId .. ":" .. idCounter`, `v = 1`, `exp = now + 604800`
  - `.Edit(rec, changes, char, now) -> newRec`: `v + 1`, new `t`, same `exp`
  - `.Renew(rec, char, now) -> newRec`: `v + 1`, `exp = now + 604800`
  - `.Remove(rec, char, now, byOfficer) -> newRec`: `del = true`, `v + 1`. When `byOfficer` is true, it sets `d.offRemove = true` and changes `by` to the officer's profile, which is passed as `char`'s owner by the caller.
  - `.CheckIncoming(rec, existing, ctx) -> ok, reason`. `ctx` has `ownerOf(char)`, `isOfficer(char)` (returns true, false or nil) and `now`. The order of checks:
    1. `Validate(rec.d)`. Tombstones skip payload validation.
    2. `rec.exp > rec.t + 691200` (8 days) → `"exp too far"`.
    3. If `existing` exists and `rec.by ~= existing.by`, and this isn't an officer removal → `"not owner"`.
    4. An officer removal where `isOfficer(rec.char) == false` → `"not officer"`. A nil (unknown) result is accepted with the reason `"officer unverified"`.

    Per the spec's trust model, accepted reasons are logged, not blocked.
  - `.CanEdit(rec, myProfileId) -> bool`
  - `.CanOfficerRemove(isOfficer) -> bool`

- [ ] **Step 1: Write failing tests:**
  - `Validate rejects bad kind, empty item, qty 0, note > 200`
  - `Validate accepts src="discord" with poster, rejects unknown src and poster > 64`
  - `New sets 7-day expiry`
  - `Renew resets expiry and bumps version`
  - `Edit keeps expiry`
  - `rejects listing with exp beyond 8 days`
  - `rejects edit from different profile`
  - `accepts officer removal by officer`
  - `rejects officer removal by known non-officer`
  - `accepts officer removal with unknown rank as officer unverified`
  - `tombstone skips payload validation`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(exchange): listing model, validation, permissions`

### Task 11: Exchange formatting and mail drafts

**Files:**
- Create: `Guildhall/Modules/Exchange/Format.lua`, `Guildhall/Modules/Exchange/MailDrafts.lua`
- Test: `spec/format_spec.lua`, `spec/maildrafts_spec.lua`

**Interfaces:**
- Produces:
  - `ns.Exchange.Format.DEFAULTS`:
    - `whisperLF = "Hi! Saw your Guildhall listing for {item}. Are you still looking?"`
    - `whisperWTS = "Hi! Saw your Guildhall listing for {item}. Is it still available?"`
    - `mailSubject = "Guildhall: {itemName}"`
    - `mailBodyLF = "Hi! Saw your Guildhall listing for {itemName}. Are you still looking?"`
    - `mailBodyWTS = "Hi! Saw your Guildhall listing for {itemName}. Is it still available?"`
    - `discord = "{kind} {itemName}{qtySuffix}\nI {matsWord} provide materials\nI am {codWord} to CoD{noteLine}\n({char}, in game via Guildhall)"`
  - `.Vars(rec) -> table`:
    - `item` = the link, or the name
    - `itemName` = the plain name
    - `qtySuffix` = `" x" .. qty`, or `""`
    - `matsWord` = `"will"` or `"will not"`
    - `codWord` = `"open"` or `"not open"`
    - `noteLine` = `"\nNote: " .. note`, or `""`
    - `char` = the character name without the realm
    - `kind`
  - `.Discord(rec, templates)`, `.Whisper(rec, templates)`, `.Mail(rec, templates) -> subject, body`. `templates` overrides DEFAULTS key by key.
  - `ns.Exchange.MailDrafts.new(store) -> drafts`. Methods: `:Add(to, subject, body, listingId)`, `:Next() -> draft | nil` (oldest), `:Remove(draftId)`, `:Count()`. A listing ID already present isn't added twice.

- [ ] **Step 1: Write failing tests:**
  - `Discord matches pinned format for LF`. The expected output is exactly:

    ```
    LF Robe of the Archmage
    I will provide materials
    I am open to CoD
    Note: have the cloth, need a tailor. Tipping 20g.
    (Thalwyn, in game via Guildhall)
    ```

    The input is an item **link**, `mats = true`, `cod = true`, that note, and `char = "Thalwyn-Realm"`.
  - `Discord WTS with qty and no note`. Expected first line `WTS Runecloth x40`, and there is no `Note:` line.
  - `Whisper keeps item link`
  - `Mail subject is plain name`
  - `custom template overrides one key`
  - `drafts are FIFO and deduplicated by listing`
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(exchange): discord/whisper/mail formatting and mail drafts`

### Task 12: Exchange module wiring (actions and sync)

**Files:**
- Create: `Guildhall/Modules/Exchange/Exchange.lua`
- Test: `spec/exchange_spec.lua`

**Interfaces:**
- Consumes everything above.
- Produces `ns.Exchange.Create(ctx) -> ex`, with `ctx = {compat, comm, now, after, random, db, log, roster, profile}`. It builds the `"listings"` ReplicatedSet on `DB.Module(..., "Exchange").listings`, plus a Sync with module name `"exchange.listings"`. Its `onApplied` writes log entries:
  - action: `create` (no `old`), `edit`, `renew` (the `exp` grew), `remove` or `officer-remove`
  - `relayer = sender`
  - `before`/`after` for edits
  - stale or invalid records are logged as `"stale"` / `"rejected"` with the reason

  Before `Apply`, the Sync's validate hook calls `Listing.CheckIncoming`.

  Methods:
  - `ex:Post(d) -> ok, err`. It errors with `"trial"` when `compat:IsTrial()`, and with `"consent"` when `profile:NeedsConsent()`.
  - `ex:Edit(id, changes)`, `ex:Renew(id)`, `ex:Remove(id)`, `ex:OfficerRemove(id)`
  - `ex:List(filter) -> array`, where `filter` is `"all"`, `"LF"`, `"WTS"` or `"mine"`. Results are newest first and exclude tombstones and expired records.
    - It merges in records from a second, **local-only** ReplicatedSet `"imported"` on `DB.Module(..., "Exchange").imported`. That set has no Sync, so its records never go on the wire. Imported records never match `"mine"` and `CanEdit` is false for them; the importer can only delete them locally (`ex:RemoveImported(id)`). Task 16 fills this set; until then it is empty.
  - `ex:Status(rec) -> "online" | "offline" | "unknown", charToContact`
  - `ex:Contact(rec)`:
    - online → `compat:OpenChat("/w " .. char .. " " .. Format.Whisper(...))`
    - offline with the mailbox open → `compat:FillSendMail(...)`
    - offline away from a mailbox → `MailDrafts:Add(...)`, returning `"drafted"`
    - unknown → whisper
  - `ex:DiscordText(id) -> string`
  - `ex:Start()`: purges, then calls `sync:Start()`
  - `ex:OnMailShow()`: returns the next draft, if any, for the UI to offer
  - Also: `ns.RegisterModule("Exchange", { OnLogin = ..., tab = { title = "Exchange", build = Board.Build }, settings = { build = ... } })`

- [ ] **Step 1: Write failing tests** (two Exchange instances on a fake guild bus):
  - `post on A appears on B with create log entry relayed by A`
  - `Post refuses on trial account`
  - `Post refuses before consent`
  - `List mine includes listings from linked alts`
  - `Contact whispers online alt of owner`
  - `Contact drafts mail when owner offline and no mailbox`
  - `Contact fills mail when mailbox open`
  - `officer remove logged as officer-remove`
  - `expired listings are hidden and purged on Start`
  - `imported records appear in List all but not mine, and are never sent` (seed the imported set directly; assert the fake bus saw no REC for them)
- [ ] **Step 2: Run** `tools/check.sh`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tools/check.sh`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(exchange): module actions, sync and audit logging`

### Task 13: Core UI shell and Boot

**Files:**
- Create: `Guildhall/Core/UI/Window.lua`, `CopyBox.lua`, `Launcher.lua`, `LogView.lua`, `SettingsView.lua`, `Consent.lua`, `Guildhall/Core/Boot.lua`, `docs/testing/in-game-checklist.md`

**Interfaces:**
- Consumes: the module registry (`tab.build(parent)`, `settings.build(parent)`), `ns.Theme`, `ns.Log`, `ns.Profile`
- Produces:
  - `ns.UI.Window:Show(tabName?)`, `:Toggle()`, `:Refresh()`
  - `ns.UI.CopyBox:Show(title, text)`: a multiline edit box with the text highlighted and focused, and the hint "Press Ctrl+C to copy"
  - `ns.UI.CopyBox:Paste(title, onSubmit(text))`: the same box, empty and editable, with the hint "Press Ctrl+V to paste" and an OK button. Used by the Discord import (Task 16).
  - `ns.UI.Consent:Show(chars, onDone(excluded))`
  - Slash commands `/gh` and `/guildhall` (no arguments: toggle the window; `log`: open the Log tab)
  - A minimap button (draggable, saves its angle in `personal.window`)
- **Window:** a movable frame titled from `Theme.Get("title")`. Its tabs, in order: each module's tab, then **Log**, then **Settings**. It saves its position in `personal.window`.
- **LogView:**
  - a filter box (matches listing ID, profile or character)
  - a scrolling list of entries, using the `Log:Export` line format
  - an **Export** button → CopyBox
- **Boot:** a frame registered for:
  - `ADDON_LOADED`: `DB.Init(GuildhallDB)`
  - `PLAYER_LOGIN`
  - `GUILD_ROSTER_UPDATE`: `roster:Refresh()`, then UI refresh
  - `CHAT_MSG_ADDON`: `comm:Receive`
  - `MAIL_SHOW` / `MAIL_CLOSED`: `compat:SetMailboxOpen`, and on show `Exchange:OnMailShow()` → a confirmation popup "Fill in your Guildhall mail draft to X?"
  - `PLAYER_ENTERING_WORLD`
  - `ADDON_RESTRICTION_STATE_CHANGED`, if that event exists on the client (the builder confirms the name in the generated docs and otherwise polls `IsRestricted` every 5 s via `C_Timer.NewTicker`). When chat restriction lifts: `comm:Pump()`, and each module's `Start()` re-syncs.

  On login it:
  1. resolves `GuildKey`, retrying for up to 10 s because guild info loads late
  2. builds the shared services (compat, comm, log, roster, profile with set `"profiles"` and its own Sync `"core.profiles"`)
  3. calls `profile:SeeCharacter(player)`
  4. shows Consent if needed
  5. calls each module's `OnLogin(ns)`
- **Checklist:** `docs/testing/in-game-checklist.md` lists the manual checks, each tagged **[Era]** (testable on Classic Era) or **[Forever]**. It covers:
  - load with no errors
  - post, edit, renew and remove
  - a second account or a guildmate sees the listing
  - log out and back in; the listing persists
  - the offline dot
  - whisper pre-fill; mail pre-fill at a mailbox; a mail draft created away from a mailbox
  - Copy for Discord
  - the Log tab and Export
  - consent on the first alt
  - an officer removing a listing
  - item slot: shift-click from bags, from a profession window and from the auction house each load the item with its icon; drag from bags works; Clear empties it
  - another member's listing shows the right icon on their client
  - **[Forever]**: shift-clicking a *recipe* in the profession list loads the crafted item (or falls back to a typed name with no error)
  - **[Forever]**: the addon still loads with the release TOC (and the `_Vanilla` TOC is absent from the zip)
  - **[Forever]**: `/console addonChatRestrictionsForced 1`, then post → the message stays queued; set it back to 0 → it sends
  - **[Forever]**: `addonMapRestrictionsForced 1` → online dots show unknown, with no Lua errors
  - **[Forever]**: inside a dungeon, no errors
  - **[Forever]**: a trial account gets the trial message on posting

- [ ] **Step 1: Implement all the files above.** They use plain `CreateFrame` with templates that exist in both clients (`BackdropTemplate`, `UIPanelButtonTemplate`, `InputBoxTemplate`, `UIPanelScrollFrameTemplate`). Check each template name in `reference/interface-resources/` for Forever.
- [ ] **Step 2: Run** `tools/check.sh`. Expected: syntax OK and all specs PASS.
- [ ] **Step 3: Manual Classic Era test.** Copy or symlink `Guildhall/` into the Classic Era `Interface/AddOns`, `/reload`, and walk through the **[Era]** shell items in the checklist (window, tabs, Log, Settings, minimap button, slash commands, consent). The user performs this and reports back. Fix any errors they find.
- [ ] **Step 4: Commit** `feat(core): UI shell, log view, consent, boot wiring, test checklist`

### Task 14: Exchange UI (layout B)

**Files:**
- Create: `Guildhall/Modules/Exchange/UI/Board.lua`, `Guildhall/Modules/Exchange/UI/Form.lua`

**Interfaces:**
- Consumes: `ex:List/Status/Contact/DiscordText/Post/Edit/Renew/Remove/OfficerRemove`, `ns.UI.CopyBox`, `listing.CanEdit`, `roster:IsOfficer`
- Produces: `Board.Build(parent)` and `Board.Refresh()`; `Form.Open(existingRec?)`
- **Board** (matches option B in `.superpowers/brainstorm/4231-1793621056/content/board-layout.html`):
  - Sub-tabs: All, Buying (LF), Selling, Mine.
  - **Left list rows:**
    - an LF or WTS tag
    - the item text: the link shown in its quality color, with a `GameTooltip:SetHyperlink` tooltip on hover when it's a link
    - a dot: green = online, grey = offline, "?" = unknown
    - the posting character and the time left (`6d`, `5h`, `<1h`)
  - Clicking a row selects it.
  - **Right details pane:**
    - type and item
    - poster, online status and other linked characters
    - "I will / will not provide materials" and "I am open / not open to COD"
    - the note
    - posted and expiry times
    - buttons: **Whisper** (online/unknown) or **Mail** (offline), and **Copy for Discord** → CopyBox
    - **Edit**, **Renew** and **Remove** when `CanEdit`; **Remove (officer)** when the player is an officer and doesn't own the listing
  - "+ New listing" opens the Form.
  - When Contact returns `"drafted"`, show the message "Saved as a mail draft. Guildhall will offer it next time you open a mailbox."
- **Form fields:**
  - LF/WTS radio buttons
  - an **item slot**: an icon button with the item name in its quality color beside it, plus a Clear (X) button and a fallback name edit box for typing
    - **Shift-click** from bags, profession windows and the auction house: `hooksecurefunc(ChatFrameUtil, "InsertLink", fn)` (confirmed present on Forever; `ChatEdit_InsertLink` is not). While the form is shown, `fn` captures the link and loads it. Never replace the function; post-hook only, to avoid taint.
    - **Drag and drop:** the slot's `OnReceiveDrag` / `OnClick` read `GetCursorInfo()`; for `"item"` take the link, load it, then `ClearCursor()`.
    - The icon comes from `C_Item.GetItemIconByID(Util.ItemIdFromLink(link))` and quality from `C_Item.GetItemInfoInstant`. Only the link goes into `d.item`.
    - A non-item link (for example a recipe link from a profession list): resolve to the crafted item via `C_TradeSkillUI` where available (the builder checks the generated docs for the right call); otherwise put the link's plain name into the typed-name box.
    - On Classic Era, guard with `if ChatFrameUtil and ChatFrameUtil.InsertLink` and fall back to `ChatEdit_InsertLink`, so the dev TOC still works.
  - quantity
  - two toggles: "I will provide materials" and "I am open to COD"
  - a note limited to 200 characters
  - **Post** / **Save** buttons
  - Validation errors from `Listing.Validate` appear inline. The `"trial"` and `"consent"` errors get clear messages, and the consent error opens the Consent dialog.

- [ ] **Step 1: Implement Board and Form.**
- [ ] **Step 2: Run** `tools/check.sh`. Expected: syntax OK and all specs PASS.
- [ ] **Step 3: Manual Classic Era test.** The user walks through the **[Era]** Exchange items in the checklist with at least two characters (or a guildmate). Fix anything they find.
- [ ] **Step 4: Commit** `feat(exchange): board and listing form UI`

### Task 15: Forever launch verification

**Files:**
- Modify: whatever the Forever pass turns up. Also update `reference/notes/restrictions-summary.md` with confirmed behavior: the chat-lockdown rule between raid pulls, the restriction event name, and the mail frame names.

- [ ] **Step 1:** On Forever, the user runs every **[Forever]** checklist item and reports the results.
- [ ] **Step 2:** For each failure, write a failing spec where the cause is in pure logic, fix it, and run `tools/check.sh`.
- [ ] **Step 3:** Record the confirmed API behavior in `restrictions-summary.md`.
- [ ] **Step 4: Commit** `fix: forever launch verification` and tag `v0.1.0`.

### Task 16: Import from Discord (deferred until `#exchange` has real posts)

**Blocked on:** the user pasting real copied `#exchange` posts. Don't write the parser before then, and don't guess at Discord's clipboard format.

**Files:**
- Create: `Guildhall/Modules/Exchange/Import.lua`, `Guildhall/Modules/Exchange/UI/ImportPreview.lua`, `spec/fixtures/discord/*.txt` (the user's real pastes, verbatim), `spec/import_spec.lua`
- Modify: `Guildhall/Modules/Exchange/Exchange.lua` (an `ex:Import(parsed)` that writes into the local-only `"imported"` set from Task 12), `UI/Board.lua` (an **Import** button)

**Interfaces (provisional):**
- `ns.Exchange.Import.Parse(text) -> { listings = { {d = payload, poster = name}... }, unparsed = { lines... } }`. It reads the pinned format (`LF|WTS <item>[ xN]`, `I will/will not provide materials`, `I am open/not open to CoD`, optional `Note:` line). It's tolerant of case and spacing, and it skips Discord's header lines (name, timestamp) while capturing the name as `poster`.
- Lives next to `Format.lua` so the format is read and written in one place; the round-trip `Parse(Format.Discord(rec))` must give back the same fields.
- Imported records get `src = "discord"`, `poster`, posted time = import time unless the paste carries a usable date, and the normal 7-day expiry. The importer can map `poster` to an in-game character in the preview (optional), which enables Whisper/Mail.
- Re-importing the same paste doesn't create duplicates (key: poster + kind + item name).

**Open question for the user at build time:** once others run Guildhall, should imported listings be shared with them (and if so, who owns them), or stay local?

- [ ] **Step 1:** Collect fixtures from the user. Write failing specs against them, plus the round-trip spec.
- [ ] **Step 2:** Implement `Import.Parse`, then `ex:Import`, then the paste box (`CopyBox:Paste`) → preview → confirm flow.
- [ ] **Step 3:** Run `tools/check.sh`, then the user tests it in-game with a real paste.
- [ ] **Step 4: Commit** `feat(exchange): import listings from Discord paste`
