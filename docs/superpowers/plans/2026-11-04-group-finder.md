# Group Finder v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A guild-only group finder that:
- lets members post, join, schedule and fill dungeon and raid runs;
- reads raids from the in-game calendar;
- credits finished runs, verified boss kills, leadership-confirmed preparation and spec switches on the leaderboard;
- puts officer powers behind guild-rank permissions that only the guild master changes, with every change in a shared history.

**Architecture:**
- **New module.** `Guildhall/Modules/Groups/` holds three replicated sets: `groups.posts`, `groups.signups` and `groups.ready`, built on the Exchange listing pattern.
- **Observations.** Kills, preparation checks, confirmations, spec switches and calendar signups are new kinds in `core.observations`.
  - Derivers turn them into new `groups.*` activity types.
  - The Leaderboard's Ledger and Scoring then show them with no Leaderboard changes.
- **Permissions.** These are a new core file over `core.config`. Leaderboard officer checks move onto them.
- **Change history.** Every permission and checklist change is recorded in the history built by the leaderboard's Task 14.

**Tech Stack:**
- Lua 5.1 (WoW addon), tested with busted under `.tools/lua`.
- `bash tools/check.sh` runs `luac -p` and busted.
- Existing core: ReplicatedSet, Sync (including the bucketed option), Comm, Profile, Roster, Observations, Activity, Ledger, Scoring, Leaderboard Config and history, and the UI helpers.

**Spec:** `docs/superpowers/specs/2026-11-04-group-finder-design.md`, approved for v1.
- Parent specs: `docs/superpowers/specs/2026-11-04-guild-leaderboard-design.md` and `docs/superpowers/specs/2026-11-02-guildhall-exchange-design.md`.
- Mockups: https://claude.ai/artifact/8FViUNtVFmBFUkncwvjPqX, boards "Groups · dungeon post", "Groups · raid night", "New group post form" and "Settings · Permissions".

**Prerequisite:** this plan starts from `main` after `feature/leaderboard` has merged, including leaderboard Tasks 9, 10 and 14.
- Task 9 provides `core.config` and `Config`.
- Task 10 provides `def.events` and `services.syncs`.
- Task 14 provides history records.
- Branch: `feature/groups`, in the worktree `.worktrees/groups`.

## Global Constraints

### Targets
- **Forever (TOC 16001).** This is a Mainline API with secret values. Every value read from the game goes through `Compat:Safe`. A secret value means "unknown, skip": never compare it, index with it or store it.
- **Classic Era 1.15.9** (dev TOC `Guildhall_Vanilla.toc`). Every API has a nil-safe fallback.

### Code rules
- Guildhall never calls a restricted or action API. No auto-invite, and no calendar create or edit. Invites are suggestions: the player clicks the game's own invite.
- Hooks are post-hooks only.
- Every UI script handler goes through `UI.Try`.
- Event handlers are declared through `def.events`.
- New files go in **both** TOCs in the same order, after the Leaderboard files and before `Core/Boot.lua`.
- New named globals are documented in the file header.

### Credit
- Credit goes to the **profile**: a character counts only as a linked, included character of a consenting profile.
- Non-guild members and non-users earn nothing and are never stored beyond the kill's member list.
- **A finished dungeon** means a verified kill of the **last boss** of that dungeon or wing.
- **Guild majority:** a kill counts only if guild members are more than half of the group's members in the snapshot. That is 3 of 5, or 21 of 40.
- **Verified** means two different profiles report the same instance and encounter, with `at` within 600 s and overlapping member lists.
- **Repeat runs:** `groups.dungeon` counts once per dungeon (or wing) per player per server day. There is no level limit. The limit applies when the ledger derives credit; raw kills are all kept.
- **Raids:**
  - Each verified boss kill counts.
  - A full clear counts once per lockout week: every boss in the instance table killed within one weekly reset period.
  - Attendance needs no signup.
- **Calendar window:** an event is linked to verified kills from start − 1800 s to start + 21600 s.
- **Flex:** a spec switch counts when it lands within 900 s of the request.
- **Expiry:**
  - A Now post expires 7200 s after it is created.
  - A scheduled post expires 21600 s after its start.
  - A "Ready now" record lasts its "free for" window: default 7200 s, maximum 21600 s.
  - Observations keep leaderboard retention: 400 days.
  - History is kept for 2 years, so history records carry `exp = at + 63072000`. This supersedes Task 14's "never expire" for new records; the spec's retention ruling wins.

### Activity types

| id | label | unit | verify | weight | order |
|---|---|---|---|---|---|
| `groups.dungeon` | Dungeons cleared | count | paired | 5 | 80 |
| `groups.raidboss` | Raid bosses killed | count | paired | 3 | 90 |
| `groups.raidclear` | Full raid clears | count | paired | 5 | 100 |
| `groups.prepared` | Raids prepared | count | confirmed | 2 | 110 |
| `groups.flex` | Spec switches when asked | count | confirmed | 1 | 120 |
| `groups.signedup` | Signed up and showed up | count | paired | 1 | 130 |

### Permissions
- **Keys:**
  - `checklists`: edit raid checklists
  - `prepared`: confirm prepared
  - `flex`: ask for spec switches
  - `weights`: edit leaderboard weights
  - `retake`: retake a month
