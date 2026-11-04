# Guildhall: Guild Leaderboard v1 (design)

Status: draft for review, 2026-11-04. Author: Claude, from conversation with Jon Roberts ("Dor").

Related:
- Parent design: `2026-11-02-guildhall-exchange-design.md` (core, Exchange, sync, trust model). Everything there still holds unless this document says otherwise.
- Labels used below:
  - **(user)**: the user decided it.
  - **(my call)**: Claude decided it, and the user can override.

## Intent

The Exchange exists to keep gold inside the guild (user). The leaderboard makes that visible and fun, so more members use Guildhall:
- one number for the gold the guild kept, and
- rankings of who contributes (user).

It is also the start of a general **guild contributions** system. Later Guildhall modules will add their own activities without changes to the leaderboard (user). Examples:
- raid attendance
- gathering events
- transmog events
- other guild events

## Goals (v1)

1. **A core leaderboard system.** Modules register activity types and report activity; the leaderboard shows whatever is registered (user).
2. **Exchange activities.**
   - listings posted
   - purchases (deals as buyer)
   - sales (deals as seller)
   - gold earned from guildmates
   - gold paid to guildmates

   All of these count only for deals that match a Guildhall listing (user).
3. **Guild bank contributions.** Items and gold deposited into the guild bank (user). Tracked by the core, not by Exchange (my call): the bank isn't an Exchange concept, and later modules may also want it.
4. **Both views:** a board per activity, and an overall ranking using points per activity (user).
5. **A headline guild total:** "gold kept in the guild". This is the sum of verified Exchange deal gold plus net gold donated to the bank (my call: both are gold that stayed in the guild).

## Non-goals (v1)

- Any activity other than Exchange and the guild bank. Raids and events come later. The registration API must support them, but v1 ships none.
- Giving items a gold value. There is no auction-house scanning, a non-goal inherited from the parent design. Bank items count as items.
- Rewards, prizes or anything that sends gold or items. Guildhall still never acts for the player.
- Cross-guild boards, or showing other guilds anything.

## Anti-goals (it fails if…)

- **The board can be easily inflated.** Fake listings, self-deals, deposit-and-withdraw loops, and the guild master reorganising the bank (user) must not earn rank.
- **It shames people or surprises them.** Players can choose not to appear on the board. Their activity still counts toward the guild total, anonymously (my call).
- **It nags.** Automatic detection is the default (user); manual confirmation exists only as a fallback (user).

## Constraints

- Forever client (TOC 16001, modern Mainline API, Midnight "secret values" restrictions). See the parent design and `reference/notes/restrictions-summary.md`.
  - The APIs used here are readable and not restricted:
    - Trade: `GetPlayerTradeMoney`, `GetTargetTradeMoney`, `GetTradePlayerItemLink`/`Info`, `GetTradeTargetItemLink`/`Info`, `UnitName("NPC")`
    - Mail: `GetInboxHeaderInfo`, `GetInboxItemLink`, `GetSendMailCOD`, `GetSendMailItemLink`
    - Guild bank: `QueryGuildBankLog`, `GetNumGuildBankTransactions`, `GetGuildBankTransaction`, `GetNumGuildBankMoneyTransactions`, `GetGuildBankMoneyTransaction`
  - Only action APIs are restricted, and Guildhall calls none of them.
  - Every value read goes through `Compat:Safe`. A secret value means "unknown, skip".
- Classic Era 1.15.9 is the dev test client. The same APIs exist there.
- Both people in a deal must run Guildhall for it to count (user, accepted).
- Sync uses the existing machinery:
  - ReplicatedSet records `{id, v, t, by, char, exp, del, d}`
  - Sync REQ/REC over the guild addon channel, ≤255-byte messages, chunked
  - paged digests
- Credit goes to the **player (profile)**, not the character, the same as listing ownership.
- Guild-agnostic: nothing is Emergence-specific in code. Emergence's donation tab is configured, not hard-coded.

## How activity is recorded and verified

### Common model (my call)

**Activity type.** A module registers each type with:
- `id`, e.g. `exchange.deal.gold`
- label
- unit: `count`, `gold` (copper) or `items`
- verification level:
  - `paired`: two different players' clients report matching observations
  - `confirmed`: an officer or organizer confirms (reserved for future events and attendance)
  - `self`: shown, but never ranked or added to totals

**Observations.** An *observation* is one client's report of something it saw. Observations sync as records in a new replicated set, `core.observations`.

**Contributions.** A *contribution* is derived locally from observations, never synced itself. Every client computes the same contributions from the same synced observations, so results converge without a separate authority.

**Retention.** Observations expire after 400 days. "All time" therefore means the last 400 days. A monthly roll-up may replace old observations if storage demands it; that's left to the builder.

### Exchange deals

A deal is a completed transfer between a listing's owner and another guildmate, for the listed item.

**Matching a transfer to a listing (my call):**
- The listing is active, or was removed or expired at most 48 hours earlier.
- One party owns it (its profile) and the other is a different profile.
- The listed item's item ID appears among the transferred items, moving in the listing's direction:
  - WTS: the item goes from owner to partner, and gold from partner to owner.
  - LF: the item goes from partner to owner, and gold from owner to partner.
