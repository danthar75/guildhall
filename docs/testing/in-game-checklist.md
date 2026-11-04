# Guildhall in-game checklist

Manual checks for the WoW-facing parts (frames, events, slash commands). Tags:
**[Era]** can be tested on Classic Era with the dev TOC. **[Forever]** needs the WoW Forever client.
Keep `/console scriptErrors 1` on (or BugSack installed) for every session.

## How to install

- [ ] Classic Era: copy or symlink the `Guildhall/` folder into `World of Warcraft/_classic_era_/Interface/AddOns/`. The game loads `Guildhall_Vanilla.toc`.
- [ ] Forever: copy or symlink `Guildhall/` into the Forever client's `Interface/AddOns/` folder (`_retail_/Interface/AddOns/` or the Forever equivalent).
- [ ] Release zip: contains `Guildhall/Guildhall.toc` and all Lua files, and does NOT contain `Guildhall_Vanilla.toc`.
- [ ] Symlink example (WSL/Linux): `ln -s ~/projects/guildhall/Guildhall "<WoW>/_classic_era_/Interface/AddOns/Guildhall"`. On Windows use `mklink /D`.

## Loading and shell

- [ ] [Era] The addon loads with no Lua errors on login and after `/reload`.
- [ ] [Forever] The addon loads with the release TOC (`Guildhall.toc`), with no Lua errors.
- [ ] [Era] Not in a guild: one friendly chat line ("not in a guild"), no errors. `/gh` opens the window and the Exchange and Log tabs say "Join a guild to use Guildhall".
- [ ] [Era] `/gh` opens the window. `/gh` again closes it.
- [ ] [Era] `/guildhall` does the same as `/gh`.
- [ ] [Era] `/gh log` opens the window on the Log tab.
- [ ] [Era] `/gh help` prints the command list.
- [ ] [Era] The window title reads "Guildhall" in the accent color. The border uses the theme color.
- [ ] [Era] Tabs appear in order: Exchange, Log, Settings. Clicking each one switches content.
- [ ] [Era] Before Task 14 lands, the Exchange tab shows "This tab could not be loaded yet" instead of breaking the window.
- [ ] [Era] Drag the window by its background. `/reload`. It reopens at the same spot.
- [ ] [Era] ESC closes the window. The X button closes it.
- [ ] [Era] The window cannot be dragged off screen.

## Minimap button

- [ ] [Era] A round Guildhall button sits on the minimap edge.
- [ ] [Era] Hovering shows a "Guildhall" tooltip.
- [ ] [Era] Left-click toggles the window.
- [ ] [Era] Drag the button around the minimap edge. `/reload`. It keeps its new position.

## Consent

- [ ] [Era] First login on a character in a guild shows the consent dialog with the text "Guildhall links your characters so guildmates can reach you on whichever one is online. Uncheck any you don't want shared."
- [ ] [Era] The dialog lists the current character, checked.
- [ ] [Era] Click OK. The dialog closes. The Log tab shows a `profile-link` entry.
- [ ] [Era] Log in on a first alt in the same guild. The consent dialog appears again for that alt only.
- [ ] [Era] Uncheck the alt and click OK. Settings shows it as "not shared".
- [ ] [Era] Settings > Change… shows all known characters with the current choices. Changing one and clicking OK updates Settings and adds a `profile-update` log entry.
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
- [ ] [Forever] Shift-click a recipe in the profession list. The slot loads the crafted item, or falls back to a typed name with no error.

## Forever restrictions

- [ ] [Forever] `/console addonChatRestrictionsForced 1`, then post. The message stays queued (no error). `/console addonChatRestrictionsForced 0`. It sends within a few seconds.
- [ ] [Forever] `/console addonMapRestrictionsForced 1`. Online dots show unknown. No Lua errors. Set it back to 0.
- [ ] [Forever] Inside a dungeon (and during a boss pull): no Lua errors, the window still opens.
- [ ] [Forever] After leaving the instance, pending messages go out and the board catches up.
- [ ] [Forever] A trial account gets the trial message on posting.