- **Grants:** each key grants to a set of guild rank indexes plus an optional `raidlead` flag ("the current raid leader and assistants").
- **Defaults:** each key defaults to the officer ranks (`[Guildhall officers=N]`).
- **Who can change them:** only the guild master (rank 0). A permissions record is accepted only from a char at rank 0 when it arrives.
- **Raid leader rule:** a `raidlead` grant applies only when that char is leader or assistant in a **verified** kill snapshot of the same instance on the same server day.

### Copy
- Copy is plain language with no internal ids. Names display without the realm (`Util.DisplayName`).
- All times are entered and shown in **server time** (`Scoring.Clock`).

### Commits
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Use the repo's no-reply author email.

## Rulings made while planning (spec silent or ambiguous)

- **History is written in the same call as the change.** `Config` and `Permissions` publish the change and its history record together, in one function, with no yield between them. The spec's "one record" intent is to prevent a change with no record. For honest clients, this achieves it without reworking Task 14's record shape.
  - *Cost if wrong:* a crash between the two publishes would lose one history line.
- **Who gets the full-clear credit.** Each player who was present at the kill that **completed** the set.
  - *Cost:* a raider who left before the last boss misses the bonus but keeps their boss credits.
- **Which dungeon wing a kill belongs to.** The wing is identified by its final-boss encounter id. LBRS and UBRS are separate "dungeons" even though they share instance 229.
- **Run duration** (history: "42 min") runs from the first `ENCOUNTER_START` or zone-in recorded this session for that instance, to the final kill. If neither was seen, the duration is not shown.
- **Calendar signups come from the player's own client only.** It publishes its own status, and it does so outside instances.
- **Guild membership in a snapshot** is decided by the deriving client's roster (`Roster:IsMember(name)`, added in Task 2). The reporter's own count is not trusted.
- **Post notes** are at most 120 characters. The key item is an item id, or a typed name of at most 64 characters.
- **Raid boss kills are deduplicated per lockout week**, per player and encounter. The weekly lockout allows one kill per boss, so a second report (from an alt raid, or after a reset) can't double it. *Cost:* none on normal raids.
- **The leaderboard needs no change.** The new types appear on its board picker automatically, through `Activity.Types()`.

## Review Focus

1. **Secret or unreadable group members inside an instance on Forever.**
   - *Expected:* secret names are left out of the snapshot. If fewer than 2 names are readable, no kill observation is published. There is no Lua error.
   - *Owner:* Task 4, test "a snapshot with secret names publishes only readable members, or nothing".
2. **A run that crosses server midnight, or the same dungeon twice in a day.**
   - *Expected:* credit is once per server day, keyed by the kill's own `at` in server time. A clear at 23:50 and another at 00:10 earn 2. Two clears at 14:00 and 18:00 earn 1.
   - *Owner:* Task 5, test "two clears either side of server midnight count 2; two in one day count 1".
3. **Members leaving or joining mid-run, so the majority changes.**
   - *Expected:* the majority and credit use the snapshot taken at the counted kill only.
   - *Owner:* Task 5, test "2 guild + 3 pugs at the last boss gives no credit even if 4 guild started".
4. **A scheduled post read by clients in different time zones.**
   - *Expected:* the start is stored as UTC epoch, entered and displayed in server time. The reminder fires 900 s before the real start on every client.
   - *Owner:* Task 9, test "a post at 20:00 server time reminds at 19:45 server time with a local offset of +3 h".
5. **A permissions record from someone who was guild master and has since lost rank 0, or one that arrives before the roster has loaded.**
   - *Expected:* with an unknown roster, reject the record now and accept it on a later sync. An earlier accepted record stays in effect. A new guild master's newer record replaces it.
   - *Owner:* Task 1, test "permissions from a former GM stay; a new GM's record replaces them; unknown roster defers".

---

### Task 1: Core permissions and their history

**Files:**
- Create `Guildhall/Core/Permissions.lua` (both TOCs, after `Core/Leaderboard/Config.lua`).
- Modify:
  - `Guildhall/Core/Leaderboard/Config.lua` (permission checks replace `IsOfficer` for weights and retake; history `what` gains `"perms"` and `"checklist"`; history `exp`)
  - `Guildhall/Core/Roster.lua` (`Roster:RankNames()`)
  - `Guildhall/Core/Compat.lua` (`Compat:GuildRanks()`)
- Test: `spec/permissions_spec.lua`, plus updates to `spec/lbconfig_spec.lua`.

**Interfaces:**
- **Consumes:**
  - `core.config` from Config: `cfg.set`, the history writer `cfg:_history(what, key, before, after)` (rename to this if Task 14 named it differently, and keep one writer).
  - `Roster:RankIndex`, `Roster:OfficerThreshold`.
