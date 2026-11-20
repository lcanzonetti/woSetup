#requires -RunAsAdministrator
<#
.SYNOPSIS
    Builds the WATCHOUT factory-recovery WinPE (boot.wim + boot files) on a
    technician PC with the Windows ADK. Run once per ADK version / driver set,
    not on the show machines.

.DESCRIPTION
    Output folder (default .\WOSetupRecovery) is what the setup wizard and
    New-RecoveryUsb.ps1 use. Put it on the USB stick NEXT TO
    WOSetupWizard.exe:

        WOSetupRecovery\
          media\                 copype's WinPE media (UEFI boot files)
            sources\boot.wim     WinPE with PowerShell, storage cmdlets,
                                 the RAID drivers and the recovery scripts
            Boot\boot.sdi
          manifest.json          ADK version, SHA-256s, winload path, drivers

    Steps (Microsoft's WinPE procedure; ADK + WinPE add-on must be
    installed, e.g. ADK 10.1.26100.2454 for Windows 11 24H2/25H2 plus its
    latest patch):
      1. copype amd64 <WorkFolder>
      2. mount media\sources\boot.wim
      3. add WinPE-WMI, -NetFX, -Scripting, -PowerShell, -StorageWMI,
         -DismCmdlets (+ en-us language cabs), in Microsoft's order
      4. add the drivers from -DriverFolder (AMD rcbottom -> rcraid -> rccfg
         first, in that order: Dell KB 000443715; [Uncertain] whether the order
         matters offline)
      5. startnet.cmd + X:\WORecovery\Start-WORecovery.ps1 + WO-Recovery.ps1
      6. scratch space 512 MB (PowerShell needs more than the default 32 MB)
      7. unmount /Commit, write manifest.json

    Secure Boot [Uncertain]: the Windows Production PCA 2011 certificate
    expired on 19 Oct 2026 (Microsoft KB5132953). Build with an ADK whose
    WinPE boots with Secure Boot on the target machines and TEST it there;
    the show machines' Secure Boot database is frozen at build time because
    Windows Update is disabled.

.PARAMETER DriverFolder
    Folder(s) with the RAID (and NIC, if wanted) drivers: .inf/.sys/.cat
    sets, searched recursively. Without the RAID driver WinPE cannot see C:
    on a RAID system array.

.PARAMETER OutputFolder
    Default: .\WOSetupRecovery (replaced if it exists).

.PARAMETER WorkFolder
    Temporary copype folder. Default: C:\WinPE_WO (must not exist).

.PARAMETER AdkRoot
    Default: %ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit
