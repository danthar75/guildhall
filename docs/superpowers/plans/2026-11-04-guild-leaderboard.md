# Guild Leaderboard v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A core guild leaderboard showing verified Exchange deals and guild bank donations, with:
- per-activity boards and an overall board with weighted points
- per-guild weights
- frozen monthly top-5 records
- totals-only visibility for members

It is built so the coming contests module can reuse its query layer.

**Architecture:**
- **Observations.** Clients publish *observations* (one client's report of a trade, a CoD mail, a bank log entry, a listing witness or a manual deal) into a new replicated set `core.observations`. It syncs with a new day-bucketed digest.
- **Ledger.** Turns observations into signed *contributions* through per-kind derivers registered by modules. One query function totals them over any time window and filter. The board, month records and future contests all use it.
- **Config.** Officer-authored records for weights and month results live in a small set, `core.config`.
- **UI.** A Leaderboard tab plus a Settings section, reading only from the Ledger and Scoring.

**Tech Stack:**
- Lua 5.1 (WoW addon), tested with busted under `.tools/lua`
- Run `bash tools/check.sh`, which does `luac -p` plus busted
- Existing core: ReplicatedSet, Sync, Comm, Profile, Roster, Log, UI helpers

**Spec:** `docs/superpowers/specs/2026-11-04-guild-leaderboard-design.md`. Parent design: `docs/superpowers/specs/2026-11-02-guildhall-exchange-design.md`.

## Global Constraints

- Targets:
  - Forever TOC 16001, a Mainline API with secret values. Every value read from the game goes through `Compat:Safe`. A secret value means "unknown, skip": never compare, index or store it.
  - Classic Era 1.15.9 (dev TOC `Guildhall_Vanilla.toc`). Every API has a nil-safe fallback.
- Guildhall never calls a restricted or action API, and never sends gold, items or mail on its own. Hooks are post-hooks only (`hooksecurefunc`).
- Every UI script handler goes through `UI.Try`. Every event handler runs inside pcall (Boot already does this).
- New named globals are documented in the file header. New files go in **both** TOCs (`Guildhall/Guildhall.toc` and `Guildhall/Guildhall_Vanilla.toc`), in the same order.
- Credit goes to the **profile**, never the character. A character's activity is credited only if it is a linked (included) character of a consenting profile. Everything else counts toward the guild total only.
- Deals count only when matched to a Guildhall listing and **paired**: observations from both profiles. Self-deals (same profile) never count.
- Verification levels: `paired`, `confirmed` (reserved), `self` (shown, never ranked or totalled).
- Observation retention is 400 days (`exp = t + 34560000`). Month records never expire.
- Default weights:

  | Activity | Weight |
  |---|---|
  | listings posted | 1 |
  | sales | 5 |
  | purchases | 5 |
  | gold earned | 0.1 per gold |
  | gold paid | 0.1 per gold |
  | bank gold | 0.2 per gold |
  | bank items | 0.05 per item |

  A weight of 0 removes an activity from Overall but keeps its board.
- Pairing windows: trade 15 min (900 s); CoD 30 days (2592000 s). A listing matches if it is active, or was removed or expired ≤ 48 h (172800 s) ago. A witness needs the listing to be ≥ 24 h (86400 s) old. Manual deals wait for confirmation for 14 days (1209600 s).
- Visibility:
  - Everyone sees totals only.
  - A player sees their own breakdown.
  - Officers (`Roster:IsOfficer`, the `[Guildhall officers=N]` threshold) see every breakdown.
  - In the Log tab, non-officers see observation entries only as counts.
- Guild Info tags:
  - `[Guildhall donations=3,4]`: only these tabs count; no tag means all tabs.
  - `[Guildhall bankexclude=0,1]`: rank indexes whose deposits never count.
  - Several tags may be present, and their keys merge.
- Month records:
  - Saved by an officer client at the first login more than 3 days (259200 s) after month end.
  - The first accepted record wins. An officer can retake a month deliberately; it asks for confirmation and logs an entry, and in that case the newest version wins.
  - They hold the overall top 5, the top 5 per activity, gold kept and the weights used.
  - A player who opts out later shows as "(hidden)".
- Weight changes rescore every live period. Saved month records never change.
- Copy is plain language, with no internal ids. Names display without the realm (`Util.DisplayName`).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and use the repo's no-reply author email (already configured).

## Rulings made while planning (spec silent or ambiguous)

- **Period boundaries use the guild's server time (user).**
  - All stored times stay UTC epoch seconds (`GetServerTime()`). Only period boundaries are shifted.
  - **Month:** a calendar month on the server clock. The offset is `serverOffset = C_DateAndTime.GetServerTimeLocal() - GetServerTime()`, rounded to 15 minutes.
  - **Week:** starts at the client's weekly reset. That is `now + C_DateAndTime.GetSecondsUntilWeeklyReset() - 604800`, rounded to the hour.
  - **One source of truth (my call):** the weights config record carries `d.tz = serverOffset`, stamped by the officer client that publishes or refreshes it. Every client uses the record's `tz` once one exists, so all clients agree on month edges even if one client's clock API differs. Each month record also stores its own `from` and `to`, so it is self-describing.
  - **Fallback order:** record `tz`, then the local `GetServerTimeLocal` offset, then 0 (UTC). For the week: the reset API, then Tuesday 15:00 UTC.
  - *Cost if wrong:* a DST change moves the offset by an hour. Officers' clients refresh `tz` on login when it differs by ≥ 15 minutes, so month edges follow the server's clock change within a login.
- **Bank merge tolerance.** The game reports "N hours ago", so two readers can compute `approxAt` hours that differ by one. Readings match if all other fields are equal and their hour buckets differ by ≤ 1, matched greedily one-to-one, oldest first. *Cost if wrong:* rare double counts or missed pairs near hour edges.
- **Opt-out syncs.** It is stored on the profile record as `d.hidden = true`, so every client hides the same people. It is account-wide (`personal.profile.hidden`).
- **Demo data never leaves the client.** `/gh lbdemo` builds fake observations in memory only: never stored, never synced. The tab shows a "Demo data" banner until `/gh lbdemo off` or `/reload`.
- **Modules can declare events.** The module registry gains an optional `def.events = { EVENT = fn(ns, ...) }`. Boot registers those events and calls the handlers (pcall'd, only after boot and while not halted). This keeps trade, mail and bank wiring out of Boot.
- **One list of syncs.** Boot keeps a list of syncs, `ns.services.syncs`. Modules append to it, and restriction lifts and halts iterate it. This replaces the special-cased `ns.exchange.sync`.
- **Tab order.** The Leaderboard module file loads after the Exchange files in both TOCs. Tabs therefore read Exchange, Leaderboard, Log, Settings.

## Review Focus

1. **Secret values in trade, mail and bank reads inside instances or restricted states.** Expected behaviour: the observation is skipped, with no Lua error and no partial record. Owned by Tasks 5, 6 and 8, each with a test that feeds a secret value.
2. **A character renamed, or not yet in the roster cache, when resolving credit.** Expected behaviour: it goes to the guild total only and isn't ranked, with no error. Owned by Task 3 (`Ledger` credit resolution test).
3. **Clock skew between clients** (observation `t` up to `maxFuture` ahead) near period and month boundaries. Expected behaviour: the observation counts in the period of its own `at`, and a future `at` beyond 24 h is rejected. Owned by Task 2 (validation test) and Task 4 (boundary test).
4. **Huge guilds.** 5,000 observations must not flood Comm at login. Expected behaviour: a login sends one DAYS message of about 400 day hashes; only differing days exchange ids. Owned by Task 1 (message-count test).
5. **A weight record from a demoted officer** (their rank changed after publishing). Expected behaviour: weights stay as the last version from someone who was an officer when it arrived; nothing resets. Owned by Task 9 (test).

---

### Task 1: Day-bucketed sync for large sets

**Files:**
- Modify: `Guildhall/Core/Sync.lua`
- Modify: `Guildhall/Core/Util.lua` (add `Util.Hash`)
- Test: `spec/sync_spec.lua`, `spec/util_spec.lua`

**Interfaces:**
- Produces:
  - `Util.Hash(s: string) -> integer`. Deterministic, in [0, 2147483647), using only arithmetic: `h = (h * 31 + byte) % 2147483647` over the bytes. No `bit` library.
  - `Sync.new(opts)` takes a new optional `opts.bucket: function(rec) -> string`, the day key, e.g. `"20391"` = `floor(at / 86400)`.
    - With a bucket function, `Start()` sends one `DAYS {h = {[day] = hash}}` message instead of paged REQs. The day hash is `Util.Hash` of the sorted concatenation of `id .. ":" .. v .. ":" .. t .. ";"` for that day's live records.
    - On receiving DAYS, a peer compares hashes. For each differing or missing day it sends one `REQ {have = digest of those days, days = {day,...}}`. One REQ may cover several days, and it pages by `PAGE` ids like today.
    - A peer receiving a REQ with `days` answers with the records it has in those days that the sender lacks (the existing `Missing` logic, filtered by day). If the sender's `have` lists newer versions this peer lacks, it also sends its own REQ for those days, once per day per `minInterval`.
  - With no `bucket`, behaviour and wire format stay byte-for-byte unchanged: listings and profiles keep today's protocol.

- [ ] **Step 1: Write failing tests**

In `spec/util_spec.lua`:
```lua
it("Hash is deterministic and spreads", function()
  assert.equal(U.Hash("abc"), U.Hash("abc"))
  assert.are_not.equal(U.Hash("abc"), U.Hash("abd"))
  assert.is_true(U.Hash(string.rep("z", 500)) < 2147483647)
end)
```
In `spec/sync_spec.lua`, a new `describe("day buckets")`, using the existing two-member bus helper. Each member's set is built with `bucket = function(r) return tostring(math.floor(r.d.at / 86400)) end`:
- `"login sends one DAYS message and no REQ when in step"`: both members have the same 300 records across 30 days. After `Start()`, count Comm sends of kind DAYS = 1 and REQ = 0.
- `"only differing days exchange records"`: A has one extra record on day 5. B starts. A receives B's REQ covering only day 5, and B ends with the record. No REC carries records from other days.
- `"the side that is behind catches up too"`: B has a newer version of a day-7 record. A starts. After timers run, A holds B's version.
- `"sets without bucket keep the paged REQ protocol"`: the existing paged-digest assertions still pass unchanged.

- [ ] **Step 2: Run and see them fail.** `bash tools/check.sh`. Expected: the new specs fail (no `Util.Hash`, no DAYS).
- [ ] **Step 3: Implement `Util.Hash`, then the DAYS/REQ-days flow in `Sync.lua`.** Keep `MIN_INTERVAL` rate limiting on `Start()`. Register the DAYS handler only when `opts.bucket` is set.
- [ ] **Step 4: Run.** `bash tools/check.sh`. Expected: all pass (242 existing plus new).
- [ ] **Step 5: Commit.** `git commit -am "Sync: day-bucketed digests for large sets"`

### Task 2: Activity registry and the observations set

**Files:**
- Create: `Guildhall/Core/Leaderboard/Activity.lua`, `Guildhall/Core/Leaderboard/Observations.lua`
- Modify: both TOCs. Add both files after `Core/Profile.lua` and before `Core/UI/Window.lua`.
- Test: `spec/activity_spec.lua`, `spec/observations_spec.lua`

**Interfaces:**
- Produces, in `ns.Activity`:
  - `Activity.Register(def)`, where `def` is `{ id: string, label: string, unit: "count"|"gold"|"items", verify: "paired"|"confirmed"|"self", weight: number, order: number }`. Errors on a duplicate id. Gold values are in copper; the weight is per gold, so points = copper / 10000 × weight.
  - `Activity.Types() -> array` of defs, sorted by `order`, then `id`.
  - `Activity.Get(id) -> def|nil`.
  - `Activity.RegisterDeriver(kind: string, fn)`. The deriver signature is `fn(obsList, ctx) -> array of Contribution`. `ctx` is defined in Task 3.
  - `Activity.Deriver(kind) -> fn|nil`.
- Produces, in `ns.Observations`:
  - `Observations.KINDS = { trade=true, cod=true, manual=true, witness=true, bank=true }`. Modules may add kinds with `Observations.AddKind(kind)`.
  - `Observations.Validate(d) -> ok, err`:
    - `d.kind` is a known kind
    - `d.at` is an integer
    - every string field is ≤ 64 bytes
    - every number is a finite integer
    - there are no nested tables except `d.items` (an array of `{id=int, n=int}` with at most 6 entries)
  - `Observations.New(ctx) -> obj`, with `ctx = services` (Boot's) plus `ctx.db`. It creates the ReplicatedSet `core.observations` over `g.sets.observations` with `maxFuture = 86400`, and the Sync with the Task 1 bucket `floor(d.at / 86400)`. It appends the sync to `services.syncs`.
  - `obj:Publish(d) -> status, rec`. The id is `profileId .. ":o" .. counter`, `exp = now + 34560000`, and it applies Profile's excluded-character gate the same way as `Ex:_gate`, without consent.
  - `obj:List(kind?) -> array` of live records.
  - Incoming validation:
    - `rec.by` must be the profile that owns `rec.char` (`profile:OwnerOf`) when that is known
    - the payload must pass `Validate`
    - `d.at` must not be more than 86400 s ahead of now

  Log entries use set name `core.observations` and action `observe`.

- [ ] **Step 1: Failing tests.** In `activity_spec`:
  - "Register rejects duplicates"
  - "Types sorts by order then id"
  - "Deriver round-trips"

  In `observations_spec`:
  - "Validate accepts a trade payload"
  - "rejects unknown kind, nested tables, a 65-byte string, and `items` with 7 entries"
  - "Publish refuses from an excluded character"
  - "incoming record with `d.at` 2 days ahead is rejected (Review Focus 3)"
  - "incoming record whose char belongs to another profile is rejected"
- [ ] **Step 2: Run, and confirm they fail.**
- [ ] **Step 3: Implement both files.** `Observations` follows the `Exchange.Create` pattern: set, sync and a `logApplied` that records `action = "observe"`, `after = { kind = d.kind }` and `detail = copy(d)`. Only officers ever see `detail`: LogView redacts it in Task 13.
- [ ] **Step 4: Run, and confirm they pass.**
- [ ] **Step 5: Commit.** "Leaderboard core: activity registry and observations set"

### Task 3: Ledger: contributions, credit and the shared query

**Files:**
- Create: `Guildhall/Core/Leaderboard/Ledger.lua`
- Modify: `Guildhall/Core/Roster.lua`: `ParseTag` merges every `[Guildhall ...]` tag in the text, and adds `Roster:ConfigList(key) -> array of integers` (it parses `"3,4"`; a number value becomes a one-element list; a missing key gives `{}`).
- Modify: `Guildhall/Core/Profile.lua`:
  - adds `Profile:SetHidden(bool)` and `Profile:IsHidden(profileId) -> bool`, which reads the synced record's `d.hidden`, or the local flag for your own id
  - `Record()` includes `d.hidden = true` when it is set
- Test: `spec/ledger_spec.lua`, `spec/roster_spec.lua`, `spec/profile_spec.lua`

**Interfaces:**
- Consumes: `Activity` (Task 2) and `Observations:List`.
- Produces:
  - A Contribution is:

    ```
    { type: activityId, profile: string|nil, char: string|nil, value: integer (signed),
      at: integer, item: integer|nil, tab: integer|nil, ref: string,
      counted: boolean, why: string|nil, net: boolean|nil }
    ```

    - `profile` is set for deals.
    - `char` is set for bank entries; they are resolved later.
    - `ref` is the id of the observation(s) behind it, for the breakdown.
    - `counted = false` with a `why` (`"unpaired"`, `"waiting for confirmation"`, `"rank excluded"`, `"tab not counted"`, `"not linked"`) still appears in breakdowns.
    - `net = true` marks a type netted per window, floored at 0. Bank gold is netted per player; bank items per player and item.
  - `Ledger.new(ctx) -> ledger`, where `ctx = { observations, profile, roster, now, activity = ns.Activity }`.
  - `ledger:Contributions() -> array`. It calls every deriver on its kind's observations, cached until the observations set or the roster changes.
  - `ledger:Query(q) -> result`, where `q = { from: int|nil, to: int|nil, types: set|nil, item: function(itemId)->bool | nil, excludeRanks: set|nil, tabs: set|nil, includeUncounted: bool|nil }`:
    - `excludeRanks` defaults to `Roster:ConfigList("bankexclude")`.
    - `tabs` defaults to `ConfigList("donations")`; empty means all tabs.
    - It returns `{ byProfile = { [profileId] = { [type] = value } }, guild = { [type] = value }, goldKept = copper, rows = array of Contribution (only when includeUncounted) }`.
  - **Credit resolution.** A `char` becomes a profile only if `profile:OwnerOf(char)` returns a profile whose record includes that char. Otherwise the contribution counts in `guild` only. Rank exclusion uses `roster:RankIndex(char)`; an unknown rank is not excluded.
  - **Gold kept** = paired deal gold (counted once per deal) + net bank gold, all players included, hidden players too.

- [ ] **Step 1: Failing tests.**

  `roster_spec`: "ParseTag merges two tags; ConfigList parses lists".
  ```lua
  local t = Roster.ParseTag("[Guildhall officers=3] notes [Guildhall donations=3,4 bankexclude=0]")
  assert.equal(3, t.officers); assert.equal("3,4", t.donations)
  -- roster with that guild text:
  assert.same({3, 4}, r:ConfigList("donations")); assert.same({0}, r:ConfigList("bankexclude")); assert.same({}, r:ConfigList("nope"))
  ```

  `ledger_spec`, with fake derivers registered in the spec:
  - "Query sums by profile and type inside [from, to)"
  - "net types floor at 0 per player per window": deposit 100, withdraw 150, then gold = 0; an item deposit of 5 and withdrawal of 2 gives 3.
  - "net is per item id"
  - "excluded rank and uncounted tab go to rows with why and not to totals"
  - "unlinked char counts in guild only (Review Focus 2)", covering both an unknown char and an excluded alt
  - "hidden profile still counts in goldKept"
  - "item filter limits to matching items" (contest readiness)

  `profile_spec`: "Record carries hidden; IsHidden reads peers' records".
- [ ] **Step 2: Run, and confirm they fail.**
- [ ] **Step 3: Implement.** Netting is applied inside `Query` after window filtering, never at storage.
- [ ] **Step 4: Run, and confirm they pass.**
- [ ] **Step 5: Commit.** "Leaderboard core: ledger query, credit resolution, bank tags"

### Task 4: Scoring, periods and visibility rules

**Files:**
- Create: `Guildhall/Core/Leaderboard/Scoring.lua`
- Test: `spec/scoring_spec.lua`

**Interfaces:**
- Consumes: `ledger:Query` (Task 3), `Activity.Types`, and a `weights` table (Task 9; tests pass a plain table).
- Produces:
  - `Scoring.Period(key: "week"|"month"|"all", now, clock) -> from, to`. `clock = { tz: seconds, weekStart: epoch|nil }`, built by `Scoring.Clock(cfg, compat, now)` following the ruling's fallback order:
    - Week starts at `clock.weekStart`, or Tuesday 15:00 UTC when that is nil.
    - Month is the calendar month of `t + tz`.
    - `all` = `now - 34560000`, `now + 1`.
  - `Scoring.MonthRange(ym: "2026-11", tz) -> from, to` (epoch UTC), and `Scoring.MonthKey(t, tz) -> "YYYY-MM"`.
  - `Compat:ServerOffset() -> seconds|nil` and `Compat:SecondsUntilWeeklyReset() -> seconds|nil`, with nil when the API is missing or secret.
  - `Scoring.Points(totalsForProfile, weights) -> number`: sums `value × weight` over types, with gold types converting copper to gold first; `self` types are skipped. It rounds to 1 decimal for display only.
  - `Scoring.Board(result, board: "overall"|activityId, weights, opts) -> array of { profile, value, rank }`:
    - Sorted descending; equal values share a rank; ties are ordered by profile id.
    - Hidden profiles (`opts.isHidden(profile)`) are excluded.
    - Profiles with value ≤ 0 are excluded.
  - `Scoring.CanSeeBreakdown(viewerProfile, targetProfile, viewerIsOfficer) -> bool`.
  - `Scoring.Breakdown(ledger, profile, from, to, weights) -> { lines = { {type, value, weight, points} }, total, items = { [type] = rows }, notCounted = rows }`.

- [ ] **Step 1: Failing tests.**
  - "with no reset API the week starts Tuesday 15:00 UTC": 2026-11-03 14:59:59 UTC is in the previous week, and 15:00:00 starts a new one.
  - "the week starts at the reset API's time when present"
  - "month edges follow tz": with tz = -28800 (UTC-8), 2026-11-01 07:59:59 UTC counts in October, and 08:00:00 counts in November (Review Focus 3)
  - "Clock prefers the record's tz over the local offset, then falls back to 0"
  - "Points converts copper and applies weights": 340 g earned at 0.1 gives 34.
  - "weight 0 drops a type from overall but not from its own board"
  - "ties share a rank"
  - "hidden and zero profiles are not ranked"
  - "CanSeeBreakdown: self yes, officer yes, other no"
- [ ] **Step 2: Fail. Step 3: Implement** with pure arithmetic from the epoch. Shift by `tz` first, then `date("!*t", t + tz)` gives the year and month. Never use local-time functions. **Step 4: Pass. Step 5: Commit** "Leaderboard core: scoring, UTC periods, visibility".

### Task 5: Exchange deal matching and the trade window

**Files:**
- Create:
  - `Guildhall/Modules/Exchange/Deals.lua`: pure matching, activity and deriver registration
  - `Guildhall/Modules/Exchange/DealWatch.lua`: event and hook wiring
- Modify:
  - both TOCs: after `Exchange.lua`
  - `Guildhall/Core/Compat.lua`: add `Compat:TradeSnapshot()` and `Compat:TradePartner()`
- Test: `spec/deals_spec.lua`, `spec/compat_spec.lua`

**Interfaces:**
- Produces:
  - **Activity types** (registered at load, in `ns.Activity`). Weights are the global defaults.

    | Id | Unit | Order |
    |---|---|---|
    | `exchange.listings` | count | 10 |
    | `exchange.sales` | count | 20 |
    | `exchange.purchases` | count | 30 |
    | `exchange.gold.earned` | gold | 40 |
    | `exchange.gold.paid` | gold | 50 |

  - `Compat:TradeSnapshot() -> { give = { {id, n} }, get = { {id, n} }, giveCopper, getCopper } | nil`. It reads `GetTradePlayerItemLink` / `GetTradePlayerItemInfo` for slots 1–6, the target equivalents, and `GetPlayerTradeMoney` / `GetTargetTradeMoney`. It returns nil if any value is secret (Review Focus 1).
  - `Compat:TradePartner() -> fullName|nil`, from `UnitName("NPC")` normalised with `Util.FullName`.
  - `Deals.Match(transfer, listings, ctx) -> listingRec|nil`. `transfer = { me, partner (profile ids), give, get, giveCopper, getCopper, at }`. It applies the spec's matching rules: listing window, ownership, direction and item ID. If several listings match, it picks the one with the newest `t`.
  - `Deals.Observation(kind, listing, transfer) -> d`, returning `{ kind, listing = id, seller, buyer, item, count, copper, at }`.
  - Deriver for `trade`, `cod` and `manual`. It groups by `(listing, item, count, copper)`. It pairs observations whose `rec.by` values differ and each equal seller or buyer, with `at` within 900 s for a trade, 2592000 s for CoD, or 1209600 s for manual. A pair emits sale, purchase, earned and paid contributions with `counted = true`. An unpaired observation emits the same with `counted = false` and `why = "unpaired"` (manual: `"waiting for confirmation"`).
  - DealWatch:
    - On `TRADE_ACCEPT_UPDATE` with both sides accepted, it stores the snapshot and partner.
    - On `UI_INFO_MESSAGE` with `ERR_TRADE_COMPLETE` (compare against the global `ERR_TRADE_COMPLETE` string, or `LE_GAME_ERR_TRADE_COMPLETE` when the first argument is a number), it matches and publishes.
    - On `TRADE_CLOSED`, it clears the snapshot after 1 s.
    - Events are declared through `def.events` (Task 10). Until Task 10 lands, DealWatch exposes `DealWatch.OnEvent(event, ...)` for tests.

- [ ] **Step 1: Failing tests.**
  - "WTS: item from owner, gold from partner matches"
  - "LF: reversed direction matches; wrong direction doesn't"
  - "a listing removed 47 h ago matches, and one removed 49 h ago doesn't"
  - "same-profile trade never matches"
  - "typed-name listing never matches"
  - "pairing needs both profiles; one side gives unpaired rows"
  - "trades 16 min apart don't pair"
  - "a secret trade money value gives no snapshot and no observation (Review Focus 1)"
  - "a complete trade publishes exactly one observation"
- [ ] **Step 2: Fail. Step 3: Implement. Step 4: Pass. Step 5: Commit** "Exchange: trade deal detection and pairing".

### Task 6: CoD mail deals

**Files:**
- Modify: `Guildhall/Modules/Exchange/DealWatch.lua`, `Guildhall/Core/Compat.lua`
- Test: `spec/deals_spec.lua`

**Interfaces:**
- Produces:
  - **`Compat:SendMailSnapshot() -> { to, cod, items = { {id, n} } } | nil`.** It reads:
    - `SendMailNameEditBox` text, as the existing mail fill does
    - `GetSendMailCOD()`
    - `GetSendMailItemLink(i)` and `GetSendMailItem(i)`, for i = 1..`ATTACHMENTS_MAX_SEND` (fallback 12)

    It returns nil when the CoD is 0 or any value is secret.
  - **`Compat:InboxCod(index) -> { sender, cod, items = { {id, n} } } | nil`**, from `GetInboxHeaderInfo` (sender is return 3 and CODAmount is return 6), `GetInboxItemLink` and `GetInboxItem`.
  - **Hooks** in DealWatch, all installed with `hooksecurefunc`:
    - **Send:** take the snapshot in a `SendMail` post-hook (the send fields are still filled until the server answers), and publish only on `MAIL_SEND_SUCCESS`. If the fields turn out already cleared in the post-hook on Era, fall back to snapshotting on `SendMailMailButton` `PreClick` via `HookScript`.
    - `TakeInboxItem(index, i)` and `AutoLootMailItem(index)`: read `InboxCod(index)` in a hook. A post-hook runs after the call, so cache the inbox CoD headers on `MAIL_INBOX_UPDATE` and read the cache.
    - Publish `kind = "cod"` with `Deals.Observation`.

- [ ] **Step 1: Failing tests.**
  - "seller CoD send publishes after MAIL_SEND_SUCCESS only"
  - "a failed send (no success event) publishes nothing"
  - "buyer taking a CoD item from a cached header publishes"
  - "CoD observations 29 days apart pair; 31 days apart don't"
  - "a mail with no CoD is ignored"
  - "a secret sender is ignored"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Exchange: CoD deal detection".

### Task 7: Manual deals and listing witnesses

**Files:**
- Modify: `Guildhall/Modules/Exchange/Deals.lua`, `Guildhall/Modules/Exchange/Exchange.lua`
- Test: `spec/deals_spec.lua`, `spec/exchange_spec.lua`

**Interfaces:**
- Produces:
  - `Ex:RecordDeal(listingId, partnerProfile, count, copper) -> ok, errOrRec`. It publishes `kind = "manual"` with seller and buyer derived from the listing kind and owner. It requires partner ≠ me and needs one of the two to own the listing.
  - `Ex:PendingConfirmations() -> array of { obs, listing }`. These are manual observations naming me as the other party, unexpired (14 d) and without my matching observation.
  - `Ex:ConfirmDeal(obsId) -> ok` publishes the matching manual observation. `Ex:DeclineDeal(obsId)` stores the id in `db.declined` so it isn't asked again.
  - **Witness.** `Ex:Start()` and every listings change run `Ex:_witness()`. For each listing record ≥ 86400 s old that isn't mine, has no witness observation from any profile, and whose owner ≠ me, it publishes `{ kind = "witness", listing = id, owner = rec.by, at = rec.d.created or rec.t }`. Publishing is at most one per listing per client, and uses the existing `_gate` without consent prompts.
  - **Deriver for `witness`.** One `exchange.listings` contribution (`value = 1`) per listing, credited to `owner`, counted if any witness has `rec.by ≠ owner`. A listing that ended in a paired deal also counts once, even without a witness: dedupe by listing id.

- [ ] **Step 1: Failing tests.**
  - "RecordDeal on someone else's listing with me as partner works; a third party is refused"
  - "confirmation queue lists it for the partner only, and confirming pairs it"
  - "decline hides it"
  - "a 25 h old listing gets one witness from a non-owner; the owner's client doesn't witness"
  - "a 23 h old listing gets no witness"
  - "a listing with both a witness and a deal counts once"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Exchange: manual deals with confirmation, listing witnesses".

### Task 8: Guild bank log reader

**Files:**
- Create: `Guildhall/Core/Leaderboard/Bank.lua`
- Modify: `Guildhall/Core/Compat.lua`
- Test: `spec/bank_spec.lua`

**Interfaces:**
- Produces:
  - **Activity types:** `bank.gold` (gold, paired, weight 0.2, order 60) and `bank.items` (items, paired, weight 0.05, order 70).
  - **`Compat:BankOpen() -> bool`.** It is set by events:
    - Mainline: `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` / `_HIDE` with `Enum.PlayerInteractionType.GuildBanker`
    - Classic: `GUILDBANKFRAME_OPENED` / `_CLOSED`, when present
  - **`Compat:BankLog(tab) -> array of { type, name, item, count, tab, ago } | nil`**, from `GetNumGuildBankTransactions` and `GetGuildBankTransaction`. `ago` is in seconds, from years/months/days/hours, with month = 30 days and year = 365 days.
  - **`Compat:BankMoneyLog() -> array of { type, name, copper, ago } | nil`.**
  - Both return nil on secret values, and drop any single entry with a secret field.
  - **`Bank.new(ctx)`** with these methods:
    - **`:OnOpen()`:**
      - calls `QueryGuildBankLog(tab)` for tabs 1..`GetNumGuildBankTabs()`
      - calls `QueryGuildBankLog(MAX_GUILDBANK_TABS + 1)` for money (fallback 9)
      - starts a 60 s re-read ticker while the bank is open (contest readiness)
    - **`:OnLogUpdate()`:** reads every tab and the money log.
      - Each `deposit` or `withdraw` entry becomes an observation `{ kind = "bank", tab, type = "dep"|"wd", player = name, item = id|nil, count|copper, at = hourBucket * 3600 }`, where `hourBucket = floor((now - ago) / 3600)`.
      - Moves, repairs and buyTab are skipped.
      - Entries this client already published are skipped. Track them by a local key `(tab, type, player, item, count|copper, hourBucket, ordinal)` in `db.bankSeen`, pruned after 400 days.
  - **Deriver for `bank`:**
    - It clusters observations from different clients that describe the same log entry: all fields equal, hour buckets within ±1, matched greedily one-to-one, oldest first.
    - A cluster counts if it has observations from ≥ 2 profiles, or from one profile that isn't the depositor's owner.
    - It emits a `bank.gold` or `bank.items` contribution with `char = player`, `tab`, `item`, a signed value (withdrawals negative) and `net = true`.

- [ ] **Step 1: Failing tests.**
  - "a deposit and a withdrawal become observations; a move doesn't"
  - "re-reading the same log publishes nothing new"
  - "two identical deposits in the same hour publish 2 (ordinal)"
  - "readers at 10:20 (0 h ago) and 11:05 (0 h ago) merge into one entry (±1 bucket)"
  - "a depositor-only report is unpaired; another reader makes it counted"
  - "a secret name drops that entry only (Review Focus 1)"
  - "tab not in donations goes to rows with why 'tab not counted'" (through Ledger)
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Leaderboard core: guild bank log observations".

### Task 9: Config records: weights and month records

**Files:**
- Create: `Guildhall/Core/Leaderboard/Config.lua`
- Test: `spec/lbconfig_spec.lua`

**Interfaces:**
- Produces:
  - **`Config.new(ctx)`.** It creates the ReplicatedSet `core.config` over `g.sets.config`, with a normal (unbucketed) Sync appended to `services.syncs`. Record ids are `"weights"` and `"month:YYYY-MM"`, and `exp = now + 34560000 * 10` for month records.
  - **Incoming validation:**
    - The author char must be an officer (`roster:IsOfficer(rec.char) == true`) at arrival. An unknown roster rejects it now, and it is accepted on a later sync.
    - The payload shape must be valid.
    - For month records, a record whose id already exists is accepted only if `d.retake == true` and it is Greater.
  - **`cfg:Weights() -> { [typeId] = number }`.** It merges `Activity` defaults with the record, so types missing from the record use their defaults. Weights must be finite and in 0..1000; anything else is invalid.
  - **`cfg:PublishWeights(map) -> ok, err`.** Officers only. It stamps `d.tz = compat:ServerOffset()`.
  - **`cfg:Tz() -> seconds|nil`.** This is the record's `tz`. On an officer's login, `cfg:MaybeRefreshTz()` republishes the weights record unchanged except `tz` when the local offset differs by ≥ 900 s, or when no record exists yet and the local offset is known.
  - **`cfg:Month(ym) -> d|nil`** and **`cfg:Months() -> array`** of ym, newest first.
  - **`cfg:MaybeSaveMonth(ledger, now)`.** It runs on login for officers. For the newest finished month that has no record, once `now ≥ monthEnd + 259200`, it publishes:

    ```
    { month = ym, from, to, tz, goldKept, overall = top5, boards = { [typeId] = top5 }, weights, savedBy = myChar, savedAt = now }
    ```

    Each `top5` is an array of `{ profile, name, value, rank }`, where `name` is the profile's display char at save time.
  - **`cfg:RetakeMonth(ym, ledger) -> ok`.** Officers only. It sets `d.retake = true`, bumps the version, and the caller logs an entry.

- [ ] **Step 1: Failing tests.**
  - "a weights record from a non-officer is rejected"
  - "from an officer it is accepted, and Weights merges defaults"
  - "a demoted officer's earlier record stays in effect (Review Focus 5)"
  - "a negative or NaN weight is invalid"
  - "MaybeSaveMonth waits for the 3-day grace"
  - "a second save for the same month is ignored"
  - "a retake replaces it"
  - "a month record keeps its numbers after weights change"
  - "MaybeRefreshTz republishes only when the offset moves ≥ 15 min"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Leaderboard core: officer weights and frozen month records".

### Task 10: Wiring: module events, syncs list, the Leaderboard module

**Files:**
- Modify: `Guildhall/Core/Boot.lua`, `Guildhall/Core/Init.lua`
- Create: `Guildhall/Core/Leaderboard/Module.lua`. It goes in both TOCs after the Exchange UI files and before `Core/Boot.lua`.
- Modify: `Guildhall/Modules/Exchange/Exchange.lua` (append its sync to `services.syncs`; declare DealWatch events), `Guildhall/Modules/Exchange/DealWatch.lua`
- Test: `spec/boot_spec.lua`, `spec/init_spec.lua`

**Interfaces:**
- **Boot:**
  - `ns.services.syncs` is an array.
  - The core profile sync and every module's syncs are started at login, on restriction lift and in `Start` loops.
  - `halt` stops all of them: `comm:Halt()` already blocks sends; it also sets `ns.leaderboard = nil`.
- **Boot events:** each module's `def.events` events are registered at load, after module files load: Boot is last. They are dispatched as `fn(ns, ...)` only when booted and not halted.
- **`Module.lua`:**
  - Registers module `"Leaderboard"` with `OnLogin`, which builds `ns.leaderboard = { observations, ledger, config, bank }` from `ns.services`.
  - `OnLogin` also calls `config:MaybeSaveMonth` when the player is an officer.
  - Declares the bank events.
  - `tab = { title = "Leaderboard", build = ns.Leaderboard.View.Build }`, from Task 11.
  - `settings = { title = "Leaderboard", build = ns.Leaderboard.SettingsView.Build }`, from Task 12.

- [ ] **Step 1: Failing tests.**
  - "a module's events fire after boot and not after halt"
  - "a restriction lift starts every sync in services.syncs"
  - "the tab order is Exchange, Leaderboard, Log, Settings"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Boot: module events and a shared syncs list; register the Leaderboard module".

### Task 11: Leaderboard tab UI

**Files:**
- Create: `Guildhall/Core/Leaderboard/UI/View.lua` (both TOCs, before `Module.lua`)
- Test: `spec/lbview_spec.lua` (fake widgets, the way `form_spec` does it)

**Interfaces:**
- Consumes: `ns.leaderboard`, `Scoring`, `UI.*` helpers.
- Produces: `ns.Leaderboard.View.Build(parent) -> obj` with `obj:Refresh()`. It follows the mockup at https://claude.ai/artifact/8FViUNtVFmBFUkncwvjPqX ("Leaderboard · member view" and "your own breakdown" boards):
  - **Headline.** "Gold kept in the guild this week|this month|in the last 400 days: N g". A past month uses "in <Month YYYY>".
  - **Period buttons.** Week, Month, All time and "Past months ▾" (a `UI.PickList` of `cfg:Months()`).
  - **Board picker.** "Board: Overall ▾", then each `Activity.Types()` label.
  - **List.** Rows show rank, online dot, display name and value. Up to 11 rows are visible, with the mouse wheel scrolling. Your own row is pinned at the bottom when you aren't in view. The display name comes from `profile:OnlineChar` or the most recent char, using `Util.DisplayName`.
  - **Right pane:**
    - When you can see the breakdown (`Scoring.CanSeeBreakdown`): the breakdown table (activity, value, weight, points, total) and collapsible lists per type, plus "Not counted (n)" with its reasons.
    - Otherwise: rank, total and the line "The breakdown of a player's score is visible to that player and to officers."
  - **Past month.** The list comes from the saved record. Hidden profiles show "(hidden)". It shows "Saved <date> by <name>". Officers get a "Retake" button with a confirmation popup.
  - **Empty state.** "No verified activity yet. Deals made through Exchange listings and guild bank donations will show here."
  - **Demo banner.** "Demo data, not real. /gh lbdemo off" when demo mode is on.
- [ ] **Step 1: Failing tests.**
  - "a member clicking another row sees totals only"
  - "clicking your own row shows the breakdown"
  - "an officer sees anyone's breakdown"
  - "your row is pinned when ranked 14th"
  - "a past month shows saved values and (hidden)"
  - "an empty ledger shows the empty text"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Leaderboard tab".

### Task 12: Settings section and Exchange integration

**Files:**
- Create: `Guildhall/Core/Leaderboard/UI/SettingsView.lua` (both TOCs)
- Modify: `Guildhall/Modules/Exchange/UI/Details.lua`, `Guildhall/Modules/Exchange/UI/Board.lua`
- Test: `spec/lbsettings_spec.lua`, `spec/details_spec.lua` (create if absent)

**Interfaces:**
- **Settings** (as in the mockup's "Settings · leaderboard section"):
  - **Opt-out checkbox.** "Show me on the leaderboard" calls `profile:SetHidden(not checked)`, then `Boot.PublishProfile()`.
  - **Privacy note.** Verbatim: "When this is off, your name isn't listed, but your deals and donations still count toward the guild total. Guildhall only shows totals to members, and each breakdown only to its player and officers. The records still travel between guildmates' clients so deals can be checked, so someone reading their own SavedVariables file could see them."
  - **Officers only: a weights editor.** It lists each activity with an edit box, its default and a Reset button. A changed value shows in gold. "Publish weights" calls `cfg:PublishWeights`. The editor also shows "Last changed by X, date".
  - **Non-officers** see the weights read-only.
- **Details:**
  - A "Record a deal" button on a listing, available to its owner or to anyone when the listing isn't theirs. It opens a small panel: partner (a pick list of guild profiles' display names), quantity and gold. Submitting calls `Ex:RecordDeal`.
  - A pending confirmation appears as a line at the top of the Exchange board: "Brakka says you bought 40 Runecloth for 40g. Confirm? [Confirm] [Not me]".
  - After a paired sale of your WTS listing, the board shows once: "Sold? [Remove listing] [Keep it up]".
- [ ] **Step 1: Failing tests.**
  - "a non-officer sees no Publish button"
  - "Publish sends the weights"
  - "unchecking publishes a hidden profile"
  - "the Record a deal payload matches the inputs"
  - "the confirm line appears for the partner only"
  - "the sold prompt shows once per deal"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Leaderboard settings, Record a deal, deal prompts".

### Task 13: Log redaction, demo data, docs and the in-game checklist

**Files:**
- Modify:
  - `Guildhall/Core/UI/LogView.lua`
  - `Guildhall/Core/UI/Launcher.lua` (`/gh lbdemo [off]`, plus the help line "/gh lbdemo - show fake leaderboard data (only on your screen)")
  - `docs/testing/in-game-checklist.md`
  - `docs/testing/forever-launch.md`
  - `README.md` (a Leaderboard feature paragraph)
- Create: `Guildhall/Core/Leaderboard/Demo.lua` (both TOCs)
- Test: `spec/logview_spec.lua` (create), `spec/demo_spec.lua`

**Interfaces:**
- **LogView.** For non-officers, consecutive `core.observations` entries collapse into one line: `"<time> | observations | received N (trade 2, bank 10)"`. Export uses the same rule. Officers see full entries, including `e.detail`.
- **`Demo.Build(now) -> observations-like store`**, with 12 fake profiles, about 60 deals, about 40 bank entries and one month record. `/gh lbdemo` swaps `ns.leaderboard.ledger` for a ledger over that store and turns on the banner; `off` restores it. Nothing is written to SavedVariables or sent (`spec`: the publish count stays 0).
- **Docs.** Add Era checks: demo mode, the tab, filters, settings. Under "Later: Leaderboard", replace the forever-launch items with the concrete steps for each Forever test.
- [ ] **Step 1: Failing tests.**
  - "a non-officer export has no payload fields"
  - "an officer export does"
  - "demo mode publishes nothing and lbdemo off restores the real ledger"
- [ ] **Step 2–4: Fail, implement, pass.** **Step 5: Commit** "Leaderboard: log redaction, /gh lbdemo, docs".
