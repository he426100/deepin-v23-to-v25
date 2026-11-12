deepin-v23-to-v25 - Deepin 23 to 25 in-place upgrade tool
==========================================================

READ THIS IN A TTY
------------------
Switch to a TTY with Ctrl+Alt+F3 (some laptops: Fn+Ctrl+Alt+F3).
Log in, then use sudo. Return to the desktop with Ctrl+Alt+F7.
This file is ASCII only so it stays readable in the Linux console.

The tool is installed at /opt/deepin-v23-to-v25.
Commands: deepin-v25 or deepin-v23-to-v25 (both are linked).


BEFORE THE UPGRADE (on Deepin 23)
---------------------------------
  cd ~/git/deepin-v23-to-v25

  # 1. Read-only checks: version, disk, boot, GPU, mirror, backup.
  sudo ./bin/deepin-v25 preflight

  # 2. Find data worth backing up (writes a suggestion file only).
  sudo ./bin/deepin-v25 scan

  # 3. Back up to a disk on a DIFFERENT filesystem.
  sudo ./bin/deepin-v25 backup --dest /media/USER/backup

  # 4. Install the tool to /opt so it works from a TTY.
  sudo ./bin/deepin-v25 install

  # 5. Switch to a TTY (Ctrl+Alt+F3), log in, then:
  sudo deepin-v25 upgrade

The upgrade asks you to type UPGRADE. It stops lightdm and Docker,
quarantines third-party apt sources, switches to the crimson mirror,
simulates, downloads, runs full-upgrade, then verifies.

If power, network or the terminal dies: log in to a TTY again and run
  sudo deepin-v25 upgrade
It resumes from the apt breakpoint. A backup is NOT repeated.
If the system is already detected as V25, run "sudo deepin-v25 post" to
finish the remaining full-upgrade and desktop repair.


FIRST BOOT INTO DEEPIN 25
-------------------------
Log in to the desktop, open a terminal, then:
  sudo deepin-v25 post

This runs apt update, dpkg repair, finishes the upgrade, restores
desktop packages, restarts DDE services and Docker containers.

Known issue: the first V25 login can have broken window borders and no
dock. On the reference machine, running apt update in a TTY and
returning to the desktop fixed it. The root cause was not proven (the
old journal had already rotated). post/fix-desktop apply that fix plus
service restarts.

If the desktop is still broken:
  sudo deepin-v25 fix-desktop
  sudo deepin-v25 fix-desktop --restart-session
  sudo deepin-v25 fix-desktop --reset-user-config   # moves old config
  sudo deepin-v25 diagnose


IF THE DESKTOP DOES NOT START (TTY RESCUE)
------------------------------------------
Ctrl+Alt+F3, log in, then:
  sudo deepin-v25 rescue
  sudo systemctl start lightdm

rescue repairs dpkg/apt and reinstalls missing desktop packages.
If root is read-only or immutable packages are present, it refuses:
fix the cause (disable immutable protection on V25, or fix the filesystem
or ro mount on V23), reboot, then retry.


THIRD-PARTY APT SOURCES
-----------------------
All *.list and *.sources files were moved to
  /var/lib/deepin-v23-to-v25/quarantine/apt-sources/disabled/

  sudo deepin-v25 sources status
  sudo deepin-v25 sources restore FILE
  sudo deepin-v25 sources restore --all

Restore tests each source. If apt update fails, the source is
quarantined again. Upgrade or reinstall the app instead of trusting an
expired key.


RESTORE A BACKUP
----------------
The backup is self-contained:
  sudo bash /media/USER/backup/deepin-backup-*/restore-backup.sh
  sudo bash /media/USER/backup/deepin-backup-*/restore-backup.sh --system
  sudo bash /media/USER/backup/deepin-backup-*/restore-backup.sh \
       --map oldname=newname

Or with the tool:
  sudo deepin-v25 restore --from /media/USER/backup/deepin-backup-... \
       [--system] [--map oldname=newname] [--passphrase-file FILE]

Encrypted archives ask for the passphrase. checksums.sha256 is verified
first. User data is restored to the original paths; same-name files are
overwritten. --system also restores extra paths outside home and needs
an extra confirmation.

Do not delete anything from the backup directory: manifest.env,
archives.tsv, checksums.sha256, restore-backup.sh and tool/ are needed
for a restore.


LOGS AND DIAGNOSTICS
--------------------
  /var/log/deepin-v23-to-v25/     one log per run
  /var/lib/deepin-v23-to-v25/     state, quarantine, pre-upgrade snapshot
  journalctl -b -p err            errors from this boot
  journalctl -b -1                previous boot (if it still exists)
  sudo deepin-v25 diagnose        collects a desktop-failure report

Persistent journald is enabled before the upgrade so the first V25 boot
can still be inspected afterwards.


EMERGENCY COMMANDS
------------------
  sudo apt update
  sudo dpkg --configure -a
  sudo apt-get -y --fix-broken install
  sudo systemctl restart lightdm
  sudo systemctl --failed
  df -h / /boot
  nvidia-smi; dkms status

Old kernels stay installed. If the new kernel does not boot, choose
"Advanced options for Deepin" in GRUB and pick the previous kernel.


SAFETY NOTES
------------
- Back up before upgrading. A backup on the same filesystem as / is
  refused by default.
- Keep the tool on an ASCII path on the root filesystem. A TTY may not
  mount an NTFS/Windows partition, and Chinese paths cannot be typed
  in the console.
- --force and --yes skip safeguards. Do not use them unless you know
  exactly why.
- --dry-run installs nothing and does not change apt sources or user
  data, but it still writes a log and a pre-upgrade state snapshot.
- Official Deepin does not support 23 -> 25 in-place upgrades. This
  tool is experimental. Keep a Deepin 25 USB installer as a fallback.
