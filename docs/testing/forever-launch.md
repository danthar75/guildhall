# Forever launch-day test list

What to test when WoW Forever goes live. Split by whether you can test it on one account or need a second Guildhall client in the guild.

**Plan (user):** the guild is created at launch. Dor runs a second WoW account in the same guild as the "other tester", so everything here can be done without outside help. The goal is to finish within 12 hours of launch, but it isn't a rush at the moment of launch.
- Run both clients at once, each with a character in the guild and Guildhall installed.
- The guild master (rank 0) counts as an officer. To test non-officer views, put the second account's character at a low rank.
Full step-by-step details for each item are in `in-game-checklist.md`; this file is the short list and the order to do it in.

Before starting: `/console scriptErrors 1` (or BugSack), and install Guildhall into `_forever_/Interface/AddOns/Guildhall`.
New files (like the logo) need a full game restart, not just `/reload`.

## Order on launch night

1. Solo: **Loading**, then your half of `/gh names` (save the output).
2. On the second account: the other half of `/gh names`. **This is the release blocker.** If it passes, the first release can go out (Dor confirms first).
3. Everything else below, in any order.

## Solo (no other testers needed)

### Loading and look
- [ ] Loads with the release TOC (`Guildhall.toc`) with no Lua errors, on login and after `/reload`.
- [ ] Your half of `/gh names`. "Guildhall uses" includes your secondary name (the "Main Secondary" form), and no line shows the "-" link form ("Dor-Ironhand").
- [ ] The Guildhall logo shows on the minimap button and next to Guildhall in the AddOns list.
- [ ] With a guild tabard: the header shows the tabard and "<Guild>  Guildhall". With no tabard yet: the placeholder emblem.
- [ ] Not in a guild yet: one friendly chat line, and the header shows the Guildhall logo instead of a tabard.
- [ ] Popups (form, pick lists, consent, copy box) are solid, not see-through.

### Welcome screen and About tab
- [ ] First open of the window on the account shows the welcome screen on top; closing it and reopening the window does not. Esc closes it.
- [ ] `/gh welcome`, the Settings button and the About tab button reopen it. "Show this next time" brings it back on the next open.
- [ ] The About tab shows the header, feature list, the gnome line ("no more than 10 or 20") and the credit line, and all text renders (no boxes).

### Consent and your own alts
- [ ] Consent dialog on first login in the guild. OK links the character.
- [ ] A second character of yours in the same guild: consent appears for that one only. Details show "Also: <your other character>" on your listings.

### Your own listings
- [ ] Post, Edit, Renew and Remove. Posted and Updated dates show, and the Remove confirmation popups work.
- [ ] Item icons in the list and details, with the standard tooltip on hover.
- [ ] Quality-tier reagents (name with a tier icon) and ordinary items show as coloured links on your own board, not as `||c…` text.
- [ ] Shift-click from bags fills and locks the Name box, and the stack-split popup doesn't stay open.
- [ ] Shift-click a recipe in the profession window: the crafted item loads, or it falls back to a typed name with no error.
- [ ] Drag an item from bags onto the slot (`GetCursorInfo`).
- [ ] The profession window (`ProfessionsFrame`) auto-fills the Profession picker, and names follow the client language.
- [ ] Fields that don't apply hide themselves:
  - materials: no "provide materials" and no profession
  - BoE gear: profession only, then materials once a profession is picked
  - typed name: everything shows
- [ ] Copy for Discord: the text has no materials line for materials listings.
- [ ] After using the form, enter combat: no "blocked action" or taint warnings.

### Board filters
- [ ] Category (with professions under Crafted), Member, Search and the tabs all combine. Reset appears only while something is filtered, and puts everything back.
- [ ] Esc closes a pick list without closing the window behind it.

### Mail and chat
- [ ] Mail on a listing while at a mailbox fills To, Subject and Body (`SendMailNameEditBox` etc.). Nothing is sent. You can use your own alt's listing for this.
- [ ] Away from a mailbox, Mail saves a draft. The next mailbox offers Fill in, Later and Dismiss.

