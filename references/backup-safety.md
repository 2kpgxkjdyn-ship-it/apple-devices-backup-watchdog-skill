# Backup safety and restoration reference

## Contents

- Backup formats and paths
- Media and metadata coverage
- Encryption tradeoffs
- Completion evidence
- Restoration
- Recovery boundaries

## Backup formats and paths

Apple Devices creates an opaque MobileSync backup made of hashed files plus manifests and property lists. It is not a browsable photo library. Preserve the whole device-folder structure exactly.

Common Windows roots:

- `%USERPROFILE%\Apple\MobileSync\Backup`
- `%APPDATA%\Apple Computer\MobileSync\Backup`

A directory junction may redirect either root to another local NTFS volume. Apple Devices must continue seeing the original path.

## Media and metadata coverage

A whole-device backup is intended for restoring the device state. Photos, videos, capture times, locations, edits, albums, and Live Photo pairing depend on the Photos database and paired assets remaining coherent. Do not rename or extract individual hashed backup files as a substitute for restoration.

Live Photos normally consist of a still-image component and a motion-video component linked by metadata. The safest preservation method is a verified whole-device backup plus, when practical, a separate export of original media files.

If iCloud Photos with storage optimization is enabled, some full-resolution originals may live only in iCloud. A local device backup cannot guarantee inclusion of an original that is not present on the device. Check the iPhone's Photos/iCloud settings and download status separately.

## Encryption tradeoffs

Respect the user's selection. An encrypted local backup can include additional sensitive categories such as saved passwords, Wi-Fi settings, Health data, and call history. An unencrypted backup omits some protected categories. Never toggle encryption or invent/store a password on the user's behalf.

## Completion evidence

Strong completion evidence combines:

1. `AppleMobileBackup` exited normally.
2. `Info.plist`, `Manifest.plist`, `Manifest.db`, and `Status.plist` exist.
3. `Status.plist` no longer contains an uploading state.
4. File count, byte count, and latest-write time are stable across two checks.
5. Apple Devices displays a current last-backup timestamp.

Control files alone are not sufficient if Apple Devices still reports an error or no completed backup.

## Restoration

Keep the backup under the MobileSync `Backup` root, either directly or through the verified junction. Connect and unlock the iPhone or iPad, open Apple Devices, choose the device, select **Restore Backup**, select the desired timestamp, and keep the device connected through reboot and completion.

Restoration replaces device state. Confirm the destination device and preserve current data before starting. An encrypted backup requires its original password.

## Recovery boundaries

- Locked phone: wait for manual unlock, then invoke Retry at most within the configured limit.
- Disconnected phone: wait for reconnection; do not repeatedly click Backup.
- Apple Devices closed: reopen only with explicit recovery authorization.
- Generic session failure: dismiss the error, revalidate the junction and destination, confirm the existing encryption state, then retry.
- Low destination space: stop automatic actions and require space to be freed.
- Exhausted retries: stop and report the last error, paths, disk space, and status file.
