# Guildhearth: Contests v1 (design)

Status: draft for review (builder check done), 2026-11-04. Author: Claude, from conversation with Dor.

Related:
- `2026-11-04-guild-leaderboard-design.md`, mainly "Guild bank contributions" and "Next module: contests". Its rules still hold unless this document says otherwise.
- `2026-11-04-group-finder-design.md`, mainly Permissions, Shared change history and the U1b guild settings.
- Approved mockups (v1): `.superpowers/brainstorm/102453-1793830381/content/contests-overview.html`. These are local and git-ignored, so the layout summary below is the record.
- Labels: **(user)** means the user decided it, and **(my call)** means Claude decided it and the user can override it.

## Intent

Contests are short, time-limited guild bank donation races, for example "most raw mats in 3 hours" (user). They make stocking the guild bank a fun event with a podium and rewards, and they build on the leaderboard's bank tracking. A contest is just another view of bank deposits; it doesn't need a new kind of tracking (leaderboard design).

## Goals (v1)

1. **Create a contest** (user). The creator sets:
   - a name
   - a start time and a length: a few hours, or a whole weekend
   - a list of materials, each with its own points per item
   - rewards for 1st, 2nd and 3rd
   - whether standings are shown live
2. **Pick materials from a list, then adjust** (user). Start from a preset list such as Ores, Herbs, Cloth, Leather, Fish or Meat, then add items with shift-click or remove them. Each item's points can be edited.
3. **Suggest points from auction prices** (user). If Auctionator is installed, a button sets each item's points from its last-scan price relative to the cheapest item on the list. The cheapest item gets 1 point and the rest are scaled and rounded (my call). The points are saved in the contest, so every client uses the same numbers.
4. **Scoring.** A player's score is the sum, over the contest's materials, of the net count deposited during the window times that material's points.
5. **Live standings, or hidden until the end**, chosen per contest (user).
6. **The end.** When time runs out, the contest closes by itself. It shows 1st, 2nd and 3rd with details (who brought what), and the result is saved in the contest history (user).
7. **Ties.** Whoever reached the tied score first ranks higher (user).
8. **Rewards** are preset for each place (user). An officer hands them out by hand. The contest history tracks "Reward sent" per place, with who ticked it and when (user).
9. **Alerts.** On-screen alerts appear when a contest starts, 30 minutes before it ends, and with the winners (user). Each player can turn them off in Settings (my call).
10. **More than one contest can run at once** (user). A deposit counts toward every running contest that lists that material.
11. **The creator can edit the contest after it starts** (user): extend or shorten it, change points, change rewards, or cancel it. Every edit is recorded in the shared change history (user).

## Non-goals (v1)

- Moving gold or items. The addon never sends rewards. It only shows what was promised and tracks who sent it.
- Contests on anything other than guild bank item deposits: no gold donations, kills or crafting. My call; the record shape should allow other kinds later.
- Entry fees, teams or brackets.
- Prizes beyond three places.

## Anti-goals (it fails if…)

- **Points can be farmed.** A deposit, withdraw and redeposit loop must not raise a score.
- **A modified client can claim deposits that never happened.**
- **A deposit near the start or end is credited or dropped unfairly.**
- **Clients disagree about who won.**

## Who can take part, and what counts

- **Only Guildhearth users can place** (user). A deposit counts only when its character is a linked character of a consenting Guildhearth profile. This is the leaderboard's existing rule.
- **Players who opted out of the leaderboard must opt back in to take part** (user). A podium needs the real name so an officer knows who to reward. While opted out, a player's deposits don't count toward contests. The contest details tell them: "You're hidden from the leaderboard, so your deposits don't count. Show me on the leaderboard to take part."
- **Everyone can compete, including the creator** (user).
- **Exact time from the depositor (my call).**
  - The depositor's own client records the exact moment of each guild bank deposit it makes: the item, count, tab and server time. It detects deposits from its own bag and bank changes while the bank is open, and the builder confirms the exact events.
  - These records are published as a new observation kind, for example `bankdeposit`. Withdrawals are recorded the same way.