### Forever restrictions
- [ ] `/console addonChatRestrictionsForced 1`, then post: "It will reach guildmates when chat restrictions lift", with no error. Set it back to 0.
- [ ] `/console addonMapRestrictionsForced 1`: the online dots show unknown, with no errors. Set it back to 0.
- [ ] Inside a dungeon: no Lua errors, the window opens, and no false "guild changed" message.

### Release zip (once built)
- [ ] Install from the release zip into a clean `AddOns` folder. It loads, and the folder has no `Guildhall_Vanilla.toc`.

## Needs a second client (your second account in the guild)

### Release blocker
- [ ] **`/gh names` on both characters, at the same time.** Your sender name as the *other* client lists it under "Recent addon senders" must match what Guildhall uses (realm suffix aside), and the same in reverse. Save both outputs.

### Sync between players
- [ ] Their listing reaches you within a few seconds, and yours reaches them. The same goes for edits, renews and removes.
- [ ] Their listing shows the right icon, coloured link and tooltip on your client, including quality-tier reagents.
- [ ] Online dot is green while they're online and grey after they log off.
- [ ] Member filter lists both of you. Their alts are grouped under one name.
- [ ] After a forced chat restriction lifts (or after you leave a dungeon), your queued listing reaches them, and the board catches up.
- [ ] One of you logs in late: the board catches up fully, and the log shows no "too large" entries.

### Contacting a poster
- [ ] Whisper on their listing opens chat with `/w Name …` (their "Main Secondary" name works as a whisper target). Nothing is sent.
- [ ] Mail on their listing fills To with a name the mail system accepts.

### Officers
- [ ] An officer (`[Guildhall officers=N]` in Guild Info) sees "Remove (officer)" on the other person's listing, and it works. A non-officer never sees it.

## Leaderboard

Needs Forever. Account A and account B are your two accounts, both in the guild with Guildhall. Give B a low rank (not an officer) unless a step says otherwise. Run `/console scriptErrors 1` on both. After each step, open the Leaderboard tab and use `/gh log` to see what happened.

### Solo

- [ ] **Tab, periods and opting out.** Open the Leaderboard tab. Click Week, Month, All time and Past months. Expected: each switches with no Lua error, and your own row shows your breakdown. In Settings, turn off "Show me on the leaderboard": your row disappears from the list, and the guild total still counts you.
- [ ] **Guild bank deposits (needs a guild bank tab, which may need gold).** Deposit an item into a tab, then open the bank so the log loads. Expected: the Log tab shows an "observations" line of counts, and moving an item between tabs adds nothing.
- [ ] **Secret values.** Open a trade window, the mailbox and the guild bank inside an instance (or with `/console addonChatRestrictionsForced 1` and `/console addonMapRestrictionsForced 1`). Expected: no Lua errors and no half-recorded entries. A skipped read is simply not recorded.
- [ ] **Glyph check.** Open the Leaderboard tab, its settings and the Past months list. Expected: every label, button and number renders as real text, with no empty boxes or question marks.
- [ ] **Demo mode.** Type `/gh lbdemo`. Expected: the tab shows an orange "Demo data, not real. /gh lbdemo off" banner, 12 made-up players, and data under Week, Month, All time and Past months. Type `/gh lbdemo off`, or `/reload`: real data returns, and nothing was sent (the other account sees nothing).
- [ ] **Change history box.** As the guild master (or a rank granted "Edit leaderboard weights"), change a weight in Leaderboard settings and save. Expected: Settings > Change history shows the line with a server-time date (and Settings > Permissions under "Recent changes"); with more lines than fit, the mouse wheel scrolls the list.
- [ ] **Rank names from the game (`GuildControlGetRankName` on Forever).** Open Settings > Permissions. Expected: the columns are your guild's rank names in rank order, Guild Master first, with no "Rank N" placeholders. If you see "Rank N", run `/dump GuildControlGetNumRanks(), GuildControlGetRankName(1)` and note what it prints (nil or a secret value means the fallback to roster rank names is in use).
- [ ] **Guild master only by default.** Before anyone has saved permissions: as the guild master, every Permissions checkbox outside the Guild Master column is enabled and unticked, and the Guild Master column is ticked and greyed out. As an officer on the same account's alt (or any non-guild-master), the grid is read-only, there are no Save or Reset buttons, the weight boxes in Leaderboard settings are read-only, and the past month view has no Retake button.
- [ ] **Bank review list.** As the guild master, open Settings > Leaderboard and press "Bank review". Expected: every recorded bank deposit and withdrawal, newest first, with server-time dates; the player, tab and month filters and "Show excluded only" narrow it; the mouse wheel scrolls it 14 rows at a time; all text renders (no empty boxes). On a rank without "Review bank contributions" the button isn't there.
- [ ] **Guild Info tags.** In Guild Info, write `[Guildhall donations=3,4]` (and `[Guildhall bankexclude=0,1]`). Expected after `/reload`: tabs 3 and 4 count, and ranks 0 and 1 never count. A space after a comma (`donations=3, 4`) is also read correctly, but write tags without spaces to be safe. No tag means all tabs count.

