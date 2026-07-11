[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Destination,
    [string]$BackupPath = '',
    [double]$MinimumFreeGiB = 15,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Get-DefaultBackupPath {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Apple\MobileSync\Backup'),
        (Join-Path $env:APPDATA 'Apple Computer\MobileSync\Backup')
    )
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -eq 1) { return $existing[0] }
    if ($existing.Count -eq 0) { return $candidates[0] }
    throw "Multiple backup roots exist. Pass -BackupPath explicitly: $($existing -join ', ')"
}

function Get-TreeInventory {
    param([string]$Path)
    $count = [int64]0
    $bytes = [int64]0
    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction Stop | ForEach-Object {
            $count++
            $bytes += $_.Length
        }
    }
    [pscustomobject]@{ FileCount = $count; Bytes = $bytes; GiB = [math]::Round($bytes / 1GB, 2) }
}

function Normalize-Path {
    param([string]$Path)
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) { $BackupPath = Get-DefaultBackupPath }
$BackupPath = Normalize-Path $BackupPath
$Destination = Normalize-Path $Destination

if ($BackupPath.Equals($Destination, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BackupPath and Destination must be different.'
}
if ($Destination.StartsWith($BackupPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination cannot be inside BackupPath.'
}
if (Get-Process -Name AppleMobileBackup -ErrorAction SilentlyContinue) {
    throw 'AppleMobileBackup is running. Stop or finish the backup before migrating its directory.'
}

$sourceItem = Get-Item -LiteralPath $BackupPath -Force -ErrorAction SilentlyContinue
if ($sourceItem -and $sourceItem.LinkType -eq 'Junction') {
    $currentTarget = Normalize-Path (($sourceItem.Target | Select-Object -First 1))
    if ($currentTarget.Equals($Destination, [StringComparison]::OrdinalIgnoreCase)) {
        [pscustomobject]@{ State='AlreadyConfigured'; BackupPath=$BackupPath; Destination=$Destination; DryRun=[bool]$DryRun }
        exit 0
    }
    throw "BackupPath is already a junction to a different target: $currentTarget"
}

$destinationRoot = [IO.Path]::GetPathRoot($Destination)
$drive = [IO.DriveInfo]::new($destinationRoot)
if (-not $drive.IsReady) { throw "Destination drive is not ready: $destinationRoot" }

$source = Get-TreeInventory $BackupPath
$requiredBytes = $source.Bytes + [int64]($MinimumFreeGiB * 1GB)
if ($drive.AvailableFreeSpace -lt $requiredBytes) {
    throw ('Destination needs at least {0:N2} GiB free; only {1:N2} GiB is available.' -f ($requiredBytes/1GB), ($drive.AvailableFreeSpace/1GB))
}

$destinationExists = Test-Path -LiteralPath $Destination
if ($destinationExists) {
    $destinationBefore = Get-TreeInventory $Destination
    if ($destinationBefore.FileCount -gt 0 -and $source.FileCount -gt 0) {
        throw 'Destination is not empty. Refusing to merge opaque backup trees.'
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safetyCopy = "$BackupPath.pre-junction-$stamp"
$plan = [ordered]@{
    State = 'Planned'
    BackupPath = $BackupPath
    Destination = $Destination
    SafetyCopy = if ($sourceItem) { $safetyCopy } else { $null }
    SourceFiles = $source.FileCount
    SourceGiB = $source.GiB
    DestinationFreeGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 2)
    MinimumFreeGiB = $MinimumFreeGiB
    DryRun = [bool]$DryRun
}
if ($DryRun) { [pscustomobject]$plan; exit 0 }

$destinationParent = Split-Path -Parent $Destination
New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
New-Item -ItemType Directory -Path $Destination -Force | Out-Null

if ($sourceItem -and $source.FileCount -gt 0) {
    & robocopy.exe $BackupPath $Destination /E /ZB /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /NP /NFL /NDL
    $robocopyExit = $LASTEXITCODE
    if ($robocopyExit -ge 8) { throw "Robocopy failed with exit code $robocopyExit." }

    $destinationAfter = Get-TreeInventory $Destination
    if ($source.FileCount -ne $destinationAfter.FileCount -or $source.Bytes -ne $destinationAfter.Bytes) {
        throw "Copy verification failed. Source: $($source.FileCount) files/$($source.Bytes) bytes; destination: $($destinationAfter.FileCount) files/$($destinationAfter.Bytes) bytes."
    }
}

if ($sourceItem) { Rename-Item -LiteralPath $BackupPath -NewName (Split-Path -Leaf $safetyCopy) }
New-Item -ItemType Junction -Path $BackupPath -Target $Destination | Out-Null
$junction = Get-Item -LiteralPath $BackupPath -Force
$resolved = Normalize-Path (($junction.Target | Select-Object -First 1))
if ($junction.LinkType -ne 'Junction' -or -not $resolved.Equals($Destination, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Junction verification failed. Keep the safety copy and repair the link manually.'
}

$plan.State = 'Configured'
[pscustomobject]$plan