- **If exact times can't be read (my call, from the builder check).** On a client where the game doesn't allow detecting your own deposits (or the values are secret), contests fall back to bank log times. A deposit then counts only when its whole hour-wide uncertainty lies inside the window. The form warns: "On this version, contests shorter than about 3 hours can't be judged precisely."
- **Proof from the bank log (user approved my proposal).**
  - A depositor's record counts only when a matching **verified** bank log entry exists. That means the same character, tab, item and count, with the log's approximate time within about an hour of the exact time. "Verified" uses the leaderboard's existing rule: the entry is reported by two clients, or by one client that isn't the depositor's.
  - Each log entry can confirm only one exact-time record.
  - The window test uses the exact time.
- **Netting (my call).**
  - Per player, per contest, per material, the score uses deposits minus withdrawals inside the window, floored at 0.
  - Withdrawals are matched to the bank log the same way. An unconfirmed withdrawal still counts against the player, to be safe.
  - A verified bank log withdrawal with no exact-time record still counts against the player when its hour-wide uncertainty overlaps the window (my call, from the builder check). Otherwise a withdrawal made with the addon off would reopen the deposit, withdraw and redeposit farm.
- **Existing bank rules apply (my call).**
  - The leaderboard's donation-tab tag (`[Guildhearth donations=...]`) and excluded-rank tag (`[Guildhearth bankexclude=...]`) apply to contests too.
  - Officer bank review applies too: a deposit an officer unticks doesn't count.
- **Contest deposits still count on the regular leaderboard** as normal bank donations (my call). A contest is only a separate view of the same deposits.

## Ending and results

- At the end time, every client shows the contest as finished, with a **provisional** podium computed from the data it has. The winners alert fires then.
- **Fast final results (user: "30-60 minutes if not sooner; people want to see the results asap").**
  - A result becomes **final** 60 minutes after the end at the latest.
  - Anyone with the contest permission (or the creator) can press **"Finalize now"** at any time after the end.
  - Deposits still unconfirmed by the bank log at that moment don't count.
- **Getting deposits confirmed quickly (my call).**
  - Bank log proof needs a client that isn't the depositor's to read the log.
  - "Finalize now" therefore asks the officer to have the guild bank open, and re-reads the log before freezing. The button reads "Open the guild bank to finalize" until the bank is open.
  - During the last 30 minutes, and in the hour after the end, any Guildhearth user with the bank open re-reads the log every minute.
- **The frozen result (my call, from the builder check).**
  - The finalizing client publishes a frozen result record containing:
    - the ranked podium (char, points, the time each player reached their score)
    - the full standings
    - the ids of the deposit observations it counted
  - The frozen record is authoritative, so every client shows it. A client whose own calculation differs shows a small "your data differed" note, not a different podium.
  - The first frozen record wins. Like a month retake, a later one replaces it only if it comes from the guild master.
  - Results stay provisional until someone with the permission is online after the hour. Any such client freezes automatically at that point.
- **A second "Final results" alert** fires only if the frozen podium differs from the provisional one (my call).
- **Reward sent.** Each podium place has a "Reward sent" tick that the creator and anyone with the contest permission can tick (my call). It records who and when. Unticking is also recorded.

## Permissions and history

- **New permission: "Create and run contests"** (user). It is set per rank in Settings > Permissions. As with the other permissions, it starts as the guild master only until the GM changes it, and only the GM can change it.
- **Editing.**
  - The creator can edit their contest (user). The guild master can also edit or cancel any contest, for example when the creator has left the guild (my call).
  - The creator keeps edit rights even if they later lose the permission. Reward ticks need the permission (my call).
  - Before the end, everything can be edited: times, points, materials, rewards and live/hidden.
  - After the end, the times, points and materials lock, so a finished contest can't be reopened or rescored. Only cancelling (until the result is final) and reward ticks remain (my call, from the builder check).
  - Start and 30-minute alerts never fire twice for one contest.
  - **Points changes apply to the whole contest**, including earlier deposits, so the standings are recomputed (my call). Changing the start or end recomputes the window.