- Hand-typed listings (no item link) can't be matched automatically and only count through manual confirmation.

**Trade window:**
1. When both sides have accepted, snapshot both sides: items with count, gold, and the partner from `UnitName("NPC")`.
2. On trade completion (`UI_INFO_MESSAGE` with `ERR_TRADE_COMPLETE`), each client publishes an observation: `{kind="trade", listing, seller, buyer, itemID, count, copper, at}`.

**CoD mail:**
- **Seller side:** the client observes sending a mail with a CoD amount and an attachment matching the listing. Hook `SendMail` (post-hook) and read `GetSendMailCOD` and the attachments.
- **Buyer side:** the client observes taking a CoD attachment from a mail sent by the listing's owner or partner. Hook `TakeInboxItem` / `AutoLootMailItem` (post-hook) after reading `GetInboxHeaderInfo`.
- Each publishes `{kind="cod", …}` with the same fields.

**Pairing:** a deal is verified when observations from **both** profiles exist for the same listing, with:
- the same itemID
- the same count
- the same copper
- `at` within 15 minutes for a trade, or 30 days for CoD (CoD is paid when the buyer opens the mail)

One verified deal yields:
- seller: +1 sale, +copper earned
- buyer: +1 purchase, +copper paid
- the guild total: +copper

**Manual confirmation (user):** for deals that weren't detected, such as gold sent by plain mail or a typed-name listing:
1. On a listing, either party can click "Record a deal" and enter the partner, quantity and gold.
2. That publishes an observation with `kind="manual"`.
3. The other party gets a prompt "Brakka says you bought 40 Runecloth for 40g. Confirm?". Accepting publishes their matching observation.

Unmatched manual observations expire from the prompt queue after 14 days.

**Listings posted:** a listing counts once for its owner if it:
- stayed up at least 24 hours, or
- ended in a verified deal.

This blocks post-and-delete spam (my call).

**Witness rule (my call, from the builder check).** Only the owner creates a listing, so on its own it would be `self` and unranked. Instead, the first other client that holds the listing record when it is at least 24 hours old publishes a small *witness* observation. A client skips this if a witness already exists. One witness from a different profile makes the activity `paired`. The witness is permanent (400 days), unlike the listing record itself, which is purged at expiry.

**Self-deals:** deals between two characters of the same profile never count, by definition (different profiles required).

### Guild bank contributions

**What the game gives:**
- per-tab item logs: deposit / withdraw / move, with player name, item, count and a relative time ("N hours ago")
- a money log: deposit / withdraw / repair / buyTab, with player name, amount and relative time
- logs are readable only while the bank is open, and keep only recent entries

**Recording (my call):**
- **Log readers.** Whenever a Guildhall user has the bank open, their client queries the logs of the tabs it can see. It publishes each **deposit** entry it hasn't already published as an observation:

  `{kind="bank", tab, type, player, itemID|nil, count|copper, approxAt}`

  `approxAt` is the server time minus the relative age, so it is only accurate to the hour.
