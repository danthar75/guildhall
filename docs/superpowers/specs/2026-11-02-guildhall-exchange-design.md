# Guildhall: core + Exchange module — design

Date: 2026-11-02. Target: WoW Forever 1.60.1 (TOC 16001), launching 2026-11-04.
API research: `reference/notes/restrictions-summary.md` (start there), `reference/notes/restricted-api-index.md`.

## Intent

Guildhall is a guild-helper addon for WoW Forever. It's meant to work for any guild. The first guild using it is **Emergence**; the name may change, because they hope to get it in-game without special characters.

The guild runs a Discord server with an `#exchange` channel in its "Raid" category. Members use it to buy and sell among themselves, so **gold stays inside the guild**. The guild leader's pinned format is:

```
LF [item]
I [will / will not] provide materials
I am [open / not open] to CoD
```

WoW addons have no network access and can't reach Discord. So the **Exchange** brings that board into the game. Members post and browse listings in-game, the listings reach other members who run Guildhall, and any listing can be copied as ready-to-paste Discord text in the pinned format.

The user plans to add **other features later that aren't known yet**. So Guildhall is a **core plus modules**, and the Exchange is the first module. The core must not assume the Exchange is the only thing it hosts.

## Goals

1. A shared, in-game board of buy (LF) and sell (WTS) listings among guild members who run Guildhall.
2. Listings stay visible when their poster is offline, and they expire after 7 days.
3. Each listing shows whether its poster is online right now.
4. Filling a listing takes one click: a pre-filled whisper if the poster is online, a pre-filled mail if they're offline.
5. Any listing can be copied as Discord text in the guild leader's format.
6. A core that later modules plug into, giving them settings, guild context, messaging, storage, a UI shell and theming.
7. Guild-agnostic: no Emergence-specific values in code.

## Non-goals (v1)

