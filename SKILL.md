---
name: apple-devices-backup-watchdog-skill
description: Safely relocate, monitor, recover, and verify Apple Devices or iTunes local iPhone/iPad backups on Windows. Use when Codex needs to move MobileSync backups to another drive through a directory junction, diagnose a full system drive during backup, watch AppleMobileBackup progress, prevent sleep, detect stalls or disconnects, perform explicitly authorized bounded recovery, or verify that a whole-device backup is restorable without touching personal media or deleting prior backups.
---

# Apple Devices Backup Watchdog

Use a conservative workflow for Windows local backups created by Apple Devices or iTunes. Treat backup directories as opaque databases; never reorganize, rename, deduplicate, or edit their internal files.

## Safety baseline

1. Inspect before changing anything. Record the source path, destination path, drive space, junction state, backup process, file count, byte count, and latest write time.
2. Refuse migration while `AppleMobileBackup` is running. Ask the user to stop the backup or obtain explicit permission before stopping it.
3. Preserve the user's encryption choice. Never enable, disable, or change a backup password automatically.
4. Never delete a source, safety copy, failed session, or phone content without a separate explicit request naming the target.
5. Prefer `-DryRun` first. Confirm every resolved absolute path before a recursive operation.
6. Keep logs and status files out of public repositories because paths and device identifiers may be personal.

## Locate the active backup root

Check both common locations and inspect their item types:

- `%USERPROFILE%\Apple\MobileSync\Backup` for Apple Devices and newer installations.
- `%APPDATA%\Apple Computer\MobileSync\Backup` for legacy iTunes.

If a path is a junction, resolve its target and operate on that target. If both locations contain ordinary directories, compare recent writes and ask before selecting one.

## Relocate a backup safely

Use `scripts/Prepare-AppleDevicesBackupTarget.ps1`.

1. Run with `-DryRun`, an explicit `-Destination`, and `-BackupPath` when auto-detection is ambiguous.
2. Require destination free space to exceed the source size plus the configured reserve.
3. Copy with restartable Windows semantics, then compare file count and total bytes.
4. Rename the original to a timestamped safety copy and create a directory junction at the original path.
5. Verify the junction resolves to the destination before starting Apple Devices.
6. Retain the safety copy until a completed backup and restore visibility have been confirmed.

Example:

```powershell
.\scripts\Prepare-AppleDevicesBackupTarget.ps1 `
  -Destination 'G:\iPhoneBackup\AppleDeviceBackup' `
  -DryRun
```

Remove `-DryRun` only after reviewing the reported paths and space.

## Monitor and recover

Use `scripts/Watch-AppleDevicesBackup.ps1`. Start in monitor-only mode. Add `-EnableRecovery` only when the user explicitly authorizes UI actions and bounded process recovery.

```powershell
.\scripts\Watch-AppleDevicesBackup.ps1 `
  -Target 'G:\iPhoneBackup\AppleDeviceBackup' `
  -CheckIntervalSeconds 300 `
  -StallChecks 3 `
  -MaxRetries 3
```

The watcher must:

- Prevent system sleep while it runs.
- Check `AppleMobileBackup`, file count, total bytes, last write, device connection, junction validity, C/destination free space, Apple Devices UI signals, and backup control files.
- Treat three unchanged checks at five-minute intervals, with no meaningful process CPU growth, as a stall.
- Wait for a locked or disconnected phone. Do not loop recovery while the device is unavailable.
- Stop automatic recovery when destination free space is below the threshold.
- Use retry delays of 5, 10, and 20 minutes and stop after three attempts.
- Never toggle encryption.

## Verify completion

Require all of the following before declaring completion:

- `AppleMobileBackup` has exited.
- `Info.plist`, `Manifest.plist`, `Manifest.db`, and `Status.plist` exist in the current device backup folder.
- `Status.plist` no longer reports an uploading state.
- The directory is stable across two checks.
- Apple Devices shows a current “Last backup” time. If UI text cannot be read, report `VerifyingCompletion` and request a visual confirmation instead of restarting the backup.

Read [references/backup-safety.md](references/backup-safety.md) when explaining backup coverage, Live Photos, metadata, encryption tradeoffs, or restoration.