- **Produces:**
  - `Compat:GuildRanks() -> array of names | nil`, using `GuildControlGetNumRanks` and `GuildControlGetRankName(i)`. Index 1 is rank 0. A secret value gives nil.
  - `Roster:RankNames() -> array`. Falls back to the names seen in the roster cache.
  - `Permissions.KEYS = { "checklists", "prepared", "flex", "weights", "retake" }`, with labels:
    - "Edit raid checklists"
    - "Confirm prepared"
    - "Ask for spec switches"
    - "Edit leaderboard weights"
    - "Retake a month"
  - `Permissions.new(ctx) -> perms`. `ctx` holds `config`, `roster`, `profile`, `now` and `compat`.
  - `perms:Grants(key) -> { ranks = { [rankIndex] = true }, raidlead = bool }`. Defaults to the officer ranks with `raidlead = false`.
  - `perms:Can(char, key, opts) -> bool`.
    - True if the char's rank is in the grant.
    - Also true if the grant has `raidlead`, `opts.raidLeaders` is given and it contains the char.
    - An unknown rank gives false.
  - `perms:Publish(map) -> ok, err`.
    - Only allowed when I'm rank 0; otherwise it returns `false, "Only the guild master can change permissions."`.
    - Writes record id `"perms"`.
    - Writes a history entry with `what = "perms"` in the same call.
  - Incoming `"perms"` record: accepted only if `roster:RankIndex(rec.char) == 0` when it arrives.
    - If the roster is unknown, reject it now (it is retried on sync).
    - Within that rule, a newer version wins.
  - `cfg:PublishWeights` and `cfg:RetakeMonth` now check `perms:Can(myChar, "weights" | "retake")`.
  - Incoming weights and month records are checked with `perms:Can(rec.char, ...)` when they arrive. Before any perms record exists, the defaults keep today's officer rule.

- [ ] **Step 1: Failing tests.**
  - "defaults grant officer ranks only"
  - "a perms record from rank 1 is rejected; from rank 0 accepted"
  - "permissions from a former GM stay; a new GM's record replaces them; unknown roster defers" (Review Focus 5)
  - "Can honours raidlead only with a matching raidLeaders set"
  - "Publish writes one history entry what=perms with before and after"
  - "a weights publish by a rank now granted 'weights' is accepted; by an officer whose rank was removed is rejected"
  - "history records carry exp = at + 63072000"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass (`bash tools/check.sh`).
- [ ] **Step 5:** commit "Core: guild-rank permissions with change history".

### Task 2: Instance table and group Compat reads

**Files:**
- Create `Guildhall/Modules/Groups/Instances.lua`.
- Modify `Guildhall/Core/Compat.lua` and `Guildhall/Core/Roster.lua` (`Roster:IsMember(name)`).
- Test: `spec/instances_spec.lua` and `spec/compat_spec.lua`.

**Interfaces:**
- **Produces:**
  - `Instances.LIST`, an array of instance entries, each:

    ```
    { key, name, short, kind = "dungeon"|"raid", size, instanceId, bosses = { encounterIds... }, final = encounterId }
    ```

  - **Dungeon entries.** There is one entry per wing. Example: `key = "strat_ud"`, name "Stratholme (Undead)", short "Strat UD". Every Era 5-player dungeon is covered, with these wings:
    - Dire Maul: East, West and North
    - Stratholme: Live and Undead
    - Scarlet Monastery: Graveyard, Library, Armory and Cathedral
    - Blackrock: LBRS and UBRS
  - **Raid entries.** Each one lists all its bosses. The raids are MC, Onyxia, BWL, ZG, AQ20, AQ40 and Naxx.
  - **Where the ids come from.** Encounter ids come from the DungeonEncounter DB2 for build 1.15.x (wago.tools). Record the source URL and build in the file header. Spot values the tests assert:
    - MC Ragnaros is 672
    - MC Lucifron is 663
    - Onyxia is 1084
  - `Instances.Get(key)`, `Instances.ByEncounter(encounterId) -> entry, isFinal`, and `Instances.ForPicker(kind) -> array`. `ForPicker` sorts dungeons by name and raids by tier.
  - `Compat:GroupSnapshot() -> { members = { fullName... }, leader = fullName|nil, assists = { fullName... }, size } | nil`.
    - Reads `IsInRaid`, `GetNumGroupMembers`, `UnitName` and `GetRaidRosterInfo` (rank 2 is leader, 1 is assistant), or `UnitIsGroupLeader` in a party.
    - Leaves out secret or nil names.
    - Normalises names to `Name-Realm`.
    - Returns nil when fewer than 2 names are readable.
  - `Compat:InstanceKey() -> instanceId|nil`, from `GetInstanceInfo()` return 8. A secret value gives nil.
  - `Compat:ActiveSpecGroup() -> 1|2|nil`, from `GetActiveTalentGroup` or `C_SpecializationInfo.GetActiveSpecGroup`. When neither exists, it returns nil, which means no dual spec.
  - `Compat:ItemCount(itemId) -> n|nil`, from `GetItemCount` or `C_Item.GetItemCount`.
  - `Compat:UnenchantedSlots() -> array of slot names | nil`.
    - Scans `GetInventoryItemLink("player", slot)` for these slots: Head 1, Shoulder 3, Chest 5, Legs 7, Feet 8, Wrist 9, Hands 10, Back 15, Main hand 16, Off hand 17.
    - Slot 17 counts only when it holds a weapon or shield (`GetItemInfoInstant` class 2, or armor subclass 6).
    - The enchant id is the third `:` field of `item:`. 0 or empty means unenchanted.
    - An empty slot is skipped.
  - `Roster:IsMember(name) -> bool|nil`. Returns nil while the roster is unknown.

- [ ] **Step 1: Failing tests.**
  - "every entry has final in bosses and a unique key"
  - "ByEncounter(672) is MC, not final for dungeons; a dungeon final returns isFinal"
  - "a snapshot with secret names publishes only readable members, or nothing" (Review Focus 1)
  - "leader and assists read from raid rank"
  - "UnenchantedSlots finds 'Legs' for item:123:0 and skips an empty off hand"
  - "ActiveSpecGroup is nil without dual spec"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: instance table and group reads".

