# Guildhall: Welcome screen (design)

Status: agreed in chat on 2026-11-04. It is built as the last step of the Leaderboard v1 branch.

Labels:
- **(user)**: Jon decided it.
- **(my call)**: Claude decided it; Jon can override.

## When it shows
- **First open (user).** It appears the first time the Guildhall window is opened on an account. It opens on top of the window.
- **After updates (user).** It shows again when a new version has a "What's new" entry the player hasn't seen. The "What's new" section is then prominent: at the top, highlighted, above the feature list.
  - A version with no "What's new" entry (a small fix) doesn't reopen it (my call).
- **Account-wide flag (my call).** Alts don't see it again. Stored as `personal.welcome = { seen = "<last version seen>" }`.

## Getting it back (user)
- a "Show welcome screen" button in Settings
- the `/gh welcome` command
- a "Show this next time" checkbox on the screen itself (my call)

## What's on it
- **Header:** the Guildhall logo, the guild's tabard and name, and the version.
- **What's new** (only after an update, or when reopened with news to show). It lists the entries for every version newer than the last one seen, newest first, each headed "In <version>".
- **What Guildhall does:** a short, plain-language list. Each module supplies its own lines (`def.about = { title, lines }`), so new modules appear without the screen being edited (my call). The text for v1:
  - **Exchange:** post what you're looking for or selling. Guildmates see it right away, and you can whisper, mail or copy it for Discord.
  - **Linked characters:** guildmates reach you on whichever character you're on. Only the characters you choose are shared.
  - **Leaderboard:** the gold your guild kept, plus who's contributing, from verified Exchange deals and guild bank donations.
  - **Log and Settings:** see every change, and adjust your message templates.
- **The gnome line, verbatim (user):** "No gnomes were harmed during the creation of this add-on. I mean, no more than 10 or 20 so almost none."
- **Credit (user):** "Made by Jon Roberts (Dor in game), a real-life senior software developer. Built with Claude, reviewed by a human." The "real-life senior software developer" wording is there to reassure players that a professional reviewed the code (user).
- **Buttons:** Close. Esc also closes it.

## Data
- `Guildhall/Core/WhatsNew.lua` holds an ordered list of `{ version = "0.2.0", lines = { ... } }`. The release process adds an entry when a version has news.
- The version comes from the TOC (`C_AddOns.GetAddOnMetadata` or `GetAddOnMetadata`, `"Version"`).
- Versions compare numerically by dotted parts.

## Non-goals
- No changelog history beyond what `WhatsNew.lua` lists.
- No animations, and no per-character tracking.