- **Withdrawals** are published the same way, so contributions can be netted.
- **Moves are ignored entirely.** Reorganising the bank never counts (user's blacklist case).

**Verification:**
- A bank entry counts when it has been reported by at least two different players' clients, or by one client that isn't the depositor (`paired`).
- The donor's own client may also report it. That alone is not enough.
- Duplicate log readings of the same entry are merged by `(tab, type, player, itemID, count, approxAt rounded to the hour, ordinal among identical entries)`.

**Who gets credit (my call, from the builder check).** Bank entries are logged by character name. A deposit is credited to a player only if its character is a **linked character of a consenting Guildhall profile**. All other deposits count toward the **guild total only** and never appear on a board:
- guild members who don't run Guildhall
- players who haven't given consent yet
- alts a player chose not to link

The reasons:
- Non-users can't opt out, so ranking them would surprise them.
- Crediting an unlinked alt would reveal a link the player declined.

Bank observations are therefore keyed by character name, and resolved to a profile at display time.

**Netting:** contribution per player per period is net:
- gold: deposits minus withdrawals, floored at 0
- items: per item ID, deposits minus withdrawals, floored at 0

So withdraw-and-redeposit loops add nothing (user's blacklist case).

**Officer configuration**, in the Guild Info text, the same mechanism as `[Guildhall officers=N]`:
- `[Guildhall donations=3,4]`: only these tabs count (Emergence's planned donation tab, user). With no tag, all tabs count.
- `[Guildhall bankexclude=0,1]`: deposits by these rank indexes never count, for example the guild master's bank alts (user's blacklist case).

## Rankings and scoring

**Per-activity boards (user):** one board per registered activity type. Each ranks players by that activity's value in the selected period.

**Overall ranking (user):** each player's score is the sum over activity types of `value × weight`.
- Gold-unit activities are weighted per gold, not per copper.
- Items are weighted per item, with an optional per-item override list. That's left to the builder; v1 may use a flat per-item weight.

**Default weights (my call)**, so it works before officers touch anything:

| Activity | Weight |
|---|---|
| Listings posted | 1 |
| Sales | 5 |
| Purchases | 5 |
| Gold earned | 0.1 per gold |
| Gold paid | 0.1 per gold |
| Bank gold | 0.2 per gold |
| Bank items | 0.05 per item |

**Who sets the weights:** each guild sets its own weights (user). Officers do it in the Settings tab (my call).
- Weights are published as an officer-authored config record in that guild's own replicated set, the same per-guild storage as listings. Each guild therefore has independent weights, and changing them never affects another guild.
- Other clients accept a record only if its author is an officer of that guild, using the existing officer check. The newest accepted version wins.
- Guild Info text is too small for a weight table, which is why the weights don't live there.
- **Coverage:** every registered activity type and contribution type has a weight, including both bank types. A type a future module registers appears in the editor automatically with the module's default weight, until officers change it.
- **Zero weights:** a weight of 0 removes that activity from the overall score but keeps its own board.

**Periods:**
- This week. The week starts at the weekly reset, approximated as Tuesday 15:00 UTC for US. The exact reset rule is left to the builder, ideally from the client.
- This month (calendar month, server time).
- All time (the last 400 days).

## UI (my call, to be mocked up before building)

**Leaderboard tab.** A new core tab between Exchange and Log.

Top of the tab:
- headline "Gold kept in the guild: X g" for the selected period
- period buttons: Week / Month / All time
- a board picker: Overall, then each activity type

**Board.** Rows of rank, player name and value; the Overall board shows points. Players are shown by their currently online character, otherwise their most recently seen character, using the same rule as the Exchange board.
- Your own row is always visible: pinned at the bottom if you're outside the top rows.

**What each viewer sees (user):**
- **Everyone:** totals only. That means the guild headline, and each player's rank and total on every board. No individual deals or bank entries, and no per-activity split of anyone else's score.
- **The player, for their own row:** the full breakdown. That covers each activity's value, its weight and the points it adds, plus the deals and deposits behind each number.
- **Officers:** the full breakdown for every player. Officers are the ranks the guild already marks with `[Guildhall officers=N]`, so there's no new setting (my call).

**Click a row** that you're allowed to see, meaning your own row, or any row if you're an officer, to open its breakdown. It shows:
- per activity: value × weight = points
- under each activity, the counted deals and deposits: date, item, the other party, gold
- items that were excluded, and why, for example "unpaired" or "rank excluded" (my call: this helps officers settle disputes)

**Settings:**
- "Show me on the leaderboard" (default on).
- For officers: the weights editor.

**Exchange integration:**
- After a verified deal, the seller gets a one-line prompt: "Sold? Remove the listing or keep it up?"
- Listing details gain "Record a deal".

## Privacy and trust

- The trust model is the parent design's: guildmates are trusted not to modify their clients. Pairing and netting stop casual gaming, not determined tampering.
- Opting out hides a player's name and row. Their verified activity still adds to the guild total.
- **Visibility is a display rule, not secrecy.** Observations must sync to every client so deals can be paired and totals verified. The UI enforces "totals only", own breakdown and officer breakdown. A member who digs through their SavedVariables file could still read raw records. The Settings privacy note says this plainly (my call: honest about the limit).
- **Log tab:** it must not print observation contents. For non-officers, observation lines show only the type and count, for example "received 12 observations". Officers see full lines.
- **Bank tab permissions:** syncing bank entries could reveal deposits a member can't see in game. Under "totals only" they appear only inside totals. Only officers and the depositor see the individual entries.

## Storage and sync budget

**Sync changes (my call, from the builder check).** The existing paged digest (50 ids per REQ) would cost about 900 messages per login for 5,000 observations, roughly 15 minutes on the shared queue. So `core.observations` gets a **bucketed digest**:
1. A REQ carries one short hash per UTC day, over the `(id, v, t)` of that day's records, keyed by observation time.
2. The receiver compares hashes and asks for id digests only for days that differ.
3. Peers reply with the records for those days.

Notes:
- The listings and profiles sets keep the current protocol.
- No peers are released yet, so this needs no backward compatibility. It must not change the existing sets' wire format.

**Limits:**
- Observations are small, about 100 bytes serialized.
- Target about 5,000 live records for an active guild.
- Purge expired records before building digests.
- Contributions are computed on demand when the tab opens. They can be cached per period, and are never synced.

## Open questions for the user (to settle before planning)

1. ~~What the UI may show~~. Decided: totals for everyone, your own breakdown for you, and everyone's breakdown for officers. See UI, and Privacy and trust.
2. **Testing.** Classic Era has no guild bank, so the bank half and two-player pairing can only be tested on Forever. That needs:
   - a guild with a bank
   - log access
   - a second Guildhall user

   If that isn't available soon, the bank half is accepted on simulated tests only until it is.

## Left to the builder

- Exact record field names and serialization.
- The ordinal scheme for identical bank log entries.
- A roll-up strategy if storage demands one.
- The exact weekly reset rule.
- The per-item weight override list.
- The layout details within the UI described above.
