[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$BackupLink = '',
    [string]$StatusPath = '',
    [string]$LogPath = '',
    [int]$CheckIntervalSeconds = 300,
    [int]$StallChecks = 3,
    [int]$MaxRetries = 3,
    [double]$MinimumFreeGiB = 15,
    [int[]]$RetryDelayMinutes = @(5, 10, 20),
    [switch]$EnableRecovery,
    [switch]$Once,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$controlNames = @('Info.plist','Manifest.plist','Manifest.db','Status.plist')
$appAumid = 'AppleInc.AppleDevices_nzyj5cx40ttqa!App'

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AppleBackupSleepGuard {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$continuous = [Convert]::ToUInt32('80000000', 16)
$systemRequired = [uint32]0x00000001

function Get-DefaultBackupPath {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Apple\MobileSync\Backup'),
        (Join-Path $env:APPDATA 'Apple Computer\MobileSync\Backup')
    )
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -eq 1) { return $existing[0] }
    if ($existing.Count -eq 0) { return $candidates[0] }
    throw "Multiple backup roots exist. Pass -BackupLink explicitly: $($existing -join ', ')"
}

function Normalize-Path([string]$Path) { [IO.Path]::GetFullPath($Path).TrimEnd('\') }

if ([string]::IsNullOrWhiteSpace($BackupLink)) { $BackupLink = Get-DefaultBackupPath }
$BackupLink = Normalize-Path $BackupLink
$linkItem = Get-Item -LiteralPath $BackupLink -Force -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($Target)) {
    if (-not $linkItem -or $linkItem.LinkType -ne 'Junction') { throw 'Pass -Target, or configure BackupLink as a junction first.' }
    $Target = [string]($linkItem.Target | Select-Object -First 1)
}
$Target = Normalize-Path $Target
if ([string]::IsNullOrWhiteSpace($StatusPath)) { $StatusPath = Join-Path $PSScriptRoot 'apple_backup_watch_status.json' }
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $PSScriptRoot 'apple_backup_watch.log' }

$startedAt = Get-Date
$retryCount = 0
$noProgressChecks = 0
$stableCompletionChecks = 0
$nextRetryAt = $null
$lastBytes = $null
$lastCount = $null
$lastCpu = $null
$lastProgressAt = Get-Date
$lastError = ''

function Write-Log([string]$Level,[string]$Message) {
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("{0}`t{1}`t{2}" -f (Get-Date).ToString('o'),$Level,$Message)
}

function Get-BackupProcess { Get-Process -Name AppleMobileBackup -ErrorAction SilentlyContinue | Select-Object -First 1 }

function Get-JunctionState {
    $item = Get-Item -LiteralPath $BackupLink -Force -ErrorAction SilentlyContinue
    $resolved = if ($item -and $item.LinkType -eq 'Junction') { Normalize-Path ([string]($item.Target | Select-Object -First 1)) } else { '' }
    [pscustomobject]@{
        Exists = [bool]$item
        LinkType = if ($item) { [string]$item.LinkType } else { '' }
        Target = $resolved
        Valid = [bool]($item -and $item.LinkType -eq 'Junction' -and $resolved.Equals($Target,[StringComparison]::OrdinalIgnoreCase))
    }
}

function Get-Inventory {
    $count = [int64]0; $bytes = [int64]0; $latest = $null
    Get-ChildItem -LiteralPath $Target -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        $count++; $bytes += $_.Length
        if ($null -eq $latest -or $_.LastWriteTime -gt $latest) { $latest = $_.LastWriteTime }
    }
    $folders = @(Get-ChildItem -LiteralPath $Target -Force -Directory -ErrorAction SilentlyContinue)
    $folder = $folders | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $present = @{}; $uploading = $false
    foreach ($name in $controlNames) {
        $present[$name] = $false
        if ($folder) {
            $path = Join-Path $folder.FullName $name
            $present[$name] = Test-Path -LiteralPath $path
            if ($name -eq 'Status.plist' -and $present[$name]) {
                try {
                    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
                    $uploading = [bool]($text -match '(?i)uploading')
                } catch {}
            }
        }
    }
    [pscustomobject]@{
        FileCount=$count; Bytes=$bytes; GiB=[math]::Round($bytes/1GB,2); LatestWrite=$latest
        DeviceFolder=if($folder){$folder.FullName}else{$null}
        InfoPlist=$present['Info.plist']; ManifestPlist=$present['Manifest.plist']
        ManifestDb=$present['Manifest.db']; StatusPlist=$present['Status.plist']
        Uploading=$uploading
        AllControlFiles=[bool]($present['Info.plist'] -and $present['Manifest.plist'] -and $present['Manifest.db'] -and $present['Status.plist'])
    }
}

function Test-IPhoneConnected {
    try { return [bool](((& pnputil.exe /enum-devices /connected 2>$null) -join "`n") -match 'Apple iPhone|VID_05AC&PID_12A8|Apple Mobile Device USB') }
    catch { return $false }
}

function Get-AppRoot {
    $p = Get-Process -Name AppleDevices -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    if ($p) { [Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle) }
}