### Task 3: Posts, signups and Ready now

**Files:**
- Create `Guildhall/Modules/Groups/Post.lua` and `Guildhall/Modules/Groups/Groups.lua`, the service.
- Test: `spec/groups_spec.lua`.

**Interfaces:**
- **Consumes:** the ReplicatedSet and Sync patterns from `Modules/Exchange/Exchange.lua` and `Listing.lua`, and `Instances`.
- **Produces:**
  - **`Post.Validate(d)`.** A post payload has:
    - `instance`: a key from `Instances`
    - `role`: `"t"`, `"h"` or `"d"`
    - `need = { t, h, d }`: integers from 0 to 39. The sum plus 1 must be ≤ the instance size.
    - `start`: nil for Now, otherwise an integer epoch
    - `note`: ≤ 120 characters
    - `want`: an item id integer or a name ≤ 64 characters, or nil
    - `assign`: `{ [profileId] = "t"|"h"|"d" }`, or nil
    - `created`
  - **`Post.New(d, profileId, char, now, n)`.** The id is `profileId:g<n>`. `exp` is `created + 7200` for a Now post and `start + 21600` for a scheduled one.
  - **`Post.CheckIncoming`.** It mirrors `Listing.CheckIncoming`. The id prefix must equal `rec.by`, and only the owner may edit.
  - **`Groups.Create(ctx) -> svc`.** It builds three sets.
    - The sets are `groups.posts`, `groups.signups` and `groups.ready`.
    - Each has an unbucketed Sync appended to `ctx.syncs`.
  - **Posts:**
    - `svc:Post(d) -> ok, recOrErr`
    - `svc:Close(id)`
    - `svc:Assign(postId, profileId, role)`, poster only
    - `svc:Posts() -> array`, sorted with Now posts first (by created, newest first), then scheduled posts by start
  - **Signups:**
    - `svc:SignUp(postId, roles) -> ok`. `roles` is a set of at least one of t, h, d. The record id is `postId .. "|" .. myProfile`.
    - `svc:Withdraw(postId)` sets `d.withdrawn = true`.
    - `svc:Signups(postId) -> array` of `{ profile, roles, withdrawn, at }`.
  - **Ready now:**
    - `svc:SetReady(roles, level, forSeconds)` and `svc:ClearReady()`. The record id is my profile, and `exp = now + forSeconds`.
    - `svc:Ready() -> array`, excluding expired records.
  - **`svc:Filled(post) -> { t = {profiles}, h = {...}, d = {...}, open = {t, h, d} }`.**
    - The poster fills their own role.
    - Each `assign` entry fills its role.
    - Open slots equal `need` minus assigned.
  - **Change hook:** `ctx.onChange` fires on any set change, debounced through `ctx.after(1)` when it is present.

- [ ] **Step 1: Failing tests.**
  - "a Now post expires after 2 h, a scheduled one 6 h after start"
  - "need larger than the instance size is invalid"
  - "a post whose id prefix isn't its author is rejected"
  - "signup with healer or DPS lists both roles; withdraw hides it"
  - "assign fills a slot and reduces open"
  - "Ready now expires after its window; clamped to 6 h"
  - "Posts orders Now first then scheduled by start"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: posts, signups and Ready now".

### Task 4: Kill watch

**Files:**
- Create `Guildhall/Modules/Groups/KillWatch.lua`.
- Modify `Guildhall/Core/Leaderboard/Observations.lua` (Validate: `members` and `assists` arrays of strings, each ≤ 64 characters with at most 40 entries, plus the new kinds).
- Test: `spec/killwatch_spec.lua`.

**Interfaces:**
- **Produces:**
  - **`KillWatch.new(ctx)`.** It handles `OnEncounterStart(encounterId)`, `OnEncounterEnd(encounterId, name, difficulty, groupSize, success)`, `OnBossKill(encounterId)`, `OnZone()` and `OnSpecChanged()`. `OnSpecChanged` is used by Task 7.
  - **On a successful `ENCOUNTER_END`:**
    - The encounter id must be in `Instances.ByEncounter`, and `success` must be 1, read via `Safe`.
    - The client takes a `Compat:GroupSnapshot()` and publishes:

      ```
      { kind = "kill", instance = entry.key, encounter = id, members, leader, assists, dur = seconds|nil, at = now }
      ```

    - `dur` is set only for a final boss.
  - **`BOSS_KILL` fallback.** `BOSS_KILL` publishes the same observation only if no `ENCOUNTER_END` for that encounter arrived within 5 s.
  - **Duplicates.** A second report of the same encounter within 600 s from this client is skipped.
  - **`Observations.AddKind`** registers `kill`, `prepcheck`, `prepared`, `flexask`, `flexdone`, `flexok` and `signup`.

- [ ] **Step 1: Failing tests.**
  - "a successful final-boss ENCOUNTER_END publishes one kill with members and dur"
  - "a wipe (success 0) publishes nothing"
  - "BOSS_KILL alone publishes after 5 s; with ENCOUNTER_END it doesn't double"
  - "members over 40 or a name over 64 chars is invalid"
  - "an unknown encounter publishes nothing"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: boss kill observations".

### Task 5: Kill derivers — dungeons, raid bosses and full clears

