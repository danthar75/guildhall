# Guildhall in-game checklist

Manual checks for the WoW-facing parts (frames, events, slash commands). Tags:
**[Era]** can be tested on Classic Era with the dev TOC. **[Forever]** needs the WoW Forever client.
Keep `/console scriptErrors 1` on (or BugSack installed) for every session.
For Forever launch day, the short list split into solo and needs-another-tester is in `forever-launch.md`.

## How to install

- [ ] Classic Era: copy or symlink the `Guildhall/` folder into `World of Warcraft/_classic_era_/Interface/AddOns/`. The game loads `Guildhall_Vanilla.toc`.
- [ ] Forever: copy or symlink `Guildhall/` into `World of Warcraft/_forever_/Interface/AddOns/`.
- [ ] Release zip: contains `Guildhall/Guildhall.toc` and all Lua files, and does NOT contain `Guildhall_Vanilla.toc`.
- [ ] Symlink example (WSL/Linux): `ln -s ~/projects/guildhall/Guildhall "<WoW>/_classic_era_/Interface/AddOns/Guildhall"`. On Windows use `mklink /D`.

## Loading and shell

- [ ] [Era] The addon loads with no Lua errors on login and after `/reload`.
- [ ] [Forever] The addon loads with the release TOC (`Guildhall.toc`), with no Lua errors.
- [ ] [Forever] **Launch blocker: character names.** Forever names are "Main Secondary" (space-separated) on a realmless client. With a guildmate who also runs Guildhall online, run `/gh names` on both characters and save the output. Check: (1) "Guildhall uses" includes the secondary name; (2) it matches "Guild roster (you)" and the sender the *other* client lists under "Recent addon senders" (realm suffix aside); (3) no API shows the "-" link form ("Dor-Ironhand"). If any check fails, name handling in `Compat:PlayerFullName` / `Util.FullName` / `Util.DisplayName` must change before the guild uses the addon.
- [ ] [Era] Not in a guild: one friendly chat line ("not in a guild"), no errors. `/gh` opens the window and the Exchange and Log tabs say "Join a guild to use Guildhall".
- [ ] [Era] `/gh` opens the window. `/gh` again closes it.
- [ ] [Era] `/guildhall` does the same as `/gh`.
- [ ] [Era] `/gh log` opens the window on the Log tab.
- [ ] [Era] `/gh help` prints the command list.
- [ ] [Era] The window title reads "Guildhall" in the accent color. The border uses the theme color.
- [ ] [Era] Tabs appear in order: Exchange, Log, Settings. Clicking each one switches content.
- [ ] [Era] The Exchange tab shows the board (sub-tabs, search box, list on the left, details on the right), not "This tab could not be loaded yet".
- [ ] [Era] Drag the window by its background. `/reload`. It reopens at the same spot.
- [ ] [Era] ESC closes the window. The X button closes it.
- [ ] [Era] The window cannot be dragged off screen.

## Minimap button

- [ ] [Era] A round Guildhall button sits on the minimap edge.
- [ ] [Era] Hovering shows a "Guildhall" tooltip.
- [ ] [Era] Left-click toggles the window.
- [ ] [Era] Drag the button around the minimap edge. `/reload`. It keeps its new position.

## Consent

- [ ] [Era] First login on a character in a guild shows the consent dialog with the text "Guildhall links your characters in <guild> so guildmates there can reach you on whichever one is online. Only characters in <guild> are listed. Uncheck any you don't want shared."
- [ ] [Era] The dialog lists the current character, checked.
- [ ] [Era] Click OK. The dialog closes. The Log tab shows a `profile-link` entry.
- [ ] [Era] Log in on a first alt in the same guild. The consent dialog appears again for that alt only.
- [ ] [Era] Uncheck the alt and click OK. Settings shows it as "not shared".
- [ ] [Era] Two guilds: log in on a character in guild A, then on an alt in guild B. The consent dialog for B lists only the B alt (not the A character). In A, Settings lists only A's characters; a guildmate in A never sees the B alt under "Also:".
- [ ] [Era] Upgrading from a build without guild scoping: on first login each character is asked about once more (the dialog names the guild). Characters not logged in since stay unlinked until they log in.
- [ ] [Era] Uncheck the current character (Settings > Change…). "+ New listing" > Post shows "This character isn't linked to your profile. Posting from it would reveal the link. Link it in Settings or post from a linked character." Edit, Renew and Remove on your listings show the same message, and nothing is sent.
- [ ] [Era] Settings > Change… shows all known characters in this guild with the current choices. Changing one and clicking OK updates Settings and adds a `profile-update` log entry.
- [ ] [Era] Logging in again after consent does not show the dialog.

