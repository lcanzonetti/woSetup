#requires -RunAsAdministrator
<#
.SYNOPSIS
    Makes a WATCHOUT recovery USB stick: boots the factory recovery when the
    machine's own disk cannot (OPEN_QUESTIONS 29a/29c).

.DESCRIPTION
    ERASES THE WHOLE STICK. Only a USB disk is accepted, never the boot or
    system disk, and the operator must type "USB <disk number>"
    (AGENTS.md rule 7).

    Layout (owner decision 29c: two partitions):
      1. FAT32, 2 GB, label WOBOOT        UEFI boots only from FAT32: the
                                          WinPE media (Build-WinPE.ps1 output)
      2. NTFS, rest, label WO_RECOVERY    no 4 GB file limit: the images
           WO_RECOVERY.tag, WO_RECOVERY_USB.tag
           WO-Recovery.ps1
           Images\<COMPUTERNAME>\factory_C.wim, factory_D.wim, factory.json
             (copied by the wizard step "Copy the factory image off the
              machine"; one folder per machine)

    Windows 10 1703 and later (and its WinPE) mount both partitions of a
    removable stick. [Uncertain] that every machine's firmware offers the
    stick for UEFI boot: test with F12 on each model.

.PARAMETER DiskNumber
    The stick's disk number (Get-Disk).

.PARAMETER SourceFolder
    Build-WinPE.ps1 output (WOSetupRecovery).
#>
param(
    [Parameter(Mandatory)] [int]$DiskNumber,
    [Parameter(Mandatory)] [string]$SourceFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$recoveryScript = Join-Path $PSScriptRoot '..\..\recovery\partition\WO-Recovery.ps1'
$media = Join-Path $SourceFolder 'media'
if (-not (Test-Path (Join-Path $media 'sources\boot.wim'))) { throw "$media\sources\boot.wim not found: run Build-WinPE.ps1 first." }
if (-not (Test-Path $recoveryScript)) { throw "Missing $recoveryScript" }

$d = Get-Disk -Number $DiskNumber
if ("$($d.BusType)" -ne 'USB') { throw "Disk $DiskNumber is a $($d.BusType) disk, not USB. Refused." }
if ($d.IsBoot -or $d.IsSystem) { throw "Disk $DiskNumber is the boot/system disk. Refused." }
if ($d.Size -lt 16GB) { throw "Disk $DiskNumber is $([math]::Round($d.Size / 1GB)) GB; use a stick of at least 16 GB (64 GB or more to hold images)." }

Write-Host ''
Write-Host "  Disk $DiskNumber : $($d.FriendlyName), $([math]::Round($d.Size / 1GB)) GB, $($d.BusType)"
Write-Host '  EVERYTHING ON THIS STICK IS ERASED.'
$typed = Read-Host "  Type USB $DiskNumber to continue"
if ($typed -cne "USB $DiskNumber") { Write-Host '  Cancelled.'; exit 1 }

Write-Host "`n=== Partitions"
if ("$($d.PartitionStyle)" -ne 'RAW') { Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false }
Initialize-Disk -Number $DiskNumber -PartitionStyle MBR
$boot = New-Partition -DiskNumber $DiskNumber -Size 2GB -IsActive -AssignDriveLetter
Format-Volume -Partition $boot -FileSystem FAT32 -NewFileSystemLabel 'WOBOOT' -Confirm:$false | Out-Null
$data = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $data -FileSystem NTFS -NewFileSystemLabel 'WO_RECOVERY' -Confirm:$false | Out-Null
$b = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $boot.PartitionNumber).DriveLetter
$n = (Get-Partition -DiskNumber $DiskNumber -PartitionNumber $data.PartitionNumber).DriveLetter

Write-Host "`n=== WinPE -> ${b}:"
& robocopy.exe $media "${b}:\" /E /NFL /NDL /NJH /NP | Out-Host
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)." }

Write-Host "`n=== Recovery files -> ${n}:"
Set-Content -LiteralPath "${n}:\WO_RECOVERY.tag" -Value 'WATCHOUT factory recovery (USB)' -Encoding ASCII
Set-Content -LiteralPath "${n}:\WO_RECOVERY_USB.tag" -Value 'Recovery USB stick: images in Images\<computer>' -Encoding ASCII
Copy-Item $recoveryScript "${n}:\WO-Recovery.ps1"
New-Item -ItemType Directory -Path "${n}:\Images" | Out-Null

# Read back.
$ok = (Test-Path "${b}:\sources\boot.wim") -and (Test-Path "${b}:\EFI\Boot\bootx64.efi") -and
      (Test-Path "${n}:\WO-Recovery.ps1") -and (Test-Path "${n}:\WO_RECOVERY.tag")
if ($ok) { Write-Host "`n  [OK]   Recovery stick ready (${b}: WinPE, ${n}: images). Copy images with the wizard step 'Copy the factory image off the machine'." }
else { Write-Host "`n  [WARN] Some files are missing on the stick; check ${b}: and ${n}:." ; exit 2 }