**Files:**
- Create `Guildhall/Modules/Groups/Credit.lua`.
- Modify `Guildhall/Core/Leaderboard/Scoring.lua` (add `Scoring.DayKey(at, tz) -> "YYYY-MM-DD"` and `Scoring.WeekStart(at, clock)`, using the same server-time rules as `Period`).
- Test: `spec/groupcredit_spec.lua`.

**Interfaces:**
- **Consumes:**
  - `Activity.Register` and `RegisterDeriver`.
  - `Roster:IsMember`.
  - The Ledger contribution shape: `{ type, char, value, at, counted, why, ref }`. Check Ledger.lua for the exact field names and use them.
- **Produces:**
  - **Activity types:** the six types from Global Constraints.
  - **`Credit.Verified(kills) -> array of verified kills`.** Each verified kill is:

    ```
    { instance, encounter, at, members = union, leaders = union of leader+assists, reporters = { profiles } }
    ```

    - Clustering is greedy and oldest first.
    - Two reports cluster when they come from different profiles, have the same instance and encounter, have `at` within 600 s, and share at least 2 member names.
  - **Majority check.** A verified kill counts only if `#guild members > #members / 2`. Guild membership comes from `Roster:IsMember`, and an unknown member counts as non-guild.
  - **Deriver for `kill`:**
    - **`groups.dungeon`.** One contribution per guild member present at a verified **final** dungeon kill. Deduplicate on `(char, instance key, DayKey(at, tz))`, keeping the first one.
    - **`groups.raidboss`.** One contribution per guild member per verified raid boss kill. Deduplicate on `(char, encounter, WeekStart)`, because the lockout allows one kill per week.
    - **`groups.raidclear`.** Credit when the verified kills of an instance within one weekly reset period cover every boss in it. It goes to the members present at the completing kill, once per `(char, instance, WeekStart)`.
    - **Unverified kills.** These emit rows with `counted = false` and `why = "not verified"`, so the history and breakdown can show them.
    - **`Credit.RaidLeaders(instance, dayKey) -> set of chars`.** The leaders and assists from that day's verified kills, used by Permissions `opts.raidLeaders`.

- [ ] **Step 1: Failing tests.**
  - "two profiles' reports pair; one report is not verified"
  - "2 guild + 3 pugs at the last boss gives no credit even if 4 guild started" (Review Focus 3)
  - "two clears either side of server midnight count 2; two in one day count 1" (Review Focus 2)
  - "a level-60 helper in a low dungeon is credited"
  - "a non-final dungeon boss gives no dungeon credit"
  - "raid boss credit per kill; the same boss twice in one week counts once"
  - "full clear spread over two nights in one lockout counts once for those at the last kill"
  - "RaidLeaders returns leader and assists from verified kills only"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: credit for cleared dungeons, raid bosses and full clears".

### Task 6: Raid checklists and prepared credit

**Files:**
- Create `Guildhall/Modules/Groups/Checklist.lua`.
- Test: `spec/checklist_spec.lua`.

**Interfaces:**
- **Consumes:** Permissions (`checklists` and `prepared`), `Credit.RaidLeaders`, the Compat reads from Task 2, and the history writer.
- **Produces:**
  - **Checklist records** in `core.config`, with id `"checklist:<instance>:<slug>"`. Each record holds `{ instance, name, lines }`.
    - `name` is at most 32 characters.
    - Each line is one of:
      - `{ kind = "item", item = id, count = 1..200 }`
      - `{ kind = "enchants" }`
      - `{ kind = "manual", text ≤ 64 }`
    - A record has at most 12 lines.
  - **Default checklist.** The first saved checklist of an instance is its default. `cl:SetDefault(instance, id)` records the default in `"checklistdefault:<instance>"`.
  - **Writing checklists.** `cl:Save(d) -> ok, err` and `cl:Delete(id)` need the `checklists` permission. Each one also writes a history entry with `what = "checklist"`, carrying before and after.
  - **Incoming records** are accepted only when `perms:Can(rec.char, "checklists")` is true when the record arrives.
  - **`cl:Active(instance, postOrEvent) -> checklist|nil`.** It returns the checklist a post or event picked, otherwise the instance's default.
  - **`cl:SelfCheck(checklist) -> { ok = bool, lines = { {ok, have, need} } }`.** It reads `Compat:ItemCount` and `Compat:UnenchantedSlots`. Manual lines are always `ok = nil`, meaning unknown.
  - **When the self-check runs:**
    - A raider's client publishes it on `READY_CHECK`, and the first time it enters a raid instance that has an active checklist.
    - It runs at most once per instance per server day.
    - It publishes `{ kind = "prepcheck", instance, list = id, ok, miss = count of failed lines, at }`.
  - **`cl:Confirm(raiderChar, instance, ok)`.** It needs `prepared`, checked against the raid leaders of that night. It publishes `{ kind = "prepared", raider, instance, ok, at }`.
  - **Deriver for `prepared`.** It gives one `groups.prepared` contribution per raider per `(instance, DayKey)`.
    - The newest confirmation from an author who is permitted at derivation time wins.
    - The result counts only if it is `ok = true`.
    - A `raidlead`-granted author is permitted only if they are in `Credit.RaidLeaders(instance, day)`.

- [ ] **Step 1: Failing tests.**
  - "a member without 'checklists' can't save; an officer can, and history records it"
  - "SelfCheck reports 2 of 5 potions and missing Legs enchant"
  - "self-check runs once per instance per day"
  - "only a permitted confirmation earns prepared; a self-report alone earns nothing"
  - "a raid assistant with raidlead grant can confirm only on a night they led a verified kill"
  - "the newest confirmation wins (untick after tick removes credit)"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: raid checklists and prepared credit".