#>
param(
    [string[]]$DriverFolder = @(),
    [string]$OutputFolder = (Join-Path (Get-Location) 'WOSetupRecovery'),
    [string]$WorkFolder = "$env:SystemDrive\WinPE_WO",
    [string]$AdkRoot = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$startnet = Join-Path $repo 'recovery\winpe\startnet.cmd'
$bootstrap = Join-Path $repo 'recovery\winpe\Start-WORecovery.ps1'
$recovery = Join-Path $repo 'recovery\partition\WO-Recovery.ps1'
foreach ($f in $startnet, $bootstrap, $recovery) { if (-not (Test-Path $f)) { throw "Missing $f" } }

$dandi = Join-Path $AdkRoot 'Deployment Tools\DandISetEnv.bat'
$dism = Join-Path $AdkRoot 'Deployment Tools\amd64\DISM\dism.exe'
$ocs = Join-Path $AdkRoot 'Windows Preinstallation Environment\amd64\WinPE_OCs'
foreach ($f in $dandi, $dism, $ocs) { if (-not (Test-Path $f)) { throw "Windows ADK / WinPE add-on not found: $f" } }
if (Test-Path $WorkFolder) { throw "$WorkFolder exists. Delete it first (copype needs a new folder)." }

function Invoke-Dism([string[]]$Arguments) {
    Write-Host "dism $($Arguments -join ' ')"
    & $dism @Arguments
    if ($LASTEXITCODE -ne 0) { throw "DISM failed ($LASTEXITCODE): $($Arguments -join ' ')" }
}

Write-Host "`n=== copype amd64 $WorkFolder"
& cmd.exe /c "call `"$dandi`" && copype amd64 `"$WorkFolder`""
if ($LASTEXITCODE -ne 0) { throw "copype failed ($LASTEXITCODE)." }

$media = Join-Path $WorkFolder 'media'
$wim = Join-Path $media 'sources\boot.wim'
$mount = Join-Path $WorkFolder 'mount'
Invoke-Dism @('/Mount-Image', "/ImageFile:$wim", '/Index:1', "/MountDir:$mount")
$committed = $false
$drivers = New-Object System.Collections.Generic.List[string]
try {
    Write-Host "`n=== Optional components"
    $components = 'WinPE-WMI', 'WinPE-NetFX', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI', 'WinPE-DismCmdlets'
    foreach ($c in $components) {
        Invoke-Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$(Join-Path $ocs "$c.cab")")
        $lang = Join-Path $ocs "en-us\${c}_en-us.cab"
        if (Test-Path $lang) { Invoke-Dism @("/Image:$mount", '/Add-Package', "/PackagePath:$lang") }
    }

    Write-Host "`n=== Drivers"
    $infs = @()
    foreach ($d in $DriverFolder) { $infs += @(Get-ChildItem -Path $d -Filter *.inf -Recurse -File) }
    # AMD RAIDXpert2 order first (PROJECT_CONTEXT 2), everything else after.
    $order = @{ 'rcbottom.inf' = 0; 'rcraid.inf' = 1; 'rccfg.inf' = 2 }
    $sorted = $infs | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Name.ToLower())) { $order[$_.Name.ToLower()] } else { 9 } } }, FullName
    foreach ($i in $sorted) {
        Invoke-Dism @("/Image:$mount", '/Add-Driver', "/Driver:$($i.FullName)")
        $drivers.Add($i.Name)
    }
    if ($drivers.Count -eq 0) { Write-Host '  [WARN] No driver added: WinPE will not see a RAID system array.' }

    Write-Host "`n=== Recovery scripts"
    Copy-Item $startnet (Join-Path $mount 'Windows\System32\startnet.cmd') -Force
    $wr = Join-Path $mount 'WORecovery'
    New-Item -ItemType Directory -Path $wr -Force | Out-Null
    Copy-Item $bootstrap, $recovery $wr -Force

    # The RAM-disk boot entry needs winload.efi's path inside boot.wim.
    $winload = $null
    foreach ($candidate in '\Windows\System32\boot\winload.efi', '\Windows\System32\winload.efi') {
        if (Test-Path (Join-Path $mount $candidate.TrimStart('\'))) { $winload = $candidate.ToLower(); break }
    }
    if (-not $winload) { throw 'winload.efi not found in boot.wim.' }
    Write-Host "  winload: $winload"

    Invoke-Dism @("/Image:$mount", '/Set-ScratchSpace:512')
    Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit')
    $committed = $true
}
finally {
    if (-not $committed) { & $dism /Unmount-Image "/MountDir:$mount" /Discard | Out-Host }
}

Write-Host "`n=== Output $OutputFolder"
if (Test-Path $OutputFolder) { Remove-Item -Recurse -Force $OutputFolder }
New-Item -ItemType Directory -Path $OutputFolder | Out-Null
Copy-Item $media (Join-Path $OutputFolder 'media') -Recurse
$outWim = Join-Path $OutputFolder 'media\sources\boot.wim'
$outSdi = Join-Path $OutputFolder 'media\Boot\boot.sdi'
$manifest = [ordered]@{
    SchemaVersion = 1
    BuiltAt       = (Get-Date).ToString('o')
    BuiltOn       = $env:COMPUTERNAME
    AdkVersion    = (Get-Item $dism).VersionInfo.ProductVersion
    BootWim       = 'media\sources\boot.wim'
    BootWimSha256 = (Get-FileHash $outWim -Algorithm SHA256).Hash
    BootSdi       = 'media\Boot\boot.sdi'
    BootSdiSha256 = (Get-FileHash $outSdi -Algorithm SHA256).Hash
    WinloadPath   = $winload
    Components    = $components
    Drivers       = @($drivers)
}
[IO.File]::WriteAllText((Join-Path $OutputFolder 'manifest.json'), (ConvertTo-Json -InputObject $manifest -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -Recurse -Force $WorkFolder
Write-Host "`nDone. Copy $OutputFolder next to WOSetupWizard.exe on the USB stick."