function Get-UiState {
    $root = Get-AppRoot
    if (-not $root) { return [pscustomobject]@{Open=$false;Locked=$false;Error='';LastBackup='';LastBackupConfirmed=$false;Retry=$false;BackupNow=$false} }
    $nodes = $root.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    $names = [Collections.Generic.List[string]]::new()
    for($i=0;$i -lt $nodes.Count;$i++){ $n=[string]$nodes.Item($i).Current.Name; if($n){$names.Add($n)} }
    $error = [string]($names | Where-Object { $_ -match '未能备份|Could not back up|backup.*failed' } | Select-Object -First 1)
    $last = [string]($names | Where-Object { $_ -match '上次备份|Last backup' } | Select-Object -First 1)
    [pscustomobject]@{
        Open=$true
        Locked=[bool](($names -join "`n") -match '密码锁定|输入密码|passcode locked|enter.*passcode')
        Error=$error
        LastBackup=$last
        LastBackupConfirmed=[bool]($last -and $last -notmatch '从未|Never')
        Retry=[bool]($names | Where-Object { $_ -match '^(重试|Retry)' })
        BackupNow=[bool]($names | Where-Object { $_ -match '^(立即备份|Back Up Now)$' })
    }
}

function Invoke-Button([string[]]$Names) {
    $root = Get-AppRoot; if(-not $root){return $false}
    foreach($name in $Names){
        $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,$name)
        $node = $root.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
        if($node -and $node.Current.IsEnabled){
            if($DryRun){Write-Log 'DRYRUN' "Would invoke $name"; return $true}
            $node.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
            Write-Log 'RECOVERY' "Invoked $name"; return $true
        }
    }
    return $false
}

function Start-App {
    if(Get-AppRoot){return $true}
    if($DryRun){Write-Log 'DRYRUN' 'Would open Apple Devices'; return $true}
    Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$appAumid"
    for($i=0;$i -lt 20;$i++){Start-Sleep 1;if(Get-AppRoot){return $true}}
    return $false
}

function Invoke-Recovery([object]$Ui) {
    if(-not $EnableRecovery){return $false}
    if(-not (Test-IPhoneConnected)){ $script:lastError='iPhone is disconnected.'; return $false }
    if($Ui.Locked){ $script:lastError='iPhone is locked. Unlock it before retrying.'; return $false }
    if(-not (Get-JunctionState).Valid){ $script:lastError='Backup junction is invalid.'; return $false }
    if(-not (Start-App)){ $script:lastError='Apple Devices could not be opened.'; return $false }
    Start-Sleep 2; $Ui=Get-UiState
    if($Ui.Retry -and (Invoke-Button @('重试','Retry','Retry (T)'))){return $true}
    if($Ui.Error){ [void](Invoke-Button @('确定','OK','取消','Cancel')); Start-Sleep 2 }
    # Do not toggle encryption. UI selection changes are intentionally left to the user.
    return (Invoke-Button @('立即备份','Back Up Now'))
}

