# Apple Devices Backup Watchdog Skill

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-blue.svg)](#requirements--运行要求)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#requirements--运行要求)

A safety-first Codex Skill for relocating, monitoring, recovering, and verifying local Apple Devices or iTunes backups on Windows.

一套安全优先的 Codex Skill，用于在 Windows 上迁移、监测、有限恢复并验证 Apple Devices 或 iTunes 的本地 iPhone/iPad 整机备份。

## 中文

### 功能

- 将默认的 `MobileSync\Backup` 安全迁移到空间更充足的本地 NTFS 磁盘。
- 在原位置建立 Windows 目录联接，让 Apple Devices 继续使用默认路径。
- 每隔一段时间检查备份进程、文件数量、总大小、最近写入时间和磁盘余量。
- 在监测期间阻止电脑自动睡眠。
- 识别手机断线、锁定、目标空间不足、目录联接异常和备份停滞。
- 在用户明确启用后，最多执行三次有限恢复，默认间隔为 5、10、20 分钟。
- 使用四个控制文件、上传状态、目录稳定性和 Apple Devices 的“上次备份”时间验证完成状态。
- 保持用户现有的加密选择，不自动开启、关闭或更改备份密码。

### 安全原则

这套工具把 Apple 备份视为不可拆分的数据库，不会整理、重命名或去重内部的散列文件。

- 默认先使用 `-DryRun`，检查解析后的真实路径和空间。
- 备份进程运行时拒绝迁移。
- 迁移后保留带时间戳的原目录安全副本，不自动删除。
- 目标目录非空时拒绝合并两个不透明的备份树。
- 默认只监测；必须显式添加 `-EnableRecovery` 才会执行恢复操作。
- 低空间、断线或锁屏时不会盲目循环重试。
- 不删除手机内容、旧备份或其他磁盘文件。

### 运行要求

- Windows 10 或 Windows 11
- Apple Devices 或 iTunes
- Windows PowerShell 5.1 或更高版本
- 目标位置建议使用本地 NTFS 磁盘
- 足够容纳当前备份并额外保留至少 15 GiB 的空间

### 安装为 Codex Skill

方式一：让 Codex 使用 `skill-installer` 从本仓库安装：

```text
Install the skill from https://github.com/2kpgxkjdyn-ship-it/apple-devices-backup-watchdog-skill
```

方式二：手动克隆到个人 Skill 目录：

```powershell
git clone https://github.com/2kpgxkjdyn-ship-it/apple-devices-backup-watchdog-skill.git `
  "$env:USERPROFILE\.codex\skills\apple-devices-backup-watchdog-skill"
```

重新启动 Codex 或开启新任务，让 Skill 被重新发现。

### 快速开始

先确认 Apple Devices 当前没有正在备份，然后执行迁移模拟：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Prepare-AppleDevicesBackupTarget.ps1 `
  -Destination 'G:\iPhoneBackup\AppleDeviceBackup' `
  -DryRun
```

检查输出中的源路径、目标路径、文件数量和空间后，移除 `-DryRun` 执行迁移：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Prepare-AppleDevicesBackupTarget.ps1 `
  -Destination 'G:\iPhoneBackup\AppleDeviceBackup'
```

启动只监测模式：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Watch-AppleDevicesBackup.ps1 `
  -Target 'G:\iPhoneBackup\AppleDeviceBackup' `
  -CheckIntervalSeconds 300 `
  -StallChecks 3 `
  -MaxRetries 3
```

只有在已经确认路径、手机和备份选项后，才添加 `-EnableRecovery`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Watch-AppleDevicesBackup.ps1 `
  -Target 'G:\iPhoneBackup\AppleDeviceBackup' `
  -EnableRecovery
```

状态默认写入 `scripts\apple_backup_watch_status.json`，运行日志默认写入 `scripts\apple_backup_watch.log`；两者已被 `.gitignore` 排除。

### 完成判定

只有同时满足以下条件，备份才应被视为完成：

1. `AppleMobileBackup` 已退出。
2. 当前设备备份目录存在 `Info.plist`、`Manifest.plist`、`Manifest.db` 和 `Status.plist`。
3. `Status.plist` 不再包含上传中状态。
4. 文件数量、大小和最近写入时间连续两次检查保持稳定。
5. Apple Devices 显示本次“上次备份”时间。

如果程序无法读取界面文字，它会停在 `VerifyingCompletion`，要求人工查看 Apple Devices，而不会自动重新开始备份。

### 照片、视频和实况照片

整机备份不是可以直接浏览的照片目录。照片、视频、拍摄时间、地点、编辑记录和实况照片配对依赖照片数据库与对应资源保持一致，因此不要直接重命名或抽取散列文件来代替恢复。

如果启用了“优化 iPhone 储存空间”，部分全分辨率原片可能只存在于 iCloud。任何本地备份都无法保证包含当时并未下载到设备上的原片。

恢复时应保持备份位于 Apple 的 `MobileSync\Backup` 路径下，连接并解锁设备，然后在 Apple Devices 中选择“恢复备份”。

## English

### What it does

- Relocates the default `MobileSync\Backup` directory to a larger local NTFS drive.
- Creates a Windows directory junction so Apple Devices continues to use its default path.
- Monitors the backup process, file count, total bytes, latest write time, device connection, junction, and disk space.
- Prevents system sleep while monitoring.
- Detects stalls, disconnects, device locks, invalid junctions, and low destination space.
- Performs at most three bounded recovery attempts only when `-EnableRecovery` is explicitly supplied.
- Verifies completion using Apple control files, upload state, directory stability, and the Apple Devices last-backup timestamp.
- Never changes the user's local-backup encryption setting.

### Quick start

Preview a migration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Prepare-AppleDevicesBackupTarget.ps1 `
  -Destination 'G:\iPhoneBackup\AppleDeviceBackup' `
  -DryRun
```

Start in monitor-only mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Watch-AppleDevicesBackup.ps1 `
  -Target 'G:\iPhoneBackup\AppleDeviceBackup'
```

Enable bounded UI recovery only after reviewing the paths and backup settings:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\Watch-AppleDevicesBackup.ps1 `
  -Target 'G:\iPhoneBackup\AppleDeviceBackup' `
  -EnableRecovery
```

### Important limitations

- A whole-device backup is an opaque restore database, not a browsable media export.
- iCloud-optimized originals that are absent from the device may not be present in a local backup.
- Unencrypted backups omit some protected categories. Encrypted backups require the original password.
- UI automation currently recognizes common English and Simplified Chinese Apple Devices labels. Other locales may require manual confirmation.
- Always keep an independent copy of irreplaceable media when possible.

## Repository layout

```text
.
├── SKILL.md
├── agents/
│   └── openai.yaml
├── references/
│   └── backup-safety.md
└── scripts/
    ├── Prepare-AppleDevicesBackupTarget.ps1
    └── Watch-AppleDevicesBackup.ps1
```

## Contributing

Issues and pull requests are welcome. Do not attach real backup manifests, device identifiers, logs containing personal paths, or any files copied from an iPhone backup.

## License

Released under the [MIT License](LICENSE).