### Task 7: Flex — asking for a spec switch

**Files:**
- Create `Guildhall/Modules/Groups/Flex.lua`.
- Test: `spec/flex_spec.lua`.

**Interfaces:**
- **Produces:**
  - **`flex:Ask(raiderChar, instance, note)`** needs the `flex` permission, including the raid-leader rule. It publishes:

    ```
    { kind = "flexask", raider, instance, note ≤ 64, at }
    ```

  - **Detecting the switch.** The raider's client watches `KillWatch:OnSpecChanged` (from `ACTIVE_TALENT_GROUP_CHANGED` or `PLAYER_TALENT_UPDATE`, through Compat).
    - When the active spec group changes within 900 s of an open ask naming me, it publishes `{ kind = "flexdone", ask = askId, at }`.
  - **Manual fallback.** When `Compat:ActiveSpecGroup()` returns nil (no dual spec), the asker's "Switched ✓" tick publishes `{ kind = "flexok", ask = askId, at }`.
  - **Deriver.** One `groups.flex` per ask. It counts when:
    - the asker was permitted at derivation time, and
    - a `flexdone` by the raider's profile arrived within 900 s, or a `flexok` came from the asker.

- [ ] **Step 1: Failing tests.**
  - "ask then a spec change within 15 min counts once"
  - "a change after 16 min doesn't count"
  - "an ask by a member without 'flex' never counts"
  - "without dual spec, the asker's tick counts"
  - "the raider can't tick their own flexok"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: spec switch credit".

### Task 8: Calendar raids and signup credit

**Files:**
- Create `Guildhall/Modules/Groups/Calendar.lua`.
- Modify `Guildhall/Core/Compat.lua`.
- Test: `spec/calendar_spec.lua`.

**Interfaces:**
- **Produces:**
  - **`Compat:GuildEvents(fromT, toT) -> array | nil`.** Each event is `{ title, start, instance = keyOrNil, myStatus }`.
    - It reads `C_Calendar.GetNumDayEvents` and `GetDayEvent`, guild events only (`calendarType == "GUILD_EVENT"`), for today through 14 days ahead.
    - `instance` is mapped from the event's dungeon or raid id, or from the title through `Instances` short and long names.
    - `myStatus` is the player's own invite status, mapped to `"accepted"`, `"signedup"`, `"tentative"`, `"declined"` or nil.
    - It returns nil inside an instance, when `IsRestricted("chat")`, or when any value read is secret.
    - It calls `C_Calendar.OpenCalendar()` once per session, which is a read request.
  - **`cal:Refresh()`** runs on login, on `CALENDAR_UPDATE_EVENT_LIST`, and on leaving an instance. It caches events in memory for the board.
    - For each event where `myStatus` is accepted or signedup, it publishes `{ kind = "signup", title ≤ 64, start, status, at }`.
    - It publishes at most once per (title, start).
  - **Deriver for `signedup`.** One `groups.signedup` per player per post or event.
    - A Guildhall signup counts if it was not withdrawn, the player is in a verified kill of the post's instance, and the kill falls in the post's window:
      - Now posts: created to exp
      - Scheduled posts: start − 1800 to start + 21600
    - A calendar `signup` observation counts if it has a verified kill containing that player within start − 1800 to start + 21600, for the event's instance (or any raid, when the instance is unknown).
  - **`cal:Events() -> array`** for the board. These are read-only and marked "Calendar". `accepted` is the count of guild members whose own signup observation exists.

- [ ] **Step 1: Failing tests.**
  - "events read nothing inside an instance or with a secret value"
  - "a Guildhall signup plus a verified kill in the window counts once"
  - "a signup without a kill counts nothing"
  - "a calendar signup is credited only when paired with a verified kill"
  - "the signup observation is published once per event"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: calendar raids and signup credit".

### Task 9: Reminders and the Groups module

**Files:**
- Create `Guildhall/Modules/Groups/Reminders.lua` and `Guildhall/Modules/Groups/Module.lua` (both TOCs, after the other Groups files).
- Test: `spec/reminders_spec.lua` and `spec/boot_spec.lua`.

**Interfaces:**
- **Consumes:** `def.events` and `services.syncs` (leaderboard Task 10), and the services from Tasks 3–8.
- **Produces:**
  - **`Module.lua`** registers module `"Groups"`:
    - **Events:**
      - `ENCOUNTER_START`, `ENCOUNTER_END`, `BOSS_KILL`, `PLAYER_ENTERING_WORLD`
      - `READY_CHECK`
      - `ACTIVE_TALENT_GROUP_CHANGED`, if present (else `PLAYER_TALENT_UPDATE`)
      - `CALENDAR_UPDATE_EVENT_LIST`, `GROUP_ROSTER_UPDATE`
    - **`OnLogin`** builds `ns.groups = { svc, kills, credit, checklist, flex, calendar, reminders }`.
    - **Tab:** `tab = { title = "Groups", build = ns.Groups.View.Build }`, placed after Leaderboard and before Log.
    - **Settings:** `settings = { title = "Groups", build = ns.Groups.SettingsView.Build }`.
    - **About text:** `about = { title = "Group finder", lines = { "Post or join guild runs, now or scheduled. Finished runs and raid nights count on the leaderboard." } }`.
  - **`Reminders.new(ctx)`** ticks every 30 s using `ctx.after`.
    - **The 15-minute reminder.** At `start - 900` it prints one chat line to each signed-up, non-withdrawn player and to the poster: `"Guildhall: <instance> starts in 15 min (<n> of <size> signed up, <m> online)."`
    - **Sound.** It plays `SOUNDKIT.READY_CHECK` when `personal.groups.sound ~= false`.
    - **Firing rules.** Each reminder fires once per post. If the client logs in late, it fires immediately when the client is past `start - 900` and before `start`.
    - **Opt-out.** When `personal.groups.reminders == false`, nothing fires.
  - **`personal.groups = { reminders = true, sound = true, roles = { d = true } }`.** These are defaults, account-wide.

