# picdump

`picdump.sh` copies camera-card contents into a dated local archive and can
optionally sync that archive to a remote host over SSH using `rsync`.

The script contains no machine-specific paths or hostnames. Configure it with
command-line options or `PICDUMP_*` environment variables.

## Requirements

- Bash
- rsync
- SSH for remote transfers
- exiftool (required; reads capture dates for folder and file names)
- WSL2 `mountpoint` and `sudo` only when using `PICDUMP_WINDOWS_DRIVE`

## Usage

Copy a mounted card to a local archive:

```bash
./picdump.sh --source /media/user/CAMERA
```

Send the card straight to a remote destination, skipping the local copy:

```bash
./picdump.sh --mode nas \
  --source /media/user/CAMERA \
  --remote-base 'backup@example.org:/srv/photos/Unprocessed' \
  --ssh-port 4545
```

Copy the card to both the local archive and the remote destination:

```bash
./picdump.sh --mode both \
  --source /media/user/CAMERA \
  --remote-base 'backup@example.org:/srv/photos/Unprocessed' \
  --label vacation
```

Preview any run without copying anything by adding `--dry-run` (`-D`); rsync
lists what would be transferred and the output goes to the log file.

Remote transfer retries three times by default, waiting 30 seconds between
attempts. Change these settings with `--retries` and `--retry-delay`.

## Configuration

Options can instead be set in the environment:

| Variable | Purpose | Default |
| --- | --- | --- |
| `PICDUMP_MODE` | `local`, `nas`, or `both` | `local` |
| `PICDUMP_SOURCE` | Source directory (the card); required in all modes | unset |
| `PICDUMP_LOCAL_BASE` | Base directory of local archives | `~/Pictures/Unprocessed` |
| `PICDUMP_REMOTE_BASE` | Remote rsync destination, e.g. `user@host:/path` | unset |
| `PICDUMP_SSH_PORT` | SSH port for remote transfers | SSH default |
| `PICDUMP_WINDOWS_DRIVE` | Optional WSL2 Windows drive letter; auto-mounts at `/mnt/<letter>` | unset |
| `PICDUMP_LOG_FILE` | Log file | `~/.local/state/picdump/picdump.log` |
| `PICDUMP_LABEL` | Optional label in the dated folder name | unset |
| `PICDUMP_DRY_RUN` | `true` to preview transfers (same as `--dry-run`) | `false` |
| `PICDUMP_RETRIES` | Maximum remote attempts | `3` |
| `PICDUMP_RETRY_DELAY` | Seconds between remote attempts | `30` |

For example:

```bash
export PICDUMP_SOURCE=/mnt/e
export PICDUMP_LOCAL_BASE="$HOME/Pictures/Unprocessed"
export PICDUMP_REMOTE_BASE='backup@example.org:/srv/photos/Unprocessed'
export PICDUMP_SSH_PORT=4545
./picdump.sh --mode both --label family
```

When `PICDUMP_WINDOWS_DRIVE` is set, the script can mount the drive with
`sudo` if it is not already mounted. It unmounts only a drive mounted by the
script itself. Use `PICDUMP_SOURCE` for other operating systems and mount
setups.

## Sample `.bashrc` function

Put your settings in a function so a single command does everything. Adjust the
paths, host, and port; extra arguments (such as `-d label` or `-D`) pass through.

```bash
picdump() {
    PICDUMP_SOURCE=/mnt/e \
    PICDUMP_LOCAL_BASE="$HOME/Pictures/Unprocessed" \
    PICDUMP_REMOTE_BASE='backup@example.org:/srv/photos/Unprocessed' \
    PICDUMP_SSH_PORT=2828 \
    ~/code/picdump/picdump.sh "$@"
}
```

Then, for example:

```bash
picdump --mode both --label vacation   # card -> local and NAS
picdump -m nas                         # card -> NAS only
picdump -D                             # dry run
```

On WSL2, replace `PICDUMP_SOURCE=/mnt/e` with `PICDUMP_WINDOWS_DRIVE=e` to
auto-mount the drive.