## Settings

- [ ] [Era] Settings shows the guild key, profile id, officer threshold and linked characters.
- [ ] [Era] The officer line shows the hint "Set by officers in Guild Info: [Guildhall officers=N]".
- [ ] [Era] Add `[Guildhall officers=3]` to Guild Info, `/reload`. The threshold reads 3.

## Log tab

- [ ] [Era] The Log tab lists entries, newest first, in the export line format.
- [ ] [Era] Typing in the filter box narrows the list by listing ID, profile id or character name (case-insensitive).
- [ ] [Era] Typing into the log text does not change it.
- [ ] [Era] Export opens the copy box titled "Guildhall log" with the text highlighted and the hint "Press Ctrl+C to copy".
- [ ] [Era] Ctrl+C copies it. Pasting elsewhere gives the same lines. ESC closes the copy box.

## Leaderboard (Era, demo data)

Era has no Forever bank or trade events, so these checks use `/gh lbdemo` fake data.

- [ ] [Era] `/gh help` lists "/gh lbdemo - show fake leaderboard data (only on your screen)".
- [ ] [Era] `/gh lbdemo` prints a chat line. The Leaderboard tab shows the orange "Demo data, not real. /gh lbdemo off" banner and 12 made-up players (Thalwyn, Brakka, Mireth and so on), never your real guildmates.
- [ ] [Era] Demo data shows under Week, Month, All time and Past months (one saved month). Your own demo row shows a full breakdown; picking another player shows totals only (unless you are an officer).
- [ ] [Era] Filters: the Board picker lists Overall and every activity, and each board re-ranks. Selecting a row updates the right-hand panel. With more than 11 rows the list scrolls and your own row is pinned.
- [ ] [Era] Settings: the Leaderboard settings page opens with no Lua error. Changing a weight while demo is on is refused with a message ("Demo data is only on your screen..."), and nothing is published. The opt-out checkbox ("Show me on the leaderboard") changes your real setting even in demo mode.
- [ ] [Era] While demo is on, the other client sees nothing new, and `/reload` clears the banner and the fake data (SavedVariables hold none of it).
- [ ] [Era] `/gh lbdemo off` removes the banner and the real tab returns.
- [ ] [Era] Log tab as a non-officer (put your character below the officer rank): observation entries are one line of counts like "received 6 (trade 2, bank 4)", with no names or amounts. Export gives the same lines. As an officer, the full entries show.

## Exchange board

- [ ] [Era] Sub-tabs All, Buying (LF), Selling and Mine filter the list. The active one stays highlighted.
- [ ] [Era] Each row shows an LF (blue) or WTS (orange) tag, the item link in its quality color, a dot (green online, grey offline, "?" unknown) and "Name · 6d left" (or `5h`, `<1h`).
- [ ] [Era] Hovering a row whose item is a link shows the item tooltip. Hovering a typed-name row shows no tooltip and no error.
- [ ] [Era] Clicking a row highlights it and fills the details pane. The selection survives a refresh (e.g. a guildmate posting).
- [ ] [Era] With more than 10 listings the list scrolls with the mouse wheel and the scrollbar. Rows are reused (no slowdown after many refreshes).
- [ ] [Era] The search box narrows the list by item name or poster, case-insensitive. Clearing it restores the list.
- [ ] [Era] Details pane: type and item, poster with dot and "(online/offline/unknown)", "Also: <other linked characters>", "I will / will not provide materials", "I am open / not open to COD", the note, Posted and Expires dates (YYYY-MM-DD HH:MM).
- [ ] [Era] A 200-character note wraps inside the details pane and does not run under the buttons.
- [ ] [Era] A note containing `|` shows the character literally (no broken color codes).
- [ ] [Era] Your own listing shows Copy for Discord, Edit, Renew, Remove, and no Whisper/Mail button.
- [ ] [Era] Remove asks "Remove your listing for <item>?" first. No keeps the listing.
- [ ] [Era] As an officer, another member's listing shows Remove (officer), which asks for confirmation first. As a non-officer, the button never appears.
- [ ] [Era] Errors from board actions (e.g. Renew on a trial account) show as a red line under the board.
- [ ] [Era] The board updates by itself when a guildmate posts, edits or removes while it is open.
- [ ] [Era] An imported (Discord) listing shows "Posted on Discord by <poster>", no Whisper/Mail when there's no character, and a single "Remove from my board" button (never Edit).

## Listing form

