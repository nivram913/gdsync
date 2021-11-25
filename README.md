# gdsync
Google Drive synchronization tool. Successor of the venerable `autosave_gd` (https://github.com/nivram913/autosave_gd).

Files are encrypted with AES 256 bits in CBC mode before being uploaded to Google Drive. Filenames are encrypted too.

This tool is intended to be used from a GUI on **Xubuntu 20.04** but can run on other system as well if dependencies are installed.

The syncronization is pretty basic : it's based on modification time.

## Requierements
- `drive` (https://github.com/odeke-em/drive) (for Google Drive uploading)
- `openssl >= 1.1.1` (for encryption)
- `zenity` command (for GUI)
- `gio` utility (for emblem on synced files)
- `secret-tool` utility (for storing password in Gnome Keyring)
- `inotifywait` utility (for `gds_inotify.sh` for real time emblem updating)

*Optional :*

- `thunar` file manager (for actions from right click on files)

## Install

- Place the script in a directory included in your `$PATH` (like `$HOME/bin`)
- Configure variables `GDS_INDEX_FILE`, `REMOTE_DIR` and so on, at the beginning of the script
- Create remote directory configured previously on Google Drive and place an empty `mtime.lst` file in that remote directory
- Configure `drive` with `drive init` in the relevant directory (refer to the `drive`'s doc)


*Action from right click setup in Thunar* :

- Go in `Edit` -> `Configure custom actions...` in Thunar and add these new entries:
  - `Name`=`Add to sync`, `Command`=`gdsync.sh --add %F`
  - `Name`=`Remove from sync`, `Command`=`gdsync.sh --del %F`
  - `Name`=`Force push`, `Command`=`gdsync.sh --force-push %F`
  - `Name`=`Force pull`, `Command`=`gdsync.sh --force-pull %F`

You can setup a keyboard shortcut to execute `gdsync.sh --sync` to trigger a synchronization and `gdsync.sh --pull` to pull file(s) from remote server that are not locally present.

You can setup a (ana)cron task to execute `gdsync.sh --update-gio` to update emblems on synced files. Green dot emblem means in sync files and red dot emblem means not in sync files.

Moreover, you can start `gds_inotify.sh` in background task that will update the emblem of modified files in real time thanks to `inotify` feature.

## Usage

```
Usage: ./gdsync.sh <option> [<absolute path to files>]
--add         Add specified file(s) to the synchronization process
--del         Delete specified file(s) from the synchronization process
--sync        Perform a synchronization of all syncing files
--pull        Interactively pull a file from server that is not locally present
--update-gio  Update GIO emblem on synced files
--force-pull  Force pulling of specified file(s)
--force-push  Force pushing of specified file(s)
```

Files are never removed from server but a lot of files can be placed in trash folder of Google Drive.

