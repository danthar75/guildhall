# Guildhall: Group finder (design)

Status: approved for v1 by Dor on 2026-11-04. Author: Claude, from conversation with Dor.

Labels:
- **(user)**: Dor decided it.
- **(my call)**: Claude decided it; Dor can override.

Related:
- `2026-11-02-guildhall-exchange-design.md`: core, sync and trust model.
- `2026-11-04-guild-leaderboard-design.md`: activities, observations, pairing and weights.

Build order: after the Leaderboard branch (which includes the welcome screen) has merged.

## Intent

The game's LFG is basic, and today a guild run starts with a guild-chat line like "looking to run Scholomance, I'm DPS, need a tank and 2 more DPS". The group then forms through chat, if it forms at all (user). That line scrolls away, nobody can see who has already said yes, and players who weren't online miss it.

Guildhall adds a guild-only group finder. It makes runs easy to post, join, schedule and fill, and it credits finished runs on the leaderboard to encourage guild play (user).

## Goals (v1)

1. **The Groups board** (a new tab).
   - A post lists:
     - the dungeon or raid
     - the poster's role
     - open slots by role (tank / healer / DPS)
     - **Now** or a **date and time** (user)
     - an optional note
   - Guildmates sign up with one or more roles.
2. **Ready now (user pick 1).** One click marks you available, with your roles, level and an optional "free for N hours". Posters see who's available before posting.
3. **Exchange tie-in (user pick 2).** A post can name the run's key item or quest need, for example "need Seal of Ascension frags". In the post this shows as a link: clicking it opens the Exchange board searched for that item. A "Post an LF on the Exchange" button opens the Exchange form pre-filled, and the poster submits it as usual. Nothing is created automatically, and Exchange consent rules apply unchanged (my call, from the builder check).
4. **Reminders (user pick 3).**
   - 15 minutes before a scheduled run, signed-up players get a chat line and an optional sound.
   - The poster also sees "3 of 5 signed up, 2 online".