- [ ] [Era] "+ New listing" opens the form titled "New listing" with a Post button. On the Selling sub-tab, Selling (WTS) is preselected.
- [ ] [Era] The LF/WTS radio buttons are mutually exclusive.
- [ ] [Era] Typing a name in the Name box (no item link) posts a listing with that plain name.
- [ ] [Era] Typing in the Name box after loading a link clears the slot back to "No item chosen".
- [ ] [Era] Quantity accepts digits only (max 4). 0 shows "Quantity must be a whole number from 1 to 9999."
- [ ] [Era] The note stops at 200 bytes and the counter shows n/200. Accented letters (e.g. "é") count 2, and a full accented note posts without a "too long" error.
- [ ] [Era] Posting with no item shows "Choose an item (shift-click or drag one in) or type its name." inside the form.
- [ ] [Era] With an undecided character (new alt), Post shows "Choose which characters to link first." and opens the consent dialog.
- [ ] [Era] Edit opens "Edit listing" pre-filled (type, item, quantity, toggles, note) with a Save button. Clearing quantity or note removes them.
- [ ] [Era] ESC and Cancel close the form. Shift-clicking items while the form is closed does nothing to it.
- [ ] [Era] Shift-clicking an item while the chat box is open puts it in both the form and the chat box (expected; the hook can't stop chat).

## Exchange settings

- [ ] [Era] Settings shows an "Exchange" section with six template boxes (whisper LF/WTS, mail subject, mail body LF/WTS, Copy for Discord) and a Reset button each.
- [ ] [Era] Newlines show as `\n`. Edit the Discord template (e.g. add `\nping {char}`), press Enter. Copy for Discord uses it with a real line break.
- [ ] [Era] Reset restores the default text and the default is used again.
- [ ] [Era] ESC in a template box restores the saved text.

## Exchange (after Task 14)

- [ ] [Era] Post a listing. It shows on the board.
- [ ] [Era] Edit it. The change shows, and the log has an `edit` entry.
- [ ] [Era] Renew it. The expiry moves out, and the log has a `renew` entry.
- [ ] [Era] Remove it. It disappears, and the log has a `remove` entry.
- [ ] [Era] A second account or a guildmate sees the listing within a few seconds.
- [ ] [Era] Log out and back in. The listing is still there.
- [ ] [Era] The online dot is green for an online poster, grey when they log off.
- [ ] [Era] Whisper on an online poster's listing opens chat pre-filled with `/w Name ...`. Nothing is sent.
- [ ] [Era] Mail on an offline poster's listing while at a mailbox switches to Send Mail and fills To, Subject and Body. Nothing is sent.
- [ ] [Era] Mail away from a mailbox shows "Saved as a mail draft...". At the next mailbox a popup asks "Fill in your Guildhall mail draft to Name?" with Fill in, Later and Dismiss.
- [ ] [Era] Fill in fills the Send Mail fields. Later keeps the draft for next time. Dismiss deletes it.
- [ ] [Era] Copy for Discord opens the copy box with the formatted text.
- [ ] [Era] An officer (rank below the threshold) can remove another member's listing. The log shows `officer-remove`.
- [ ] [Forever] Mail frame names `SendMailNameEditBox`, `SendMailSubjectEditBox`, `SendMailBodyEditBox` and `MailFrameTab_OnClick(nil, 2)` work.

## Item slot (after Task 14)

- [ ] [Era] Shift-click an item in your bags while the form is open. The slot shows the item and its icon.
- [ ] [Era] Shift-click an item in a profession window. The slot loads it with its icon.
- [ ] [Era] Shift-click an item in the auction house. The slot loads it with its icon.
- [ ] [Era] Drag an item from bags onto the slot. It loads, and the cursor is cleared.
- [ ] [Era] Clear (X) empties the slot.
- [ ] [Era] Another member's listing shows the right icon on their client.
- [ ] [Forever] Listings for quality-tier reagents (name shows a tier icon) and ordinary items render as coloured links with tooltips on other clients, not as escaped `||c…` text. If not, `Util.IsItemLink` needs the client's link shape.
- [ ] [Forever] Shift-click a recipe in the profession list. The slot loads the crafted item, or falls back to a typed name with no error.
- [ ] [Forever] Shift-click from bags uses the `ChatFrameUtil.InsertLink` hook (link is its first argument); `/dump ChatFrameUtil.InsertLink` exists. No taint warnings ("blocked action") after using the form and then entering combat.
- [ ] [Forever] The slot icon comes from `C_Item.GetItemIconByID`. Drag-and-drop from bags works (`GetCursorInfo` returns "item", id, link).
- [ ] [Forever] The Remove and Remove (officer) confirmation popups appear and work.

## Board filters and listing profession

- [ ] [Era] Search row shows "Category: All" and "Member: Anyone" buttons right of the search box; nothing overlaps the details pane.
- [ ] [Era] Category popup lists All, Crafted, Materials, Recipes, Gear, Other. Professions appear indented under Crafted only when a listing has them. Choosing one filters the list and the button reads e.g. "Category: Tailoring".
- [ ] [Era] Category and Member combine with the All / Buying / Selling / Mine tabs and with Search. The selection survives a refresh (new listing, sync).
- [ ] [Era] Member popup lists each poster once (alts together under one name), sorted. An imported Discord listing appears as "<poster> (Discord)". If the chosen member's last listing is removed, the button returns to "Member: Anyone".
- [ ] [Era] Popups close on a choice, on a click elsewhere, and on Esc (Esc closes the popup but not the form behind it). With many members the list scrolls with the mouse wheel.
- [ ] [Era] Listing form: the Profession picker shows None by default, opens the list, and the choice shows on the button. The Note box and error line moved down without overlap.
- [ ] [Era] Open the Tailoring (or any) window, shift-click a crafted item or recipe into the form: the picker fills with that profession. Open Enchanting (the craft window): it fills Enchanting. A potion with no window open fills Alchemy; food fills Cooking; a bandage fills First Aid.
- [ ] [Era] Pick a profession by hand, then shift-click the same item again: your choice stays. A different item auto-fills again.
- [ ] [Era] Editing a listing shows its profession; setting None and saving removes it. The details pane shows "Profession: <name>" above Posted.
- [ ] [Forever] The profession window (`ProfessionsFrame`) fills the picker via `C_TradeSkillUI.GetBaseProfessionInfo()`; names follow the client language; no Lua errors or taint warnings.

## Forever restrictions

- [ ] [Forever] `/console addonChatRestrictionsForced 1`, then post. The status line reads "Listing posted. It will reach guildmates when chat restrictions lift." The message stays queued (no error). `/console addonChatRestrictionsForced 0`. It sends within a few seconds.
- [ ] [Forever] `/console addonMapRestrictionsForced 1`. Online dots show unknown. No Lua errors. Set it back to 0.
- [ ] [Forever] Inside a dungeon (and during a boss pull): no Lua errors, the window still opens.
- [ ] [Forever] After leaving the instance, pending messages go out and the board catches up.
- [ ] [Forever] A trial account gets the trial message on posting.
- [ ] [Forever] Several restriction lifts within a minute (e.g. pulls in a dungeon) send at most one catch-up per minute (`/gh log` shows no burst of ignored "too large" entries).

## Guild change and large boards

- [ ] [Era] While logged in, leave the guild (or `/gquit` on a test alt). Within a few seconds one chat line says Guildhall has stopped and asks for `/reload`. No Lua errors. Guildmates no longer get replies from this client.
- [ ] [Era] Join a different guild without reloading. One chat line asks you to `/reload` to switch Guildhall to the new guild. Nothing from the old guild's board is sent to the new guild. After `/reload` the board shows the new guild's listings only.
- [ ] [Forever] Inside an instance, a guild name that reads as empty (secret) does not trigger the guild-change message.
- [ ] [Era] With a large board (hundreds of listings, e.g. seeded on a test guild), a client that logs in catches up fully; the log shows no "too large" entries.

## Groups

- [ ] [Era] The Groups tab opens with no Lua errors. "+ New post" offers dungeons and raids, Now or Scheduled (server time), and the roles you still need.
- [ ] [Era] Post a run, then sign up from a second client. The post and signup reach the other client, and "I'm ready now" lists you as ready.
- [ ] [Era] Sign up for a run starting in 20 minutes. A reminder prints 15 minutes before it; the sound plays only when "Play a sound with reminders" is on.
- [ ] [Era] Open the calendar on another month, then `/reload`. Guild events for the next 14 days are still read, and each maps to its raid.
- [ ] [Era] Kill a dungeon boss and finish the dungeon. The finished run and raid kills show on the Leaderboard once enough guildmates saw them.
- [ ] [Era] Raid roster: Prepared checkbox and Ask to switch work. Dual spec may not exist on Era; if it doesn't, spec switching is not offered and nothing errors.
- [ ] [Era] Settings > Groups and Permissions: the guild master sets which ranks can do what, and Change history shows each change in server time.
- [ ] [Era] Edit checklist on a raid post saves, and a 13th line is refused.
