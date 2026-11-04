## Guildhall {{VERSION}} (beta)

> **Beta.** Guildhall is being tested in the guild Emergence, so expect rough edges. Please report problems to Dor in game or on the guild Discord, or open an issue here.

An in-game LF / WTS board for your guild on WoW Forever. Post what you're buying or selling, see who's online, and whisper, mail or copy a listing for Discord in one click. Everyone in the guild who runs Guildhall sees the same board.

### Install (about 2 minutes)

1. **Download** `Guildhall-{{VERSION}}.zip` from the **Assets** list at the bottom of this page.
2. **Close WoW Forever** if it's running.
3. **Open your Forever AddOns folder:**
   - In the Battle.net app, select **WoW Forever**. Click the **gear icon** next to Play, then **Show in Explorer** (Finder on Mac).
   - Open the **`_forever_`** folder, then **Interface**, then **AddOns**. If `AddOns` doesn't exist yet, create it. Spelling matters.
   - Usually this is `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns`.
4. **Unzip the download into `AddOns`.** You should end up with:
   ```
   ...\_forever_\Interface\AddOns\Guildhall\Guildhall.toc
   ```
   - If you see `AddOns\Guildhall\Guildhall\Guildhall.toc` (one folder too deep), move the inner `Guildhall` folder up one level.
5. **Start the game.** On the character screen, click **AddOns** (bottom left) and make sure **Guildhall** is ticked.
6. **In game,** type `/gh` or click the minimap button. The first time, Guildhall asks which of your characters it may link; untick any you'd rather keep private.

### Updating

Close the game, delete the old `AddOns\Guildhall` folder, and unzip the new one in its place. Your listings and settings are kept, because they live in a separate file.

### Uninstalling

Delete `Interface\AddOns\Guildhall`. To remove its saved data as well, also delete `Guildhall.lua` from `WTF\Account\<your account>\SavedVariables\`.

### Is it safe?

- The zip contains plain-text `.toc` and `.lua` files plus one picture (`Media\Logo.tga`, the minimap logo). There are no programs or installers, and you can open every text file in Notepad.
- WoW addons run inside the game's sandbox. They can't access the internet, your files or your account.
- Guildhall never sends a whisper, mail or trade for you. It only fills in the text, and you press Send yourself.
- The full source code is in this repository.
- **Optional download check:** the zip's SHA-256 should be
  ```
  {{SHA256}}
  ```
  To check it, run one of these and compare the output:
  - Windows PowerShell: `Get-FileHash .\Guildhall-{{VERSION}}.zip`
  - Mac / Linux: `shasum -a 256 Guildhall-{{VERSION}}.zip`

### Something wrong?

Message **Dor** in game or on the guild Discord, or open an issue here. If you saw a Lua error, copy its text.

---
Made by Dor, a senior software developer. Built with Claude (Anthropic's AI assistant) and reviewed by a human.
