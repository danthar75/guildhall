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

## Later: Leaderboard (once it's built)

Needs Forever. Most of it needs the second account.
- [ ] Solo: the tab opens, the periods switch, your own row shows your breakdown, and opting out hides you.
- [ ] Solo, once the guild has a bank tab (it may need gold to buy one): your guild bank deposits appear as observations, and moves between tabs don't count.
- [ ] With the second account: a trade-window deal matched to a listing pairs and counts for both of you.
- [ ] With the second account: a CoD mail deal pairs and counts.
- [ ] With the second account: "Record a deal" plus their confirmation counts.
- [ ] With the second account: a listing still up after 24 hours gets witnessed and counts.
- [ ] With the second account at a non-officer rank: they see totals only, can open only their own breakdown, and their Log tab shows counts only.
- [ ] With the second account also reading the bank log: bank entries pair. Excluded ranks and tabs don't count.