- **History.** Every create, edit, cancel and reward tick goes into the shared change history. Some example lines:
  - "Contest Cloth Drive: created"
  - "Contest Cloth Drive: Runecloth 4 -> 5 pts"
  - "Contest Cloth Drive: end 21:00 -> 22:00"
  - "Contest Cloth Drive: reward 1st sent to Velis"
  - "Contest Cloth Drive: cancelled"
- **Storage.** Contest definitions are config records in `core.config`, following the checklist pattern: history kept in the same record, `before`/`after`/`by`, and every version retained.

## UI (user approved the v1 mockups)

- **A new Contests tab** between Groups and Log (my call).
  - **Sections:** Running, Starting soon and Finished.
  - **Rows:** each shows the name, the time left or the date, and whether standings are live or hidden.
  - **Your place:** shown on running contests that have live standings, and your own points on hidden ones.
  - **Finished rows** show the podium and whether all rewards are sent, or how many are left.
- **Contest details:**
  - the time window in server time, the creator and a time bar
  - rewards per place
  - points per material
  - standings, with each player's breakdown (items and counts). A short note explains the tie rule where it applied.
  - a footnote: only deposits by Guildhearth users count, and each must show in the bank log
- **Hidden standings.**
  - While a hidden contest runs, other players see no standings. Your own score is still shown to you.
  - Clients may still compute standings locally. "Hidden" is a display choice, not secrecy (my call).
- **New contest form:**
  - name, start date and time in server time, then a length in hours or an end date and time
  - a "Start from list" picker
  - the material rows: item, points box, AH price when known, and a remove button
  - "Suggest points from AH prices", disabled with a hint when Auctionator isn't loaded
  - three reward text boxes
  - "Show standings while it runs"
  - Cancel and Create
  - The edit form is the same form, used by the creator.
- **Finished contest:** the podium and points, and "Reward sent (<reward>)" ticks with "by <name>, <date time>". A "provisional" label shows until the result is frozen.
- **Alerts:** a raid-warning style message in the middle of the screen for a few seconds. Plain ASCII only. There are three, with examples:
  - Start: "Contest started: Cloth Drive" plus the length and materials
  - "30 minutes left: Cloth Drive" plus your place when standings are live
  - "Cloth Drive is over!" plus the podium
- **Settings:**
  - Settings > Contests (or the Groups-style personal section) gets "Show contest alerts".
  - The permission appears in Settings > Permissions.

## Constraints

- Everything in the parent designs still applies:
  - The Forever secret-values rules.
  - Classic Era is nil-safe.
  - No UI glyph above U+00FF.
  - Strict validators on every synced record.
  - The trusted-guildmates model. History is an audit trail between honest clients, and the bank log proof is the guard against forged deposits.
- **Bank log precision.** The game reports bank log times as "N hours ago". The exact time comes only from the depositor's own client.
- **Auctionator is optional** (OptionalDeps). Use its public API to read the last-scan price by item ID. It must work without Auctionator, and with Auctionator present but holding no price for an item.
- **Storage.**
  - A contest record is about 1 KB with up to 40 materials (my call: a cap of 40 materials and a 200-character name and reward text).
  - Deposit observations are small and kept for 400 days, like other observations.
  - Frozen results are kept for 2 years, like history.

## Open questions for the builder check

1. (Settled: 60 minutes at the latest, plus "Finalize now".)
2. **Detecting your own deposits.** Can the depositor's client reliably detect its own guild bank deposits, and their exact time, on Forever and on Era? Candidate signals are bag updates while the bank is open, `GUILDBANKBAGSLOTS_CHANGED`, and an immediate log re-read. Are any of these secret on Forever?
3. **Auctionator.** Does Auctionator run on Forever, and is its price API (`Auctionator.API.v1.GetAuctionPriceByItemID`) available there?
4. **Preset lists.** Should the preset lists be defined by item class and subclass, or by explicit item IDs per game version? Using class and subclass reuses the Category module.

## Left to the builder

- Exact record fields, ids and serialization.
- The matching tolerance between exact times and log times, within the "about an hour" rule.
- The preset list contents, the points rounding, and the alert timing details, such as how long an alert stays on screen.
- Layout details within the approved mockups.