function Write-Status([string]$State,[string]$Message,[string]$NextAction,[object]$Process,[object]$Inventory,[object]$Ui,[object]$Link,[object]$Drive) {
    [ordered]@{
        State=$State; Message=$Message; Updated=(Get-Date).ToString('o'); StartedAt=$startedAt.ToString('o')
        NextAction=$NextAction; NextRetryAt=if($nextRetryAt){$nextRetryAt.ToString('o')}else{$null}
        RetryCount=$retryCount; MaxRetries=$MaxRetries; NoProgressChecks=$noProgressChecks
        LastProgressAt=$lastProgressAt.ToString('o'); LastError=$lastError
        ProcessId=if($Process){$Process.Id}else{$null}; ProcessCPUSeconds=if($Process){[math]::Round($Process.CPU,1)}else{$null}
        FileCount=$Inventory.FileCount; BackupBytes=$Inventory.Bytes; BackupGiB=$Inventory.GiB
        LatestFileWrite=if($Inventory.LatestWrite){$Inventory.LatestWrite.ToString('o')}else{$null}
        InfoPlist=$Inventory.InfoPlist; ManifestPlist=$Inventory.ManifestPlist; ManifestDb=$Inventory.ManifestDb
        StatusPlist=$Inventory.StatusPlist; StatusContainsUploading=$Inventory.Uploading; AllControlFiles=$Inventory.AllControlFiles
        CFreeGiB=[math]::Round(([IO.DriveInfo]::new('C:\')).AvailableFreeSpace/1GB,2)
        DestinationFreeGiB=[math]::Round($Drive.AvailableFreeSpace/1GB,2); MinimumFreeGiB=$MinimumFreeGiB
        JunctionValid=$Link.Valid; JunctionTarget=$Link.Target; IPhoneConnected=Test-IPhoneConnected
        AppleDevicesOpen=$Ui.Open; AppleDevicesError=$Ui.Error; AppleDevicesLastBackup=$Ui.LastBackup
        RecoveryEnabled=[bool]$EnableRecovery; DryRun=[bool]$DryRun; Target=$Target; BackupLink=$BackupLink
    } | ConvertTo-Json | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

Write-Log 'INFO' "Watchdog started. Target=$Target; recovery=$([bool]$EnableRecovery); dryRun=$([bool]$DryRun)"
try {
    [void][AppleBackupSleepGuard]::SetThreadExecutionState($continuous -bor $systemRequired)
    while($true){
        $now=Get-Date; $process=Get-BackupProcess; $inventory=Get-Inventory; $ui=Get-UiState; $link=Get-JunctionState
        $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($Target))
        if(-not $link.Valid){ Write-Status 'Blocked' 'Backup junction is missing or points elsewhere.' 'RepairJunction' $process $inventory $ui $link $drive; exit 3 }
        if(($drive.AvailableFreeSpace/1GB) -lt $MinimumFreeGiB){
            $lastError="Destination free space is below $MinimumFreeGiB GiB."
            if($EnableRecovery -and $process -and -not $DryRun){Stop-Process -Id $process.Id -Force}
            Write-Log 'FATAL' $lastError; Write-Status 'StoppedLowSpace' $lastError 'FreeSpaceRequired' $null $inventory $ui $link $drive; exit 2
        }

        $fileProgress=($null -eq $lastBytes -or $inventory.Bytes -gt $lastBytes -or $inventory.FileCount -gt $lastCount)
        $cpuProgress=($process -and $null -ne $lastCpu -and ($process.CPU-$lastCpu) -ge 0.5)
        if($fileProgress -or $cpuProgress){$noProgressChecks=0;$lastProgressAt=$now}elseif($process){$noProgressChecks++}
        $lastBytes=$inventory.Bytes;$lastCount=$inventory.FileCount;$lastCpu=if($process){$process.CPU}else{$null}

        if($process){
            $stableCompletionChecks=0
            if($noProgressChecks -ge $StallChecks){
                $lastError="No file or CPU progress for $([math]::Round($StallChecks*$CheckIntervalSeconds/60,1)) minutes."
                Write-Log 'ERROR' $lastError
                if($EnableRecovery -and -not $DryRun){Stop-Process -Id $process.Id -Force;$nextRetryAt=$now.AddMinutes(5)}
                Write-Status 'Stalled' $lastError $(if($EnableRecovery){'RetryWhenDue'}else{'ManualReviewRequired'}) $null $inventory $ui $link $drive
            } else { Write-Status 'Running' 'Backup is making progress.' 'ContinueMonitoring' $process $inventory $ui $link $drive }
        } else {
            $completionEvidence=($inventory.AllControlFiles -and -not $inventory.Uploading)
            if($completionEvidence -and $ui.LastBackupConfirmed){
                $stableCompletionChecks++
                if($stableCompletionChecks -ge 2){Write-Log 'SUCCESS' 'Backup completion verified.';Write-Status 'Completed' 'Backup completion verified.' 'None' $null $inventory $ui $link $drive;exit 0}
                Write-Status 'VerifyingCompletion' 'Completion indicators found; waiting for a stable second check.' 'VerifyAgain' $null $inventory $ui $link $drive
            } elseif($completionEvidence){
                Write-Status 'VerifyingCompletion' 'Control files are complete; visually confirm the Last backup time in Apple Devices.' 'VerifyAppleDevicesLastBackup' $null $inventory $ui $link $drive
            } elseif(-not (Test-IPhoneConnected)){
                $lastError='iPhone is disconnected.';Write-Status 'WaitingForDevice' $lastError 'ReconnectIPhone' $null $inventory $ui $link $drive
            } elseif($ui.Locked){
                $lastError='iPhone is locked.';Write-Status 'WaitingForUnlock' $lastError 'UnlockIPhone' $null $inventory $ui $link $drive
            } elseif($EnableRecovery){
                if($null -eq $nextRetryAt){$nextRetryAt=$now}
                if($now -ge $nextRetryAt){
                    if($retryCount -ge $MaxRetries){$lastError='Maximum automatic recovery attempts were exhausted.';Write-Status 'NeedsUserAttention' $lastError 'ManualReviewRequired' $null $inventory $ui $link $drive;exit 4}
                    $retryCount++;$recovered=Invoke-Recovery $ui
                    $delay=$RetryDelayMinutes[[math]::Min($retryCount-1,$RetryDelayMinutes.Count-1)];$nextRetryAt=$now.AddMinutes($delay)
                    Write-Status $(if($recovered){'Recovering'}else{'RecoveryDeferred'}) $(if($recovered){"Recovery attempt $retryCount was invoked."}else{$lastError}) 'WaitForBackupProcess' $null $inventory (Get-UiState) $link $drive
                } else {Write-Status 'WaitingToRetry' $lastError 'RetryWhenDue' $null $inventory $ui $link $drive}
            } else {Write-Status 'Idle' 'No backup process is running.' 'StartBackupManually' $null $inventory $ui $link $drive}
        }
        if($Once){break}
        Start-Sleep -Seconds $CheckIntervalSeconds
    }
} catch {
    $lastError=$_.Exception.Message;Write-Log 'FATAL' $lastError;throw
} finally {
    [void][AppleBackupSleepGuard]::SetThreadExecutionState($continuous)
}