### Needs a second client (your second account)

- [ ] **`TRADE_ACCEPT_UPDATE` fires with (1,1) when both players accept on Forever.** On A run `/etrace` filtered to TRADE_ACCEPT_UPDATE, open a trade with B, put something in, and have both press Accept. Expected: the last event shows `1, 1`. If it shows something else, the trade pairing needs a different completion check.
- [ ] **Trade deal pairs.** Post a listing on A, then trade the item to B for the listed gold. Expected: both clients log an "observations" line, and the deal appears on both Leaderboards (sales for A, purchases for B).
- [ ] **CoD mail pairs.** On A, post a CoD listing. Send a CoD mail with one attachment to B, then take it on B. Expected: both sides publish a CoD observation (the Log tab shows an "observations" line on each), and the deal pairs on the Leaderboard on both clients.
- [ ] **Guild bank needs a second reader.** On A, deposit an item. Expected: nothing counts yet. On B, open the guild bank so B reads the log. Expected: the deposit now counts for A, and moves between tabs and ranks from `bankexclude` don't count.
- [ ] **Opt-out hides you on other clients.** On A, turn off "Show me on the leaderboard". Expected: on B, A disappears from the list within a minute (their activity still counts toward the guild total). Turn it back on and A returns.
- [ ] **Record a deal needs confirmation.** On A, use Record a deal for a trade with B. Expected: it shows "waiting for the other player to confirm" until B confirms, then counts for both.
- [ ] **A listing is witnessed.** Leave a listing up for 24 hours. Expected: the other account counts as a witness, and A's listings posted goes up by 1.
- [ ] **A non-officer sees counts only.** With B at a non-officer rank: B sees totals for others, can open only their own breakdown, and in B's Log tab observation entries read "received N (trade 2, bank 10)" with no names or amounts. An officer's Log tab shows the full entries.
- [ ] **Granting Officer the weights.** On the guild master account (A), tick Officer under "Edit leaderboard weights" and press Save. Give B the Officer rank. Expected: A's Settings > Change history shows "Permission Edit leaderboard weights: added Officer", after A's name and "[Guild Master]". On B, within a minute, the weight boxes become editable; change a weight and publish. Expected: A shows the new weight and B's line in Change history. Then on A untick Officer and Save: B's weights become read-only again, and B's earlier weight change stays in effect.
- [ ] **Bank review: untick a deposit.** On A (guild master), open Bank review, untick a deposit made by B, type "moving guild funds" and press OK. Expected: B's score drops by that deposit on both clients, while the guild total (gold kept, bank boards' guild figures) stays the same. A's Settings > Change history shows "Bank entry <date> B <amount> deposit: excluded · moving guild funds". Tick it again: B's score comes back and the history shows "Bank entry <date> B <amount> deposit: counted again".
- [ ] **Bank review: the reason reaches the member.** After unticking B's deposit on A, open B's own breakdown on B. Expected: under "Not counted" the deposit reads "... · Excluded by an officer: moving guild funds", with no officer name on B (a non-officer). An officer viewing it also sees who excluded it.
- [ ] **A non-officer's Log hides bank reviews.** After A unticks B's deposit, open the Log tab on B (non-officer). Expected: the exclusion and its history entry each read "<time> | bank review | received", with no officer name, profile id or reason; typing A's name in the filter does not find them. On A (officer) the full entries show.
- [ ] **Month save waits for sync to settle.** On A (guild master or officer), stay offline for a few days of a finished month, then log in at least 3 days after the month ends while B is online. Expected: the month is not saved at 90 s while observations are still arriving; it is saved once the Log has been quiet for a minute (within 15 min of login), and Past months then matches what B shows. If sync never goes quiet within 15 min, nothing is saved that session.
- [ ] **Fresh install catches up on permission-dependent records.** With a rank granted "Review bank contributions" and an exclusion made by that rank, install Guildhall fresh on B (delete its SavedVariables) and log in. Expected: within about two minutes B shows the exclusion (the member's score drops on B too) with no /reload, and B's Log shows at most one "author lacks permission" line for it.
- [ ] **Long message check (later).** In a test guild (or later, once the real guild has 5 or more saved months), install Guildhall fresh on one account and log in. Expected: it receives every saved month, with none missing from Past months.

### Beta label

- [ ] **Beta label shows.** On the character screen's AddOns list the addon reads "Guildhall (Beta)". The welcome screen and About tab show "Version 0.1.0 (beta)" and the orange beta note.

## Groups

### Solo

- [ ] **Which BFD encounter ids fire.** Run `/etrace` filtered to ENCOUNTER_END, then kill bosses in Blackfathom Deeps. Expected: the first value is in 2761-2767 (Aku'mai 2767) or in 2910-2916 (Aku'mai 2910). Note which set fires; Guildhall accepts both, and the unused set can be dropped later.
- [ ] **Optional bosses map to the right wing.** With `/etrace` filtered to ENCOUNTER_END, kill Postmaster Malown (2798) and Skul (2799) in Stratholme, and Tsu'zee (2794) and Lord Hel'nurath (2793) in Dire Maul. Expected: Malown and Skul are on the Live side (Strat Live), Tsu'zee and Hel'nurath in Dire Maul West. If a boss was in the other wing, move its id in `Modules/Groups/Instances.lua`.
- [ ] **Calendar reads with another month open.** Open the calendar UI on a different month, then relog or `/reload`. Expected: guild events for today through 14 days ahead are still read correctly.
- [ ] **Calendar event maps to its raid.** Create guild events for a raid (e.g. MC) and one with only the raid name in the title. Expected: each maps to its raid, through the instance id or through the title.
- [ ] **Calendar time is server time.** Create a guild event at 20:00 server time. Expected: it shows at 20:00 server time on the board.
- [ ] **Dungeon details layout, every section full.** Post a dungeon run with a long note and a "Needs" item, assign 4 players, and have 5 more sign up (guildmates or alts on other accounts). Select it as the poster. Expected: the title, "Posted by" line, "Needs:" link, 5 group rows, "Signups waiting" with "+2 more" at its right, 3 signup rows with T/H/D and Invite, the 2-line credit footnote and the 3 buttons don't overlap, and no text is clipped at the panel edge.
- [ ] **Raid header and roster columns.** Select a scheduled MC post or calendar event that has a checklist with 3+ lines. Expected: the header ("<date> server time · N accepted · in raid now: X (Y guild) · bosses k / n") wraps onto two lines above the checklist button, and the Raider, 1-3, Prepared and Flex columns line up under their headers. Long names are truncated, the Prepared checkbox and the "Ask to switch" button don't overlap, and the footnote clears the bottom buttons.
- [ ] **New post form layout and scheduled time.** Click "+ New post", pick Molten Core, then pick Scheduled, tomorrow, and a time 1 h from now in server time. Expected: Still need shows 2/8/29 for DPS, nothing overlaps or clips (the hint, the day button and the time box, the note counter, the item slot, the reminder checkbox, the preview line), and the posted run shows on the board at the time you typed, in server time. Then post with a time earlier today. Expected: "Pick a time in the future."
- [ ] **Shift-click fills the post form and the checklist editor.** With the form open, shift-click an item in your bags. Expected: "Run needs" shows its name and icon, and no stack-split popup stays open. Do the same with the checklist editor open (Edit checklist on a raid): the Item box shows the name, and Add item adds "N × name".
- [ ] **Settings sub-tabs and Groups settings.** Open Settings. Expected: sub-tabs General, Exchange, Leaderboard, Groups, Permissions and Change history, nothing clipped. Under Groups, untick "Remind me 15 min before runs I signed up for", /reload, and check it stays unticked; sign up for a run starting in 20 min: no reminder. Tick it again with "Play a sound with reminders" off: the reminder prints with no sound. Tick Tank and Healer under "My usual roles": "I'm ready now" and Sign up offer "My usual roles (T/H)", and the new post form starts on Tank. Unticking the last role is refused with "Keep at least one role."
- [ ] **Change history sub-tab.** As the guild master, open Settings > Change history. Expected: each row reads "<date time>  <name> [<rank name>]  <change>" in server time, newest first, and the mouse wheel scrolls the list. On a member with no permission it reads "Only officers and the guild master can see the change history."
- [ ] **Checklist editor saves.** As an officer, open Edit checklist on an MC post, add an item line, "All gear enchanted" and a text line, and save. Expected: the checklist button and columns show the new lines; a 13th line is refused with "A checklist holds at most 12 lines."
- [ ] **`ENCOUNTER_END` for a 5-player boss.** Run `/etrace` (or `/gh debug`) filtered to ENCOUNTER_END and kill a dungeon boss. Expected: it fires with the encounter id as the first value.
- [ ] **Final boss id matches `Instances`.** Kill the last boss of a dungeon. Expected: its id is the one listed for that dungeon in `Modules/Groups/Instances.lua`, and the run counts as finished.
- [ ] **Dual spec.** Check whether dual spec exists on Forever (`/dump GetNumTalentGroups and GetNumTalentGroups()`). Expected: if it does, switching spec fires an event (note which, e.g. ACTIVE_TALENT_GROUP_CHANGED); if not, spec switching is simply not offered.
- [ ] **Calendar outside an instance.** Stand in the open world. Expected: guild events and your own invite status are read and show on the Groups tab.
- [ ] **`UnenchantedSlots`.** Equip a piece with no enchant, then an enchanted one. Expected: the Prepared check reports the unenchanted slots correctly, with no Lua error.

### Needs a second client (your second account)

- [ ] **Boss kill pairs.** Both clients kill a boss together (with a third and fourth player for the 3-of-5 majority on a dungeon). Expected: the kill pairs, the 3-of-5 majority applies, and credit shows on the leaderboard.
- [ ] **Post and signup sync, reminder fires.** Post a run on A, sign up on B. Expected: both appear on the other client within a few seconds, and the 15-minute reminder fires on B.
- [ ] **Prepared confirm and Ask to switch.** On A (raid leader), confirm B as Prepared and use Ask to switch. Expected: both work end to end, B sees the request and the result reaches A.
- [ ] **Permission change is recorded.** The guild master (A) changes a Groups permission. Expected: the officer client (B) sees the history line under Settings > Change history.
