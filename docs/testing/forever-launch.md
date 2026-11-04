# Forever launch-day test list

What to test when WoW Forever goes live. Split by whether you can test it on one account or need a second Guildhall client in the guild.

**Plan (user):** the guild is created at launch. Jon runs a second WoW account in the same guild as the "other tester", so everything here can be done without outside help. The goal is to finish within 12 hours of launch, but it isn't a rush at the moment of launch.
- Run both clients at once, each with a character in the guild and Guildhall installed.
- The guild master (rank 0) counts as an officer. To test non-officer views, put the second account's character at a low rank.
Full step-by-step details for each item are in `in-game-checklist.md`; this file is the short list and the order to do it in.

Before starting: `/console scriptErrors 1` (or BugSack), and install Guildhall into `_forever_/Interface/AddOns/Guildhall`.
New files (like the logo) need a full game restart, not just `/reload`.

## Order on launch night

1. Solo: **Loading**, then your half of `/gh names` (save the output).
2. On the second account: the other half of `/gh names`. **This is the release blocker.** If it passes, the first release can go out (Jon confirms first).
3. Everything else below, in any order.

## Solo (no other testers needed)

### Loading and look
- [ ] Loads with the release TOC (`Guildhall.toc`) with no Lua errors, on login and after `/reload`.
- [ ] Your half of `/gh names`. "Guildhall uses" includes your secondary name (the "Main Secondary" form), and no line shows the "-" link form ("Dor-Ironhand").
- [ ] The Guildhall logo shows on the minimap button and next to Guildhall in the AddOns list.
- [ ] With a guild tabard: the header shows the tabard and "<Guild>  Guildhall". With no tabard yet: the placeholder emblem.
- [ ] Not in a guild yet: one friendly chat line, and the header shows the Guildhall logo instead of a tabard.
- [ ] Popups (form, pick lists, consent, copy box) are solid, not see-through.

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
- [ ] **Guild Info tags.** In Guild Info, write `[Guildhall donations=3,4]` (and `[Guildhall bankexclude=0,1]`). Expected after `/reload`: tabs 3 and 4 count, and ranks 0 and 1 never count. A space after a comma (`donations=3, 4`) is also read correctly, but write tags without spaces to be safe. No tag means all tabs count.

### Needs a second client (your second account)

- [ ] **`TRADE_ACCEPT_UPDATE` fires with (1,1) when both players accept on Forever.** On A run `/etrace` filtered to TRADE_ACCEPT_UPDATE, open a trade with B, put something in, and have both press Accept. Expected: the last event shows `1, 1`. If it shows something else, the trade pairing needs a different completion check.
- [ ] **Trade deal pairs.** Post a listing on A, then trade the item to B for the listed gold. Expected: both clients log an "observations" line, and the deal appears on both Leaderboards (sales for A, purchases for B).
- [ ] **CoD mail pairs.** On A, post a CoD listing. Send a CoD mail with one attachment to B, then take it on B. Expected: both sides publish a CoD observation (the Log tab shows an "observations" line on each), and the deal pairs on the Leaderboard on both clients.
- [ ] **Guild bank needs a second reader.** On A, deposit an item. Expected: nothing counts yet. On B, open the guild bank so B reads the log. Expected: the deposit now counts for A, and moves between tabs and ranks from `bankexclude` don't count.
- [ ] **Opt-out hides you on other clients.** On A, turn off "Show me on the leaderboard". Expected: on B, A disappears from the list within a minute (their activity still counts toward the guild total). Turn it back on and A returns.
- [ ] **Record a deal needs confirmation.** On A, use Record a deal for a trade with B. Expected: it shows "waiting for confirmation" until B confirms, then counts for both.
- [ ] **A listing is witnessed.** Leave a listing up for 24 hours. Expected: the other account counts as a witness, and A's listings posted goes up by 1.
- [ ] **A non-officer sees counts only.** With B at a non-officer rank: B sees totals for others, can open only their own breakdown, and in B's Log tab observation entries read "received N (trade 2, bank 10)" with no names or amounts. An officer's Log tab shows the full entries.
- [ ] **Long message check (later).** In a test guild (or later, once the real guild has 5 or more saved months), install Guildhall fresh on one account and log in. Expected: it receives every saved month, with none missing from Past months.
