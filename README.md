# GameSaveSync

Two-way game save sync between Dali's two PCs using a USB drive, with a
local web UI and optional GitHub cloud backup (pull saves on any device).

## How it works

- The USB drive holds the tool in `GameSync\` and the actual save folders in
  `GameSaves\` (one folder per game).
- Run `GameSync-App.bat` (or `Sync-GameSaves.bat` for the CLI) on either PC
  with the USB plugged in. The script finds the USB itself (marker file
  `GameSync\.usbsync-root`), so the drive letter does not matter.
- Default = two-way merge, newest file wins. In the web app you can pick the
  **main copy**: Auto (newest wins), This PC, or USB - the main side wins
  conflicts, the other side only receives files it is missing.
- Per-game **enabled toggles** persist in `GameSync\settings.json` - uncheck
  a game and it stops appearing in batch syncs.
- **Cloud backup**: the app can push/pull saves to a private GitHub repo
  (`DALI951/game-saves`), so a PC without the USB can still pull its saves.
  Games with files over 90 MB are excluded by default (GitHub's 100 MB file
  cap) - e.g. Foundation stays USB-only.
- Nothing is ever deleted. If a save was deleted on one PC, the other copy
  stays. Clean up manually if you really want it gone.
- Every run writes a log to `GameSync\logs\sync-<PC>-<timestamp>.log`.

## Usage

    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Push
    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Pull
    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -DryRun

or `GameSync-App.bat` -> opens http://127.0.0.1:8771 (per-game cards,
Push/Pull/Sync buttons, dry-run checkbox, main-copy selector, cloud push/pull,
live log).

Games can have several possible save locations (e.g. Planetbase: the save is
in `Documents\Planetbase` on one machine). The manifest's `sources` array is
checked in order and all existing ones are merged into the same USB folder.

## Files

- `manifest.json` - game list, save-path templates (`%USERPROFILE%`,
  `%APPDATA%`, `%LOCALAPPDATA%` are resolved at runtime so it works on both
  PCs), per-game alternative sources, global exclude patterns.
- `engine.ps1` - the sync engine (PowerShell 5.1, ASCII-only, no admin
  needed): USB discovery, settings, conflict rules, cloud git sync.
- `sync.ps1` - CLI wrapper with `-Push/-Pull/-DryRun/-Game/-Json`.
- `app.ps1` - local web server (`http://127.0.0.1:8771`).
- `web\index.html` - the UI.
- `Sync-GameSaves.bat`, `GameSync-App.bat` - double-click launchers.
- `GameSaves\` on the USB - one folder per game, this is the working copy.

Edit `manifest.json` to add or remove games, then re-copy it to the USB
(`GameSync\manifest.json`). Never edit files straight on the USB if you also
keep the repo copy - keep the repo as source of truth and copy over.

## USB layout

    E:\GameSync\sync.ps1
    E:\GameSync\engine.ps1
    E:\GameSync\app.ps1
    E:\GameSync\web\index.html
    E:\GameSync\manifest.json
    E:\GameSync\settings.json      <- main-copy mode + per-game toggles
    E:\GameSync\Sync-GameSaves.bat
    E:\GameSync\GameSync-App.bat
    E:\GameSync\.usbsync-root      <- marker so the tool finds the USB
    E:\GameSync\logs\
    E:\GameSaves\<Game Name>\      <- save data, one folder per game