- [ ] **Step 1: Failing tests.**
  - "a post at 20:00 server time reminds at 19:45 server time with a local offset of +3 h" (Review Focus 4)
  - "a late login inside the 15-minute window reminds once"
  - "reminders off fires nothing"
  - "tab order is Exchange, Leaderboard, Groups, Log, Settings, About"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: reminders and module registration".

### Task 10: Groups tab: board, details, Ready now and history

**Files:**
- Create `Guildhall/Modules/Groups/UI/View.lua` and `Guildhall/Modules/Groups/UI/Details.lua` (both TOCs).
- Modify `Guildhall/Modules/Exchange/UI/Board.lua` and `Form.lua`: add `ns.ExchangeUI.Search(text)` and `ns.ExchangeUI.OpenForm(prefill)` if they are absent, where `prefill = { kind = "LF", item = idOrName }`.
- Test: `spec/groupsview_spec.lua`, using fake widgets as `form_spec` does.

**Interfaces:**
- **Consumes:** `ns.groups` and the UI helpers. The layout follows the mockup boards "Groups · dungeon post" and "Groups · raid night".
- **Produces:** `ns.Groups.View.Build(parent) -> obj` with `obj:Refresh()`.
  - **"Ready now" strip.** It shows up to 4 names, with role tags, an online dot and "· N h" when the player gave a window, followed by "+N more".
    - The button reads "I'm ready now ▾". It is a picklist with roles and "free for 1/2/4 h", plus "Not ready".
  - **Sub-tabs:** **Board** and **History**.
  - **Post list.** Sections are "NOW" and "SCHEDULED". Calendar events show a "Calendar" tag.
    - Each row shows the instance name and "· <poster>" (or the time for scheduled posts), plus role tags.
    - A tag shows ✓ when that slot is filled, or else the number still open.
  - **Details for a dungeon post:**
    - **Header.** The title "<instance> · Now" (or the date and time), then the line "Posted by X N min ago · "<note>"".
    - **Item line.** "Needs: [item]" is a link that calls `ExchangeUI.Search`.
    - **Group.** "Group (n of size) · m online", then the filled rows.
    - **Signups.** "Signups waiting" lists signups with offered roles. For the poster, each signup has role buttons and an "Invite" button. "Invite" only copies "/invite Name" into the chat edit box via `Compat:OpenChat`. It never invites.
    - **Credit footnote, verbatim:** "Credit when the group kills the last boss with 3+ guild members. Once per dungeon per player per day."
    - **Poster buttons:** "Post LF on Exchange", which calls `ExchangeUI.OpenForm`, "Copy for chat", and "Close post".
    - **Non-poster buttons:** "Sign up ▾", with role choices, or "Withdraw".
  - **Details for a raid post or calendar event:**
    - **Header.** "<date> server time · N accepted · in raid now: X (Y guild) · bosses k / n".
    - **Checklist.** A checklist picker, plus a summary of the checklist.
    - **Roster.** Raider, one column per checklist line, Prepared (a checkbox, enabled only for permitted users), and Flex ("Ask to switch", or "↻ <spec> ✓" once done). The widths are fixed so text never overlaps.
    - **Footnote, verbatim:** "Ticks are pre-filled from each raider's own bag and gear check. Only your tick earns "prepared" credit. Every change is in the change history."
    - **Buttons:** "Confirm all checked" and "Edit checklist", the latter shown only with the `checklists` permission.
  - **History, "Mine" and "Guild":**
    - Mine lists "Your last runs".
    - Guild lists verified clears, newest first: "<short> cleared by A, B and N more, D min".
    - "Not verified" runs show only in Mine, greyed.
  - **Empty state:** "No runs posted. Post one, or mark yourself Ready now so guildmates know."

- [ ] **Step 1: Failing tests.**
  - "Now posts list before scheduled, calendar events tagged"
  - "a filled slot shows ✓"
  - "Invite fills the chat box and calls no invite API"
  - "Prepared checkbox disabled without permission"
  - "history line reads 'Strat UD cleared by Dor, Brakka and 3 more, 42 min'"
  - "the Exchange link calls Search with the item"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups tab".

### Task 11: New post form and checklist editor

**Files:**
- Create `Guildhall/Modules/Groups/UI/Form.lua` and `Guildhall/Modules/Groups/UI/ChecklistEditor.lua` (both TOCs).
- Test: `spec/groupsform_spec.lua`.