- Any connection to Discord, or a companion app outside the game. ("Option 2" was discussed and deferred. The core shouldn't make it hard later.)
- Pricing help, auction house scanning, price history.
- Escrow, trade automation, or sending mail, gold or items on the user's behalf.
- Showing listings to guild members who don't run Guildhall. They see them only through Discord copy-paste.
- Cross-guild or cross-realm listings.
- Real guild branding art. See "Theming".

## Anti-goals (failure even if it "works")

- **Guildhall never sends a whisper, a mail, or a chat message by itself.** It only pre-fills, and the user presses Enter or Send. (This is the user's choice, and it also avoids Blizzard's restrictions on addon-initiated chat, mail and emotes.)
- No reliance on comms side channels or workarounds that Blizzard is patching (aura IDs, pings, AFK flags, Club API tricks). Use only the guild addon channel.
- Nothing that touches combat data. The Exchange has no reason to.
- No Lua errors inside dungeons or raids. Guild and comms data can turn secret there (see Constraints), and the addon must degrade quietly.
- No Emergence-specific values hard-coded.

## Constraints (from the API research)

- **Client:** Forever runs the modern Mainline client with Midnight's "secret values" restrictions. Use the retail-style API, not Classic.
- **TOC:** `## Interface: 16001`, `## AllowLoadGameType: forever`, and the required `## ExcludeLoadGameType: standard, classic`. The shippable addon lives in `Guildhall/Guildhall.toc` under the project root.
- **Comms:** `C_ChatInfo.SendAddonMessage` on the `GUILD` channel.
  - It returns `Enum.SendAddonMessageResult`. `AddOnMessageLockdown` (11) means the send was blocked, and the addon must queue the message and retry later rather than treat it as an error.
  - Sending is restricted during chat lockdown: encounters, M+, PvP matches, and probably anywhere in a dungeon or raid. The exact rule between raid pulls is unconfirmed, so test it in-game. Check `C_RestrictedActions.GetAddOnRestrictionState(Enum.AddOnRestrictionType.Chat)` before sending.
  - **Trial accounts can't send addon messages.** They can browse, but posting must fail gracefully with a clear message.
  - Messages are limited to 255 bytes, and Blizzard throttles addon traffic, so pace sends and split large payloads.
- **Guild roster:** `GetGuildRosterInfo` / `C_GuildInfo.GuildRoster()` and the `GUILD_ROSTER_UPDATE` event. They have no restriction flags in the index. However, Club member data (and notes) is secret during chat lockdown, so expect roster-derived data to be unreliable inside instances and show online status as "unknown" there.
- **Mail:** sending only works while a mailbox is open (`MAIL_SHOW` / `MAIL_CLOSED`). Mail-sending APIs are flagged as restricted, and we don't call them anyway.
- **Secret values:** any value from a guild, club, chat or calendar API might be secret inside instances. Check with `issecretvalue` / `canaccessvalue` before comparing or storing it. Secrets can't be written to SavedVariables; they save as nil.
- **Testing:** the `addonChatRestrictionsForced` and `addonMapRestrictionsForced` CVars simulate lockdown out of combat.
- Lua's `require` is renamed `import` on Forever. This only matters if a library uses it.

## Design decisions (made with the user)

### Architecture: core + modules
- **Core** (`Guildhall`) provides:
  - module registration
  - guild context: current guild name, the player's rank, and "is this player online"
  - storage scoped per guild and per module
  - a messaging layer (prefix, queue, throttling, lockdown awareness, splitting)
  - the main window shell with a tab per module
  - a settings panel each module can add a page to
  - slash commands (`/gh`, `/guildhall`) and a minimap/launcher button
  - theming (see below)
- **Exchange** is a module: its own tab, its own settings, its own message types.
- Adding a second module later must not require editing Exchange code.

### Settings scope *(my call)*
- **Personal settings** (whisper and mail templates, the Discord template, window position, filters) are stored per player, in account-wide SavedVariables.
- **Guild-wide settings** (for v1, only the officer-rank threshold; later, branding) must agree on every client. They're read from a short tag in the **Guild Information text**, for example `[Guildhall officers=2]`. Whoever can edit Guild Info controls them, so no new sync or ownership machinery is needed.
  - `C_GuildInfo.GetInfoText` is flagged as restricted. Read it outside instances, cache it, and use the cache inside instances.
  - With no tag, the default is the top two ranks.

### Ownership: listings belong to the **player**, not the character (user's decision)
- Each player gets a **profile**: a random ID generated once per WoW account, stored in account-wide SavedVariables, plus the list of that account's characters in this guild.
- **Characters are linked automatically** as the player logs into them with Guildhall enabled. *(My call: the first time a character would be shared, Guildhall shows which characters it will link and lets the player unlink any of them. Sharing alts with the guild is a privacy choice, so nothing goes out before the player has seen it. An unlinked character just doesn't appear in their profile.)*
- Profiles (ID plus linked characters) spread over the same sync as listings.
- Effects:
  - **Mine** shows all of the player's listings from any of their characters.
  - Any linked character can edit, remove or renew the player's listings.
  - **The online dot is green if any linked character is online.** The details pane shows which character that is.
  - **Whisper goes to the character that's currently online.** **Mail goes to the character that posted the listing.**
  - Displayed name: the posting character, with the player's other characters listed in the details pane.

### Exchange: listings
Each listing has:
- a type: **LF** (buying) or **WTS** (selling)
- the item: a real in-game item link when the user shift-clicked one from their bags, a tooltip or a chat link. A typed name is allowed as a fallback.
- an optional quantity
- materials: **will / will not provide**
- COD: **open / not open**
- an optional free-text note (price, timing, anything else)
- the poster (character name and realm), posted time, and expiry time (posted + **7 days**)

### Permissions and trust
- The poster (any of the player's linked characters) can edit, remove or **renew** their own listings. Renewing resets expiry to 7 days from now.
- **Trust model (user's decision): guildmates are trusted.** Guard against accidents, stale data and bugs, not against deliberate tampering by someone running a modified copy. A removal or edit relayed by a third party during sync is accepted.
- **Audit log (user's decision): keep a detailed log so that problems can be traced.**
  - Every change a client accepts (create, edit, renew, remove, officer remove, profile link or unlink) is logged locally with:
    - the action
    - the listing ID and version
    - the claimed author (player profile and character)
    - **the character that actually sent the message to us** (the relayer, which may differ from the author)
    - server time
    - before and after values for edits
  - Rejected or ignored messages are logged too (unknown type, failed validation, older version).
  - The log is stored in SavedVariables, capped (default: 30 days or 5,000 entries, oldest first out).
  - It's viewable in-game from a **Log** view with filters by listing, player or character. It can be exported as text in the same copy box as Discord copy, so it can be shared with officers.
  - The log is local to each client and is not synced. Comparing two members' logs is how a problem gets traced.
- **Officers can remove any listing.** *(My call.)* Which ranks count as officers is a **setting** (rank index threshold, defaulting to the guild's top two ranks). Nothing is hard-coded.

### Board UI: layout "B" (chosen by the user from mockups)
- Guildhall's own movable window, not hooked into Blizzard's guild frame. (Blizzard frames may have forbidden aspects that block hooking.)
- Tabs: **All**, **Buying (LF)**, **Selling**, **Mine**.
- **Left: the listing list.** Each row shows an LF/WTS tag, the item (in quality color when linked, with a tooltip on hover), a green, grey or unknown online dot, the poster, and the time left.
- **Right: the details pane** for the selected listing. It shows the type and item, the poster with online status, "I will / will not provide materials", "I am open / not open to COD", the note, posted and expiry times, and buttons:
  - **Whisper** when the poster is online, or **Mail** when they're offline
  - **Copy for Discord**
  - Edit / Remove / Renew on your own listings, and Remove for officers
- A **+ New listing** button opens the posting form with the fields above.

Mockup: `.superpowers/brainstorm/4231-1793621056/content/board-layout.html` (option B).

### Filling a listing
- **Whisper** (poster online) opens the chat edit box pre-filled with a whisper to the poster, for example: `Hi! Saw your Guildhall listing for [item]. Are you still looking?` (with the wording adjusted for WTS listings). The user edits it and presses Enter.
- **Mail** (poster offline):
  - At a mailbox, Guildhall switches to the Send Mail tab and fills in the recipient, subject (`Guildhall: [item]`) and body. The user attaches items, gold or COD and clicks Send.
  - Away from a mailbox, it saves a **mail draft** and says so. The next time any mailbox opens, it offers to fill in the oldest pending draft. The user can dismiss a draft.
- Message templates are module settings, with the defaults above.

### Loading an item into a listing (added 2026-11-04)
- The new/edit form has an **item slot**: an icon button, with the item name in its quality color beside it.
- **Shift-click** an item in the bags, a profession window or the auction house to load it into the slot. All three send links through `ChatFrameUtil.InsertLink` on Forever (`ChatEdit_InsertLink` no longer exists). Guildhall post-hooks it with `hooksecurefunc` and captures the link while the form is open.
- **Drag and drop** from the bags onto the slot also works (`GetCursorInfo`). *(My call.)*
- The icon and quality are looked up locally from the link (`C_Item.GetItemInfoInstant`, `C_Item.GetItemIconByID`). Only the link is stored and synced.
- If a profession shift-click gives a recipe link instead of an item link, Guildhall resolves it to the crafted item where the API allows; otherwise it falls back to the typed name. *(My call. Confirm on Forever.)*
- A clear (X) button empties the slot. A typed name is still accepted.

### Import from Discord (planned; built once real posts exist)
While the user is the only one running Guildhall, they need to bring the existing `#exchange` posts into the board.
- The user copies posts from Discord and pastes them into an **Import** box in the Exchange tab. The box is the copy dialog in an editable paste mode.
- Guildhall parses each post in the pinned format (`LF/WTS [item]`, the materials line, the CoD line, an optional note) and tries to capture the Discord poster's name.
- A **preview** lists every listing it found, plus any text it couldn't parse, so the user can fix or skip it. Nothing is created until the user confirms.
- Imported listings carry `src = "discord"` and the Discord poster's name. When the matching in-game character is known, Whisper and Mail work as usual; otherwise the details pane shows "posted on Discord by X".
- *(My call.)* Imported listings live in a **separate, local-only store** that the board merges in. They never sync and never count as the importer's own listings. Whether to share them once others run Guildhall is an open question for the user, to be settled when this is built.
- The parser lives next to the Discord formatter, so writing and reading the format stay in step. It is built against **real pasted samples** saved as test fixtures, so it isn't written until `#exchange` has posts (after launch).

### Copy for Discord
This opens a small box with the text already selected so the user can press Ctrl+C. (Addons can't write to the clipboard directly.) Format, matching the pinned post:

```
LF Robe of the Archmage
I will provide materials
I am open to CoD
Note: have the cloth, need a tailor. Tipping 20g.
(Thalwyn, in game via Guildhall)
```

- WTS listings start with `WTS [item]`.
- Quantity, when present, follows the item (`x40`).
- Item links are reduced to plain names, because Discord can't show WoW links.
- The template is a setting, so a guild with a different pinned format can change it.

### Sync behavior
- Listings spread among online members running Guildhall over the `GUILD` addon channel. Each client keeps a local copy in SavedVariables, scoped per guild, so the board survives the poster logging off.
- On login, and after leaving a restricted area, a client syncs with whoever is online to catch up on listings it missed.
- Edits and removals propagate the same way. A removed listing has to stay recorded until its original expiry so that stale copies don't bring it back.
- Expired listings are dropped locally by every client. No messages are needed for that.
- Inside chat lockdown, outgoing messages are queued and sent once the restriction lifts, and the UI keeps working from local data.

### Theming (branding: see "Guild branding" below)
The user wants guild branding later (Emergence's name, colors and maybe a logo) and isn't sure it matters now. **Decision (my call):** v1 ships a neutral default look, but every visible brand element goes through the core's theme layer:
- the window title text
- accent and border colors
- an optional logo texture slot
- an optional banner line

Branding can then be added later as configuration or a small theme file, without touching module code. No Emergence art in v1.

### Guild branding and the Guildhall logo (added 2026-11-04, from Classic Era testing)
- **Built:** when in a guild, the main window header shows the guild's tabard, drawn with Blizzard's `SetLargeGuildTabardTextures` and the guild frame's own textures, followed by the guild name in gold and a small grey "Guildhall". A guild with no tabard gets Blizzard's "no logo" placeholder. Outside a guild the header reads plain "Guildhall". The user approved the look in game.
- **Logo:** Guildhall gets its own logo, chosen by the user from three concepts on the mockup page. It is used on the minimap button (required by the user), as the addon-list icon (`## IconTexture`), in the header when not in a guild, and on GitHub, the README and the Discord post. In game it ships as one small image file in the addon, and the README's "text files only" safety note says so.

### Board filters (added 2026-11-04; the user approved this design for v1)
- **Category** button next to Search. It opens a small list: All; Crafted, with one entry per profession; Materials; Recipes; Gear; Other. It combines with the All / Buying / Selling / Mine tabs, with Search, and with Member.
- **Member** button. It lists guildmates who currently have listings and filters by player (profile), so alts are included.
- **Profession of a listing**, from most to least certain:
  1. The item was shift-clicked from an open profession window.
  2. The item type implies it. Recipes name their profession; potions, elixirs and flasks mean Alchemy; food means Cooking; bandages mean First Aid.
  3. The poster's choice in an optional Profession picker on the form. The picker is pre-filled from 1 or 2 and can be changed.

  Stored as optional `d.prof`. The profession list and names come from the game where possible, so it holds for Forever.
- **Categories from item class:** trade goods and reagents → Materials; recipes → Recipes; weapons and armour without a profession → Gear (BoE), since soulbound items cannot be traded; anything with a profession (other than recipes) → Crafted / that profession; hand-typed names and everything else → Other. The game has no "crafted" flag, so Crafted means "tagged with a profession".

### Fields that apply per category (added 2026-11-04; the user asked for this)
The form shows only the optional fields that make sense for the item; a hidden field is not stored, and the details pane and Copy for Discord leave its line out.

| Category | "I will provide materials" | Profession picker |
|---|---|---|
| Crafted | shown | shown |
| Materials | hidden | hidden |
| Recipes | hidden | hidden (the recipe implies it) |
| Gear (BoE) | hidden until a profession is chosen, which makes it Crafted | shown |
| Other (incl. typed names) | shown | shown |

COD and quantity always apply. `d.mats` may be nil ("doesn't apply"). The default Discord template uses `{matsLine}`, which is empty in that case.

### Guild leaderboard: a core system fed by modules (planned; user's direction 2026-11-04)
The leaderboard is part of the **core**, not the Exchange. Each module registers the activities it can report, and the leaderboard shows whatever is registered. v1 has only Exchange activities. Later modules (all to be decided and built later) add their own without changing the leaderboard. Examples the user named:
- raid attendance
- gathering events
- transmog events
- other guild events

Shape (my proposal, to be detailed when it's built):
- **Activity types.** A module registers each activity type with:
  - an id
  - a label
  - a unit: count, or gold
  - how it is verified
- **Verification levels.** "Both parties' clients agree" (Exchange deals); "confirmed by an organizer or officer" (likely for events and attendance); "self-reported" (shown, but never counted toward rankings).
- **Credit.** Credit goes to the player (profile), not the character, the same as listing ownership.
- **Shared records.** Activity records sync through the same replicated-set machinery as listings and profiles.
- **Views.** The leaderboard has a period (this week / this month / all time) and one board per activity type. Whether there is also a combined score is still open.

### Deal tracking and leaderboard (planned; design in progress 2026-11-04)
The motivation for the Exchange is keeping gold in the guild. The user wants a guild total of gold kept in the guild, plus a fun leaderboard to promote use: listings posted, purchases, gold earned from guildmates, gold paid to guildmates.
- **Only listing-matched deals count** (user's decision). A deal is a trade-window trade or CoD mail between the poster and a guildmate, for the listed item.
- **Detected automatically by default** (user's decision). Each side's client records what it saw (trade window contents and gold; CoD sent and CoD paid). A deal counts only when both sides' records match, so nobody can inflate the numbers alone. Both parties can also confirm a deal by hand when needed (user's decision), for example gold sent by plain mail. Both people need Guildhall for a deal to count.
- **Anti-gaming:** listings only count toward the leaderboard if they stayed up a while or ended in a deal.
- **APIs:** reading trade and mail details (`GetPlayerTradeMoney`, `GetTargetTradeMoney`, `GetTradeTargetItemLink`, `GetInboxHeaderInfo`) is not restricted on Forever. Only the action APIs are, and Guildhall never calls those. Values go through `Compat:Safe`.
- Still to design: how a deal is matched to a listing, the record format and sync, time windows, and the leaderboard UI.

## Schedule and testing (user's input)

- Forever launches **2026-11-04**. The user can test on Forever at launch. v1 doesn't have to be ready on launch day.
- **Before launch, the user can test on Classic Era.** That can't test the restrictions, but it shakes out UI, sync, storage and logic early.
  - Code goes through a thin **client-compatibility layer** in the core. When missing on the client, `issecretvalue`, `canaccessvalue` and `C_RestrictedActions` fall back to "not restricted". Other API differences are wrapped there too.
  - A **dev-only TOC** (or a Classic Era interface line) lets the addon load on Classic Era for testing. The release TOC targets Forever only, as specified in Constraints.
  - The test checklist marks which items can be checked on Classic Era and which must wait for Forever (lockdown, secret values, trial accounts).
- Library use is fine. Confirm on Classic Era first, and then again on Forever at launch.

## Left to the builder

- The wire protocol: message format, serialization, compression, chunking, prefix name (16 characters or fewer), and protocol versioning. One requirement: older clients must ignore message types they don't understand rather than error.
- Sync algorithm details: anti-entropy and digest exchange, who answers sync requests, jitter and backoff, conflict resolution (for example the latest version per listing ID wins), and the listing ID scheme. Player profiles sync through the same mechanism.
- How two clients that both claim the same character in different profiles are resolved (for example, the most recent link wins and it gets logged).
- Time handling: use server time (`GetServerTime()`) for posted and expiry times so that clients agree.
- Library choices. Using common embedded libraries such as Ace3 (AceComm, AceDB, AceConfig), ChatThrottleLib, LibSerialize, LibDeflate, LibDataBroker and LibDBIcon is fine, as long as each one is confirmed to load on the Forever client.
- Exact widget layout, sizes, sorting (default: newest first) and search/filter box details.
- How the officer-rank threshold is presented in settings.
- Test approach: pure-Lua logic (listing model, expiry, merge rules, Discord formatting, protocol encoding) should be unit-testable outside the game. In-game behavior needs a manual test checklist, including runs with the restriction-simulation CVars.
