<#
.SYNOPSIS
    Bootstrap of the WATCHOUT factory recovery. Lives INSIDE boot.wim at
    X:\WORecovery\Start-WORecovery.ps1 (tools/recovery/Build-WinPE.ps1 puts
    it there), started by startnet.cmd.

.DESCRIPTION
    Kept small so boot.wim rarely needs rebuilding: it gives the hidden
    WO_RECOVERY partition a drive letter (its GPT "no drive letter" attribute
    stops WinPE from doing it), then runs WO-Recovery.ps1 from the first of:
      1. the internal recovery partition (installed by the setup wizard),
      2. a recovery USB stick (tools/recovery/New-RecoveryUsb.ps1),
      3. the copy built into boot.wim (X:\WORecovery\WO-Recovery.ps1).
    Windows PowerShell 5.1 (WinPE-PowerShell + WinPE-StorageWMI).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { "$($_.GptType)" -ieq $recoveryType })) {
    $v = $p | Get-Volume -ErrorAction SilentlyContinue
    if ($v -and $v.FileSystemLabel -eq 'WO_RECOVERY' -and "$($p.DriveLetter)" -notmatch '^[A-Za-z]$') {
        $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
    }
}

$internal = $null; $usb = $null
foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' })) {
    $root = "$($v.DriveLetter):\"
    if (-not (Test-Path -LiteralPath (Join-Path $root 'WO_RECOVERY.tag'))) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'WO-Recovery.ps1'))) { continue }
    $isUsb = $false
    $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue
    if ($part) { $isUsb = ("$((Get-Disk -Number $part.DiskNumber).BusType)" -eq 'USB') }
    if ($isUsb) { if (-not $usb) { $usb = $root } } elseif (-not $internal) { $internal = $root }
}

$script = $null
if ($internal) { $script = Join-Path $internal 'WO-Recovery.ps1' }
elseif ($usb) { $script = Join-Path $usb 'WO-Recovery.ps1' }
elseif (Test-Path -LiteralPath 'X:\WORecovery\WO-Recovery.ps1') { $script = 'X:\WORecovery\WO-Recovery.ps1' }

if (-not $script) { Write-Host 'WO-Recovery.ps1 not found on any volume.'; exit 1 }
Write-Host "Starting $script"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