5. **Smart role slots (user pick 4).**
   - The poster's role is filled automatically.
   - A signup can offer several roles ("healer or DPS"), and the poster assigns one when forming the group. This rewards flexible players (user's goal).
6. **The "who's in" view (user pick 5).** Each signup shows a role, an online dot, a whisper button and an invite suggestion, using the same pattern as the Exchange board.
7. **Run history (user pick 6).** "Your last runs" and the guild's recent clears, for example "Strat UD cleared by Dor, Brakka and 3 more, 42 min".
8. **Credit for finished runs** on the leaderboard, through new activity types (user). See below.
9. **Raids**, including calendar events and raid-specific credit (user).
10. **Permissions by guild rank, with a shared change history** (user). This is a core system, used by this module and the leaderboard.

## Non-goals (v1)

- **Auto-inviting.** Guildhall suggests invites and the player clicks the game's own invite (my call: Forever restricts actions, and Guildhall has never acted for the player).
- **No-show penalties or public reliability scores.** These would shame people, which the leaderboard already rules out. Officers see attendance in private breakdowns.
- **Creating or editing calendar events.** The calendar API's create and edit calls are restricted, so leadership keeps using the game's calendar for that. Guildhall only reads it (my call).
- Level and gear hints, raid soft-reserve, and "Copy for Discord" on posts are deferred to later (suggestions 7–9).

## Anti-goals

- **Credit can be farmed.** Signing up or posting alone earns nothing. Credit needs a verified boss kill (user).
- **It nags.** Reminders go only to people who signed up, and each player can turn them off.
- **A "bad egg" officer can quietly change rules.** Every permission or checklist change is recorded in the shared history, and only the guild master can change permissions (user).

## Runs and credit

### What counts as a finished run (user)
- **Dungeons:** the group kills the **last boss**.
  - Multi-wing dungeons count each end separately (my call). Examples: Dire Maul East, West and North; Stratholme Live and Undead.
  - Guildhall carries a table of final-boss encounter IDs per instance for the Era/Forever content set.
- **Raids:** each boss kill counts (user's "killing bosses"). A full clear may add a bonus, a separately weighted activity (my call).

### Repeat runs (user)
- **Dungeon credit counts once per dungeon per player per server day (user).** Running Stratholme Undead three times in a day earns one `groups.dungeon` credit. A different dungeon, or a different end of a multi-wing dungeon, counts separately. The day is the guild's server day, the same clock the leaderboard periods use.
- **No level limit (user).** A level 60 helping a guildmate through a low-level dungeon still earns credit, because helping guildies get gear or a clear is exactly what the guild wants to encourage.
- Applied at query time when the ledger counts credit, so the raw kill observations are all kept (my call).
- Raids are already limited by their weekly lockout, so they have no extra limit.

### Guild majority (user)
A kill counts only if **more than half** of the group are guild members: 3 of 5 for dungeons (user), and the same rule for raids, for example 21 of 40 (my call, the same rule extended).
Every report's own member list must have that majority, so one honest list vetoes a forged list padded with guild names (final review I1). A report counts only from a linked profile that owns the char it was sent from (final review I4).

### Detection (my call; verify in game)
- **The event.** `ENCOUNTER_END(encounterID, name, difficulty, groupSize, success)` with `success == 1`.
  - It isn't on Forever's restricted list.
  - Its values must still go through `Compat:Safe`.
  - **It must be verified in game on Era and Forever before relying on it.** The fallback is `BOSS_KILL`.
- **The group snapshot.** At the kill, each Guildhall client records the group's members (party/raid unit names, which are readable for your own group) and how many of them are guild members.
- **The observation.** Each client publishes `{ kind = "kill", instance, encounter, members = [...], guildCount, at }`. This adds a new observation kind, plus a field shape for the member list. Observations currently allow only `items` as a nested array, so `Observations.Validate` needs extending (it's left to the builder to bound the list at 40 names, each ≤ 64 bytes).
- **Pairing.** A kill is verified when **two different profiles** report the same instance, encounter, and `at` within 10 minutes (my call), with overlapping member lists.
- **Credit.** Every member who belongs to a consenting Guildhall profile in this guild gets credit. Non-guild members and non-users are ignored.
- **Raid attendance without a signup (my call, from the builder check).** Guild members in the group at a verified kill get `groups.raidboss` credit whether or not they signed up. That is the user's "showing up" credit. Signing up first only adds the separate `groups.signedup` credit.
- **Full clear (my call).** A full clear counts once per lockout week, so it can be spread over several nights. It needs a verified kill of every boss in that instance's table within one weekly reset period.
- **Leader flags (my call).** The group snapshot also records who is the raid leader and who are assistants. Leaders and assistants are readable for your own group.
- **Volume (final review I2).** Each client snapshots the group at the kill and publishes after a random 0-30 s wait. It skips publishing when the store already holds 3 or more reports of that kill, from other linked profiles listing this player, that already confirm (2 reports each) every name it would report, so skipping never costs anyone credit. Non-final dungeon boss kills expire after 2 days; nothing derives lasting credit from them.
- **Attendance (final review I3).** A prepared confirmation, a spec-switch ask or a signup counts the raider as present when a verified kill of that instance credits them within 30 min before to 6 h after it (for signups: inside the signup's window). "One per night" is the server day of that kill, so a raid forming before midnight and killing after it is one night.

### Restrictions on Forever
- Inside dungeons and raids, addon messages may be held back. Observations queue in Comm and send when restrictions lift, which already works.
- Calendar reads are secret during chat lockdown, so the calendar is read only outside instances.

### Activity types (new; defaults are my call, and guilds set the weights)

| Activity | Unit | Default weight |
|---|---|---|
| `groups.dungeon` (dungeon cleared) | count | 5 |
| `groups.raidboss` (raid boss killed) | count | 3 |
| `groups.raidclear` (full raid clear bonus) | count | 5 |
| `groups.prepared` (prepared, leadership-confirmed) | count | 2 |
| `groups.flex` (switched spec when asked) | count | 1 ("some credit", user) |
| `groups.signedup` (signed up through Guildhall or the calendar and then showed up) | count | 1 |

`groups.signedup` uses the `paired` verification level: the signup record plus a verified kill containing that player.
- **Calendar signups (my call, from the builder check).** Each player's own client reads its own calendar invite status ("accepted" or "signed up") outside instances. It publishes a `signup` observation `{ event title, start, status }`. The signup is the player's own claim, which is harmless, because it only earns credit when paired with a kill verified by others. Guildhall signups are already synced records.

## Raids (user)

- **Calendar first.** Leadership will mostly keep scheduling raids in the game calendar (user).
  - Guildhall reads guild calendar events and their sign-ups (`C_Calendar` reads, outside instances).
  - It shows them on the Groups board as read-only entries.
  - It links them to verified kills inside the event's time window, from start − 30 minutes to start + 6 hours (my call).
- **Guildhall raids.** Members can also post raids on the Groups board, the same as dungeons (user).
- **Credits** (user):
  - showing up (in the group at boss kills)
  - killing bosses
  - **prepared**, confirmed by leadership
  - **switching specs when asked** ("some" credit, to encourage flex players)

### Prepared checklists (user, with my design)
- **Who sets them:** officers and above set a checklist per raid (user), through the permissions system below. Examples:
  - consumables with counts: "5× Greater Fire Protection Potion"
  - "all gear enchanted"
  - free-text manual items, such as world buffs
- **Automatic check.** Each raider's client checks its own bags (`GetItemCount`) and equipped gear (whether each enchantable slot's item link has an enchant) when the raid forms or at the ready check, before the first pull. It reports the result as an observation.
- **Leadership view.** Leadership sees the roster with ✓/✗ per person and what's missing.
- **What a checklist belongs to (my call, from the builder check).** One checklist per **instance** (for example Molten Core), reused every week. A calendar event or Guildhall raid post may pick a different saved checklist for that night. When a raid forms, each raider's client checks the checklist of the instance named by the active event or post, or else of the instance they enter.
- **Confirmation.** A "Prepared" checkbox per raider is pre-ticked from the automatic check, and leadership can override it. **Only the leadership tick earns credit** (the `confirmed` verification level), so a modified client can't fake it.
- **History.** Every checklist change goes into the shared change history (user).

### Flex: spec switches (user, with my design)
- **The request.** Someone allowed to (see permissions) clicks "Ask to switch" on a raider, with an optional note like "heal for this boss".
- **Detection.** The raider's client sees the spec actually change (`ACTIVE_TALENT_GROUP_CHANGED` or the client's equivalent). **Whether Forever has dual spec must be checked in game.**
- **Credit.** The request plus the observed switch, within 15 minutes (my call), earns `groups.flex` credit.
- **Fallback if Forever has no dual spec (my call, from the builder check).** Flex becomes leadership-confirmed: whoever asked ticks "switched" afterwards, the same as "Prepared", with no automatic detection. The task is built so detection plugs in when dual spec exists.

## Permissions (core; user)

- **Settings → Permissions.** It lists each permission, with a tick box per **guild rank**, using the guild's real rank names and order from the game. It also has one extra option: "the current raid leader and assistants" (my call).
- **Permissions in v1:**
  - edit raid checklists
  - confirm prepared
  - ask for spec switches
  - edit leaderboard weights
  - retake a month
  - later, create contests
- **Defaults.** Every permission starts as the guild master only, until the guild master changes it (user).
- **Only the guild master (rank 0) can change permissions** (user).
- **Checking "raid leader and assistants" (my call, from the builder check).** Other clients accept a confirmation or "Ask to switch" from a non-officer only when that player is shown as leader or assistant in the leader flags of a **paired** kill snapshot of the same raid that night. That needs reports from two different players. Otherwise the confirmation is ignored.
- **Storage.** Permissions are stored as a guild-master-authored config record in `core.config`. Other clients accept it only from rank 0.
- **Migration.** The leaderboard's officer checks (weights, retakes) move to these permissions.

## Shared change history (core; user)

- **What's recorded.** Every change to officer-controlled settings becomes an append-only, synced history record: what changed, the before and after values, who changed it, and when. That covers permissions, checklists, weights and month retakes.
- **Who sees it.** The guild master and officers can review it in Settings ("in case we get a bad egg", user).
- **Tamper resistance.** History records never expire and can never be replaced.
- The leaderboard plan's Task 14 builds the first version, covering weights and retakes. That task was added on the `feature/leaderboard` branch. This module extends it to permissions and checklists, and moves the leaderboard's officer checks onto permissions.
- **Strength (my call, from the builder check).** History is an audit trail between honest clients, consistent with the parent design's trust model that guildmates' clients aren't modified. The "bad egg" is an officer misusing an honest client, and the history makes that visible to the guild master. To stop a change from slipping through without a record, every officer config change and its history entry are published as **one record**: the config record carries `before`, `after` and `by`, and every version of it is kept. A guard against modified clients is out of scope.
- **Retention (my call).** History is kept for 2 years, about 200 bytes per change.

## UI (my call; to be mocked up before building)

- **Groups tab**, between Leaderboard and Log. It has three areas:
  - **"Ready now" strip** at the top: who's available, with roles and an online dot.
  - **Post list** on the left: Now first, then scheduled runs by start time, plus calendar events (read-only, marked "Calendar").
  - **Details pane** on the right:
    - slots by role
    - signups, each with a role pick, online dot, Whisper, and an invite suggestion
    - the Exchange link
    - for raids:
      - the prepared roster
      - "Ask to switch"
      - "Confirm prepared", for those allowed
- **New post form:**
  - instance picker
  - your role
  - slots
  - Now or a date and time
  - note
  - optional Exchange item
- **Run history:** a sub-tab, showing "Mine" and "Guild".
- **Settings → Groups:**
  - reminders on or off
  - reminder sound on or off
  - default roles
- **Welcome and About:** the module provides its `about` lines.

## Data (left to the builder, with these limits)

- **Posts** are a replicated set `groups.posts`, following the Exchange listing pattern.
  - Expiry: Now posts expire after 2 hours, and scheduled posts 6 hours after their start (my call).
  - A post is about 300 bytes.
- **Signups** are small records keyed by `post:profile` in `groups.signups`. A player can withdraw a signup.
- **"Ready now"** records expire after their "free for" window (default 2 hours).
- **Kills, prepared checks, confirmations and flex events** are observations in `core.observations`.
- **Permissions and history** live in `core.config`.

## Open questions for the builder check

1. Does `ENCOUNTER_END` fire for 5-player dungeon bosses on Era and on Forever? Otherwise, what is the reliable kill signal?
2. Dual spec on Forever, and the event name for a spec switch.
3. Which calendar fields are readable for sign-ups: invite status per player, and guild event versus player event.
4. Whether a group-member snapshot during an encounter is readable on Forever (unit names in your own party or raid).