## Getting a stable card location

The script needs the card at a predictable place. Pin it once, then reuse the
same setting.

### Windows / WSL2: fixed drive letter

Windows may assign a different letter each time. To pin one:

1. Insert the card and open Disk Management (`diskmgmt.msc`).
2. Right-click the volume, choose **Change Drive Letter and Paths...**, and
   pick a letter far down the alphabet, such as `Q`.

Or with `diskpart`: `select volume N`, then `assign letter=Q`.

Windows remembers the letter per volume, so it applies to that specific card;
a different or reformatted card needs the step repeated. Then set
`PICDUMP_WINDOWS_DRIVE=q`.

### Linux: stable mount point

Linux has no drive letters, but there are equivalents:

- **Volume label:** desktop auto-mounting uses `/media/<user>/<LABEL>`. Label
  the card (`fatlabel`, `exfatlabel`, or `e2label`) and use
  `--source "/media/$USER/<LABEL>"`. Cameras often already use a label such as
  `EOS_DIGITAL`, which also works across several cards.
- **Fixed `/etc/fstab` mount:** find the UUID with `lsblk -f`, then add:

  ```text
  UUID=1234-ABCD  /mnt/camera  exfat  noauto,user,uid=1000,gid=1000  0  0
  ```

  `mount /mnt/camera` then works without sudo, and `--source /mnt/camera`
  always points at the card. This is tied to that one card's UUID.
- **Stable device paths:** use `/dev/disk/by-uuid/...` or
  `/dev/disk/by-label/...` rather than `/dev/sdb1`, which can change.

### Using more than one card

The script only needs the card at the configured path, so any card works.

- **Windows/WSL2:** assign the same drive letter (for example `Q`) to each card
  once in Disk Management. Only one card is in the reader at a time, so there is
  no conflict, and `PICDUMP_WINDOWS_DRIVE=q` works for all of them.
- **Linux:** give the cards the same volume label, or use `/media/$USER/*`. A
  fixed `/etc/fstab` entry is tied to one UUID, so it needs one entry per card.
- **Filename collisions:** files are renamed by capture time (see below), so
  cards from the same day can safely share a dated folder.

## Destination folders and sync behavior

The folder date is the capture date of the first supported media file, or
today's date if none is found. A label, if provided,
is included in the directory name. For example:

```text
2026-11_-_family_-_03
```

Every mode reads directly from the card. `both` runs the local transfer,
then the remote one; if one fails the other still runs and the script exits
non-zero. The script does not delete files from either destination.

### File renaming

Files are renamed by capture time (`DateTimeOriginal`, then `CreateDate`, then
file modification time) as `YYYYMMDD_HHMMSS.ext`, with a lowercase extension.
This avoids collisions between cards that reuse names like `IMG_0001.JPG`.

- Files are flattened into the dated folder; the card's subfolders are not kept.
- Files with the same source name but different extensions (RAW+JPG) share one
  name. Different shots with the same timestamp get `_1`, `_2`, ... suffixes,
  assigned in sorted source-path order.
- Names are deterministic, so rerunning skips files already transferred.
  Suffixes can shift if files are deleted from the card between runs.
- Non-media files (for example text files) are renamed from their modification
  time too.

## Tests

Unit tests use [ShellSpec](https://github.com/shellspec/shellspec) with a stub
`exiftool` (in `spec/support/`), so neither a card nor exiftool is needed:

Install ShellSpec (no root needed), and make sure `~/.local/bin` is on your
`PATH`:

```bash
curl -fsSL https://git.io/shellspec | sh -s -- --yes
```

Or clone it instead of piping a script into `sh`:

```bash
git clone --depth 1 https://github.com/shellspec/shellspec.git ~/.shellspec
ln -s ~/.shellspec/shellspec ~/.local/bin/shellspec
```

Then run the tests from the project root:

```bash
shellspec
```

## License

[MIT](LICENSE)
