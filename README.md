# GameSaveSync

Two-way game save sync between Dali's two PCs using a USB drive.

## How it works

- The USB drive holds the tool in `GameSync\` and the actual save folders in
  `GameSaves\` (one folder per game).
- Run `Sync-GameSaves.bat` on either PC with the USB plugged in. The script
  finds the USB itself (marker file `GameSync\.usbsync-root`), so the drive
  letter does not matter.
- Default = two-way merge, newest file wins. `-Push` = PC to USB only,
  `-Pull` = USB to PC only, `-DryRun` = preview without copying.
- Nothing is ever deleted. If a save was deleted on one PC, the other copy
  stays. Clean up manually if you really want it gone.
- Every run writes a log to `GameSync\logs\sync-<PC>-<timestamp>.log`.

## Usage

    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Push
    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -Pull
    powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1 -DryRun

Games can have several possible save locations (e.g. Planetbase: the save is
in `Documents\Planetbase` on one machine). The manifest's `sources` array is
checked in order and all existing ones are merged into the same USB folder.

## Files

- `manifest.json` - game list, save-path templates (`%USERPROFILE%`,
  `%APPDATA%`, `%LOCALAPPDATA%` are resolved at runtime so it works on both
  PCs), per-game alternative sources, global exclude patterns.
- `sync.ps1` - the sync engine (PowerShell 5.1, ASCII-only, no admin needed).
- `Sync-GameSaves.bat` - double-click launcher.
- `GameSaves\` on the USB - one folder per game, this is the working copy.

Edit `manifest.json` to add or remove games, then re-copy it to the USB
(`GameSync\manifest.json`). Never edit files straight on the USB if you also
keep the repo copy - keep the repo as source of truth and copy over.

## USB layout

    E:\GameSync\sync.ps1
    E:\GameSync\manifest.json
    E:\GameSync\Sync-GameSaves.bat
    E:\GameSync\.usbsync-root   <- marker so the tool finds the USB
    E:\GameSync\logs\
    E:\GameSaves\<Game Name>\   <- save data, one folder per game