**Interfaces:**
- **New post form:** `ns.Groups.Form.Open(prefill)`, following the "New group post form" mockup.
  - **Run.** A picker using `Instances.ForPicker`, with dungeons then raids.
  - **Role.** Your role, as radio buttons.
  - **"Still need".** It is pre-filled from the run's size and your role: 5-player runs give 1 tank, 1 healer and 3 DPS, less your own role; 40-player runs give 2, 8 and 29, less your role. It shows "Filled from the run size and your role. Change if friends are coming."
  - **When.** Now or Scheduled. Scheduled uses a date picker covering the next 14 days and a time entry box "HH:MM", labelled "server time".
  - **Note.** 120 characters, with a counter.
  - **"Run needs".** An item slot or typed name (optional), with "Shows as a link that searches the Exchange."
  - **Reminder.** "Remind signups 15 min before", checked by default.
  - **Preview.** A preview line.
  - **Buttons.** Cancel and Post.
- **Errors:**
  - "Pick a run."
  - "That's more people than the run allows."
  - "Pick a time in the future."
  - "Note is too long."
- **Checklist editor:** `ns.Groups.ChecklistEditor.Open(instance, id|nil)`.
  - It edits lines (item with count, all gear enchanted, manual text) and a name.
  - Save calls `cl:Save`. A permission error shows the message `cl:Save` returned.

- [ ] **Step 1: Failing tests.**
  - "need defaults to 1/1/3 minus your role"
  - "a scheduled time in the past is refused"
  - "the payload matches the inputs"
  - "the editor caps at 12 lines and saves through cl:Save"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Groups: post form and checklist editor".

### Task 12: Settings — Permissions, Change history and Groups

**Files:**
- Create `Guildhall/Core/UI/PermissionsView.lua` and `Guildhall/Modules/Groups/UI/SettingsView.lua` (both TOCs).
- Modify `Guildhall/Core/UI/SettingsView.lua` (sub-tabs) and `Guildhall/Core/Leaderboard/UI/SettingsView.lua` (move the history list out to the shared Change history view).
- Test: `spec/permissionsview_spec.lua`.

**Interfaces:**
- **Settings sub-tabs.** Settings shows sub-tabs General, Leaderboard, Groups, Permissions and Change history. A module's `settings` entry becomes a sub-tab.
- **Permissions view.** It follows the "Settings · Permissions" mockup.
  - **Caption, verbatim:** "Only the Guild Master can change these. Ranks come from the game, in rank order."
  - **Grid.** Columns are `Roster:RankNames()` plus "Raid leader & assistants". The raid-leader column is shown only for `checklists`, `prepared` and `flex`. Rows are `Permissions.KEYS` labels. The Guild Master column is always ✓ and not editable.
  - **Who can edit.** Checkboxes are enabled only for rank 0.
  - **Buttons.** "Reset to officer ranks" and "Save". Save calls `perms:Publish`.
  - **Recent changes.** Below the grid, the 4 newest history entries, with the label "(full list under Change history)".
- **Change history view:**
  - **Visibility.** The guild master and officers see it. Other members see "Only officers and the guild master can see the change history."
  - **Rows.** Each row shows the time, the name with rank name in brackets, and a plain-language line:
    - "Checklist <name>: <item> 3 → 5"
    - "Permission <label>: added <rank>" or "removed <rank>"
    - "Leaderboard weight <label>: 3 → 30"
    - "Retook <Month> top 5"
- **Groups settings:**
  - "Remind me 15 min before runs I signed up for"
  - "Play a sound with reminders"
  - "My usual roles": the defaults for Ready now and Sign up.

- [ ] **Step 1: Failing tests.**
  - "a non-GM sees the grid read-only"
  - "GM save publishes perms with the ticked ranks"
  - "history lines render in plain language for each what"
  - "members can't see the change history"
- [ ] **Steps 2–4:** confirm the tests fail, implement, confirm they pass.
- [ ] **Step 5:** commit "Settings: permissions, change history, groups".

### Task 13: Docs, What's new and Forever tests

**Files:**
- Modify:
  - `docs/testing/forever-launch.md`
  - `docs/testing/in-game-checklist.md`
  - `README.md`, a group finder paragraph
  - `Guildhall/Core/WhatsNew.lua`, the next version's lines
- Test: none beyond `bash tools/check.sh`. `release.sh` checks the WhatsNew entry.

**Content:**
- **forever-launch.md, Groups section.**
  - **Solo:**
    - Does `ENCOUNTER_END` fire for a 5-player boss? Use `/etrace` or `/gh debug`.
    - Does the dungeon's final boss id match `Instances`?
    - Does dual spec exist, and which event fires?
    - Does the calendar read guild events and my status outside an instance?
    - Does `UnenchantedSlots` report correctly?
  - **Second client:**
    - Two clients kill a boss. Check that the kill pairs, the 3-of-5 majority applies, and credit shows on the leaderboard.
    - A post and signup sync, and the reminder fires.
    - Prepared confirm and Ask to switch work end to end.
    - The GM changes permissions, and the officer client sees the history line.
- **in-game-checklist.md.** Add the Era steps for the same features.
- **WhatsNew lines:**
  - "New Groups tab: post or join guild runs, now or scheduled."
  - "Finished dungeons, raid bosses, prepared raiders and spec switches now count on the leaderboard."
  - "Guild masters can choose which ranks can do what, and every change is recorded."
- [ ] **Step 1:** write the docs.
- [ ] **Step 2:** `bash tools/check.sh` passes.
- [ ] **Step 3:** commit "Groups: docs, What's new, Forever tests".
