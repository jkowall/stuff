# Bypass Paywalls Clean updater

Keep this source directory in a clone of `jkowall/stuff`, optionally synced by
OneDrive. Each Mac or Windows PC installs its
own updater, schedule, extension folder, logs, and backups outside OneDrive.
Each machine downloads the [maintainer's ZIP](https://gitflic.ru/project/magnolia1234/bpc_uploads/blob/raw?file=bypass-paywalls-chrome-clean-master.zip)
independently. Install once per machine and Windows user account.

| Platform | Local installation | Schedule |
| --- | --- | --- |
| macOS | `~/Library/Application Support/Bypass Paywalls Updater` | At login and every 24 hours while logged in |
| Windows | `%LOCALAPPDATA%\Bypass Paywalls Updater` | At login and daily at 09:00 while signed in, including when locked |

Windows being online more keeps its own copy up to date. The Mac checks again
at login, so it can catch up without depending on Windows or on OneDrive being
available. No task can run on a powered-off machine.

Do not load the extension directly from OneDrive. A local installation avoids
OneDrive conflicts or partial sync while Chrome reads the files. It also avoids
the OneDrive privacy restriction observed with launchd on macOS. An existing
`bypass-paywalls-chrome-clean-master` folder is separate from the scheduled targets.

## Windows setup

1. Pull this repo or let OneDrive sync `Stuff\system\bypass-paywalls-updater`,
   including `update.py`.
2. Install [Python 3.9 or newer](https://www.python.org/downloads/windows/) if
   needed. The installer probes `py -3`, `python3`, and `python` and pins the real
   interpreter path. It also uses Windows PowerShell 5.1 and Windows' `curl.exe`.
3. Double-click `Install-Windows.cmd`. It downloads and validates the extension
   immediately, copies the updater to local storage, and registers the current
   user's scheduled task. It does not install Python automatically.
4. In `chrome://extensions`, enable Developer mode, click **Load unpacked**, and
   select this folder once:

   ```text
   %LOCALAPPDATA%\Bypass Paywalls Updater\extension
   ```

The task is named `Bypass Paywalls Updater-<Windows-user-SID>`, uses limited user
privileges, and does not store a password. Missed scheduled runs catch up when
available; failures retry up to three times at 15-minute intervals. It uses
`pythonw.exe` when available to avoid opening a console.

PowerShell alternatives, from this directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -PythonExe 'C:\path\to\python.exe'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1 -Uninstall

# Run/check the local copy without waiting for the schedule:
py -3 "$env:LOCALAPPDATA\Bypass Paywalls Updater\update.py" --check
py -3 "$env:LOCALAPPDATA\Bypass Paywalls Updater\update.py"
Get-Content "$env:LOCALAPPDATA\Bypass Paywalls Updater\updater.log" -Tail 20
Get-ScheduledTask -TaskName 'Bypass Paywalls Updater-*' | Get-ScheduledTaskInfo
```

If task registration fails, the installer exits with an error. The local copy
and log remain available for diagnosis. Windows Task Scheduler registration and
Chrome's behavior with an open extension have not been tested on a Windows host
from this Mac.

## macOS setup

Run from this directory:

```sh
/usr/bin/python3 install.py
/usr/bin/python3 update.py --check   # Validate the live download without installing
/usr/bin/python3 update.py           # Update the local managed extension
/usr/bin/python3 install.py --uninstall
```

A fresh installation downloads directly from the maintainer. No adjacent copy
of the extension is needed. Existing installations keep their local path.

In `chrome://extensions`, enable Developer mode and load this folder once:

```text
~/Library/Application Support/Bypass Paywalls Updater/extension
```

The LaunchAgent is `~/Library/LaunchAgents/local.bypass-paywalls-updater.plist`.
A sleeping Mac runs a missed interval after waking. Failed checks retry at the
next interval or login; run `update.py` manually to retry sooner.

```sh
launchctl print gui/$(id -u)/local.bypass-paywalls-updater
tail -n 20 "$HOME/Library/Application Support/Bypass Paywalls Updater/updater.log"
```

## Activation and sync

After a file update, reload Bypass Paywalls Clean at `chrome://extensions`, or
fully quit and reopen Chrome. The updater does not restart Chrome or modify its
profiles. [Upstream instructions](https://gitflic.ru/project/magnolia1234/bypass-paywalls-chrome-clean#update)
require reloading unpacked extensions after replacing their files.

If another copy is installed, export its settings first and load the local
managed folder instead. The extension public key, and therefore its ID, remain
the same. The updater does not synchronize browser settings between machines.

Both schedules use only local paths after installation. Changes to the updater
source sync through OneDrive, but rerun the platform installer on each machine
to refresh its local runtime. Extension releases download automatically without
rerunning the installer.

To update another existing extension folder manually, pass
`--extension-dir /path/to/bypass-paywalls-chrome-clean-master` to `update.py`.

## Validation and recovery

- Downloads only from the pinned maintainer URL over HTTPS.
- Checks package name, Manifest V3, the original public key, version, and required resources.
- Rejects downgrades, unsafe ZIP paths (including Windows device names and
  alternate data streams), symlinks, duplicate entries, and oversized archives.
- Uses a per-machine file lock to avoid overlapping updates.
- Stages the download before changing files, backs up the entire old folder,
  and restores the old folder if replacement fails.
- Does not execute downloaded extension code. The public-key comparison checks
  identity metadata; it is not a cryptographic signature check of the ZIP.

Within each local installation:

```text
updater.log
last-update.json
update.lock
update.py
extension/
backups/<previous-version>-<timestamp>/
```

`last-update.json` records the last installation's version, ZIP SHA-256, target,
and backup path. Backups are retained until you delete them. Local edits to
extension source files are replaced during an update and saved in that backup.

To roll back, first uninstall the schedule. Move the current local `extension`
folder aside, copy a backup to that path, then reload the extension or restart
Chrome. Reinstalling the schedule will update to the latest version again.

## Tests

The Python tests use isolated temporary folders and no network or browser state:

```sh
python3 -m unittest discover -v -p 'test_*.py'
```

On Windows use `py -3 -m unittest discover -v -p 'test_*.py'`. The suite covers successful
replacement, backup restoration after failure, fresh-machine bootstrapping,
check-only mode, downgrade and package rejection, Windows filename rules, and
Windows lock handling with a mocked `msvcrt` boundary on non-Windows hosts.
On macOS it also checks fresh-clone bootstrapping, failure preservation, and
local LaunchAgent paths without changing live scheduler state.
