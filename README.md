<p align="center"><img src="docs/media/logo-256.png" width="128" alt="Guildhall logo"></p>

# Guildhall

A guild-helper addon for **World of Warcraft: Forever**. Its first feature is **Exchange**: an in-game LF / WTS board shared by everyone in your guild who runs Guildhall. Members can see who's buying and selling without alt-tabbing to Discord.

Built by **Jon Roberts** ("Dor" in game) for the guild Emergence. It works in any guild.

## Install

**With WowUp** (handles updates, if your WowUp version recognises the Forever client):

1. In WowUp, choose **Get Addons → Install from URL**.
2. Paste `https://github.com/danthar75/guildhall` and install.

If WowUp doesn't list your Forever install, use the manual steps below; they always work.

**By hand:**

1. Download `Guildhall-<version>.zip` from the [Releases](https://github.com/danthar75/guildhall/releases) page.
2. Optional: check the download against the SHA-256 on the release page.
   - Windows PowerShell: `Get-FileHash .\Guildhall-<version>.zip`
   - macOS / Linux: `shasum -a 256 Guildhall-<version>.zip`
3. Unzip it into `World of Warcraft\_forever_\Interface\AddOns\` (usually under `C:\Program Files (x86)\`). You should end up with `_forever_\Interface\AddOns\Guildhall\Guildhall.toc`.
4. Restart the game, or `/reload` if it's already open.

Open it with `/gh` (or `/guildhall`) or the minimap button. `/gh help` lists the commands.

## What it does

- **Post in the guild's format.** Choose buying (LF) or selling (WTS), then add the item: shift-click it from your bags, a profession window or the auction house, or drag it in. Set materials yes/no and CoD yes/no, and add an optional quantity and note.
- **Shares the board with the guild.** Listings travel over the guild's hidden addon channel to other members running Guildhall. They stay up while you're offline and expire after 7 days. You can edit, renew or take down your own.
- **Shows who's online.** The online dot counts all of the poster's linked characters.
- **One click to respond.** **Whisper** opens chat with a message ready to send. **Mail** fills in a letter at the mailbox.
- **Copy for Discord.** Turns any listing into a post in the guild's pinned `#exchange` format, so members without the addon still see it.
- **Officer clean-up and an activity log.** Officers can remove any listing. Who counts as an officer is set by a tag in the Guild Information text, e.g. `[Guildhall officers=2]`. Every change is recorded in a local log, along with who passed it along.

## What it does *not* do

- **It never sends anything for you.** Whispers and mail are only filled in. You read them and press Enter or Send yourself. Gold, items and CoD are always attached by hand.
- **No internet access.** WoW addons can't open network connections, download files or run programs; the game doesn't allow it. Guildhall talks only to other Guildhall users in your own guild, through the game's addon channel.
- **No combat automation, and nothing that breaks Forever's addon rules.** It doesn't read combat data. During instance restrictions it waits, and catches up afterwards.
- **No account or personal data.** It stores listings, your settings and the log in WoW's normal SavedVariables file (`WTF\Account\<account>\SavedVariables\Guildhall.lua`). Nothing leaves the game.
- **Your alts are shared only if you agree.** The first time, it asks which of your characters may be linked. You can leave any of them out and change it later in Settings.

## Is it safe?

Short version: a WoW addon is plain-text Lua that the game runs inside a sandbox. It can't touch your files, your PC or your Battle.net account.

- **Text plus one picture.** The zip contains `.toc` and `.lua` text files and one image, `Media\Logo.tga` (the logo shown on the minimap button). There are no executables, no installers and nothing that runs outside the game. You can open every text file in Notepad and read it; the logo is drawn by `tools/make-logo.py` in this repository.
- **Open source.** All of the code is in this repository, and each release zip is built from it by `tools/release.sh`.
- **Checksums.** Each release lists the zip's SHA-256, so you can confirm your download is the published file.
- **Easy to remove.** Delete the `Interface\AddOns\Guildhall` folder. To also clear its saved data, delete `Guildhall.lua` from your SavedVariables folder.

## How it was made

Guildhall was designed, reviewed and tested by **Jon Roberts** ("Dor"), a senior software developer. Much of the code was written with **Claude** (Anthropic's AI assistant) as a coding assistant, working from Jon's design. It went through automated tests (`tools/check.sh`) and code review at every step. Built with Claude, reviewed by a human.

## Development

```bash
tools/setup.sh     # one-time: installs Lua 5.1 + busted locally under .tools/
tools/check.sh     # syntax check + test suite
tools/release.sh   # tests, then builds dist/Guildhall-<version>.zip and its SHA-256
```

`Guildhall/Guildhall_Vanilla.toc` lets the addon load in Classic Era for development testing. It is never included in a release. The in-game test list is in `docs/testing/in-game-checklist.md`.

## Reporting problems

Open an issue on GitHub or message Dor in game or on the guild Discord. If the addon showed a Lua error, include its text.
