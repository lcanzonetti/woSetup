#requires -RunAsAdministrator
<#
.SYNOPSIS
    Read-only checks for the setup wizard: is a checklist step already done?

.DESCRIPTION
    Each check reads the machine and returns one result:
      Done           the step's goal is in place
      NotDone        it is not (Detail says what is missing)
      NotApplicable  the step does not apply here (e.g. no AMD RAID)
      CantCheck      it cannot be told from Windows (Detail says why)
    Nothing here changes the machine. Every check is wrapped in try/catch:
    an error becomes CantCheck with the message, never a false "Done"
    (AGENTS.md rule 2, "never pretend").

    The script settings themselves (policies, registry, services...) are
    checked by the setup scripts' own -Audit mode, not here.

.PARAMETER Ids
    Check ids to run, comma-separated (see $Checks below). One string, not
    an array: powershell.exe -File passes "a,b" as a single argument.

.PARAMETER ParamsJson
    JSON with the wizard context: Profile (WO7/WO6), Role, Options (the
    script options: DefenderMode, KeepUpdateService, WorkingDirectory,
    WatchoutPath, ShowsPath).

.PARAMETER ResultPath
    JSON array of { Id, State, Detail } written here (UTF-8, no BOM).
#>
param(
    [Parameter(Mandatory)] [string]$Ids,
    [Parameter(Mandatory)] [string]$ParamsJson,
    [Parameter(Mandatory)] [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$ctx = Get-Content -Raw -LiteralPath $ParamsJson -Encoding UTF8 | ConvertFrom-Json

function Get-Opt([string]$Name) {
    # Option value from the context, $null when absent (StrictMode-safe).
    if ($ctx.PSObject.Properties['Options'] -and $ctx.Options.PSObject.Properties[$Name]) { return $ctx.Options.$Name }
    return $null
}

function R([string]$State, [string]$Detail) { [pscustomobject]@{ State = $State; Detail = $Detail } }

function Get-RegValue([string]$Path, [string]$Name) {
    $p = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties[$Name]) { return $p.$Name }
    return $null
}

function Test-RegEquals([string]$Path, [string]$Name, $Expected, [string]$Label) {
    $v = Get-RegValue $Path $Name
    if ($null -eq $v) { return R 'NotDone' "$Label is not set ($Path\$Name missing)." }
    if ("$v" -eq "$Expected") { return R 'Done' "$Label = $v." }
    return R 'NotDone' "$Label = $v (expected $Expected)."
}

function Get-Uninstall {
    # Installed programs (64- and 32-bit views), as the scripts look them up.
    Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName }
}

function Get-ServiceStart([string]$Name) {
    $s = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if ($s) { return $s.StartMode }
    return $null
}

function Get-PhysicalNics { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' }) }

function Get-DriverInfs {
    # Original .inf names of the driver packages in the driver store. File
    # names are not localised, so this works on any Windows language.
    $out = & pnputil.exe /enum-drivers 2>$null
    @($out | Where-Object { $_ -match '\.inf\s*$' } | ForEach-Object { ($_ -split ':')[-1].Trim().ToLowerInvariant() })
}

function Test-AmdRaid {
    # Three AMD RAID packages present? Returns a result, or $null when the
    # machine shows no sign of AMD RAID at all.
    $infs = Get-DriverInfs
    $want = 'rcbottom', 'rcraid', 'rccfg'
    $found = @($want | Where-Object { $n = $_; @($infs | Where-Object { $_ -like "$n*.inf" }).Count -gt 0 })
    $amdDevice = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'AMD.*RAID|RAID.*AMD' })
    if ($found.Count -eq 0 -and $amdDevice.Count -eq 0) { return $null }
    if ($found.Count -eq 3) { return R 'Done' 'rcbottom, rcraid and rccfg are in the driver store.' }
    $missing = @($want | Where-Object { $found -notcontains $_ })
    return R 'NotDone' "Missing from the driver store: $($missing -join ', ') (found: $(if ($found) { $found -join ', ' } else { 'none' }))."
}

function Get-WatchoutPathFor6 {
    # Same lookup as WO6-Setup.ps1: option, Uninstall entry, default folders.
    $isWo = { param($p) [bool]$p -and ([IO.File]::Exists([IO.Path]::Combine($p, 'WATCHPOINT.exe')) -or
                                      [IO.File]::Exists([IO.Path]::Combine($p, 'WATCHMAKER.exe'))) }
    $c = @()
    $opt = Get-Opt 'WatchoutPath'
    if ($opt) { $c += "$opt".TrimEnd('\') }
    $c += @(Get-Uninstall | Where-Object { $_.DisplayName -match 'WATCHOUT' -and $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation } |
            ForEach-Object { $_.InstallLocation.TrimEnd('\') })
    $c += 'C:\WATCHOUT 6', 'D:\WATCHOUT 6', 'D:\WATCHOUT'
    foreach ($x in $c) { if (& $isWo $x) { return $x } }
    return $null
}

function Get-ConsoleUser {
    $u = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($u) { return "$u" }
    return $null
}

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WoLogon {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    // Tries an interactive logon with an EMPTY password. Returns 0 on
    // success, otherwise the Win32 error: 1327 (account restriction) is what
    // a blank password gets under "Limit local account use of blank
    // passwords to console logon only"; 1326 means the password is not blank.
    public static int TryBlank(string user) {
        IntPtr t;
        if (LogonUser(user, ".", "", 2, 0, out t)) { CloseHandle(t); return 0; }
        return Marshal.GetLastWin32Error();
    }
}
'@

$Checks = [ordered]@{

    'preflight' = {
        $problems = @()
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $problems += 'not elevated' }
        if ($PSVersionTable.PSVersion.Major -ne 5) { $problems += "PowerShell $($PSVersionTable.PSVersion) (expected 5.1)" }
        foreach ($scope in 'MachinePolicy', 'UserPolicy') {
            $p = Get-ExecutionPolicy -Scope $scope
            if ("$p" -ne 'Undefined') { $problems += "execution policy forced by Group Policy ($scope = $p)" }
        }
        $os = Get-CimInstance Win32_OperatingSystem
        $ver = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
        $osText = "$($os.Caption) $ver (build $($os.BuildNumber))"
        if ($os.Caption -notmatch 'Windows 11') { $problems += "not Windows 11: $osText" }
        if ($problems) { return R 'NotDone' ($problems -join '; ') }
        R 'Done' "Elevated, Windows PowerShell $($PSVersionTable.PSVersion), no forced execution policy, $osText."
    }

    'machine-info' = {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os = Get-CimInstance Win32_OperatingSystem
        R 'Done' "$($cs.Manufacturer) $($cs.Model); BIOS $($bios.SMBIOSBIOSVersion) ($(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'no date' })); $($os.Caption) build $($os.BuildNumber)."
    }

    'show-account' = {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $console = Get-ConsoleUser
        if (-not $console) { return R 'CantCheck' 'Nobody is signed in at the console.' }
        if ($console -ne $me) { return R 'NotDone' "The wizard runs as $me but $console is signed in: per-user settings would go to the wrong account. Start the wizard from the show account." }
        $local = Get-LocalUser -Name ($me -split '\\')[-1] -ErrorAction SilentlyContinue
        if ($local -and "$($local.PrincipalSource)" -ne 'Local') { return R 'NotDone' "$me is a $($local.PrincipalSource) account, not a local account." }
        R 'Done' "Running as the signed-in local account $me."
    }

    'nic-driver' = {
        $nics = Get-PhysicalNics
        if ($nics.Count -eq 0) { return R 'NotDone' 'No physical network adapter with a driver.' }
        $bad = @(Get-PnpDevice -Class Net -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        if ($bad) { return R 'NotDone' "Driver problem: $(($bad | ForEach-Object { $_.FriendlyName }) -join ', ')." }
        R 'Done' "$(($nics | ForEach-Object { "$($_.Name) ($($_.InterfaceDescription))" }) -join '; ')."
    }

    'nic-link-up' = {
        $up = @(Get-PhysicalNics | Where-Object { $_.Status -eq 'Up' })
        if ($up) { return R 'Done' "Link up: $(($up | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ')." }
        R 'NotDone' 'No physical adapter has link.'
    }

    'updates' = {
        $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                   (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $text = if ($last) { "Last update: $($last.HotFixID) on $($last.InstalledOn.ToString('yyyy-MM-dd'))." } else { 'No installed update found.' }
        if ($pending) { $text += ' A restart is pending.' }
        R 'CantCheck' "$text Whether more updates are available can only be seen in Windows Update."
    }

    'amd-raid-drivers' = {
        $r = Test-AmdRaid
        if ($null -eq $r) { return R 'NotApplicable' 'No AMD RAID on this machine.' }
        $r
    }

    'raid-drivers' = {
        $amd = Test-AmdRaid
        $mega = @(Get-DriverInfs | Where-Object { $_ -like 'megasas*.inf' })
        if ($mega) { return R 'Done' "Broadcom MegaRAID driver present ($($mega -join ', '))." }
        if ($null -ne $amd) { return $amd }
        R 'NotApplicable' 'No AMD RAID or Broadcom MegaRAID on this machine.'
    }

    'raidxpert2' = {
        if ($null -eq (Test-AmdRaid)) { return R 'NotApplicable' 'No AMD RAID on this machine.' }
        $p = @(Get-Uninstall | Where-Object { $_.DisplayName -match 'RAIDXpert' })
        if ($p) { return R 'Done' "$($p[0].DisplayName) $(if ($p[0].PSObject.Properties['DisplayVersion']) { $p[0].DisplayVersion })." }
        R 'NotDone' 'RAIDXpert2 is not installed.'
    }

    'raid-mgmt-app' = {
        $amd = Test-AmdRaid
        $mega = @(Get-DriverInfs | Where-Object { $_ -like 'megasas*.inf' })
        if ($null -eq $amd -and -not $mega) { return R 'NotApplicable' 'No RAID controller on this machine.' }
        # [Uncertain] product names of the Broadcom tools.
        $p = @(Get-Uninstall | Where-Object { $_.DisplayName -match 'RAIDXpert|MegaRAID|Storage Authority|StorCLI' })
        if ($p) { return R 'Done' "$(($p | ForEach-Object { $_.DisplayName }) -join ', ')." }
        R 'NotDone' 'No RAID management app found in the installed programs.'
    }

    'nvidia-driver' = {
        $gpus = @(Get-CimInstance Win32_VideoController)
        $nv = @($gpus | Where-Object { $_.Name -match 'NVIDIA' })
        if (-not $nv) {
            $basic = @($gpus | Where-Object { $_.Name -match 'Basic Display' })
            if ($basic) { return R 'NotDone' 'Only the Microsoft Basic Display Adapter: no GPU driver installed.' }
            return R 'NotApplicable' "No NVIDIA GPU ($(($gpus | ForEach-Object { $_.Name }) -join ', '))."
        }
        # 32.0.15.6094 -> 560.94: the NVIDIA version is the last five digits.
        $digits = ($nv[0].DriverVersion -replace '\.', '')
        $nvVer = if ($digits.Length -ge 5) { $d = $digits.Substring($digits.Length - 5); "$($d.Substring(0,3)).$($d.Substring(3))" } else { $nv[0].DriverVersion }
        R 'Done' "$($nv[0].Name), driver $nvVer ($($nv[0].DriverVersion)). Compare with the version tested for your WATCHOUT release."
    }

    'bitlocker-off' = {
        $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter -eq $env:SystemDrive }
        if (-not $v) { return R 'NotApplicable' 'BitLocker is not available on this Windows.' }
        $s = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
        $prot = (Invoke-CimMethod -InputObject $v -MethodName GetProtectionStatus).ProtectionStatus
        # ConversionStatus 0 = fully decrypted, 3 = decryption in progress.
        if ($s.ConversionStatus -eq 0 -and $prot -eq 0) { return R 'Done' "$env:SystemDrive fully decrypted, protection off." }
        if ($s.ConversionStatus -eq 3) { return R 'NotDone' "$env:SystemDrive is decrypting: $([math]::Round(100 - $s.EncryptionPercentage)) % done. Check again later." }
        R 'NotDone' "$env:SystemDrive is encrypted ($($s.EncryptionPercentage) %), protection $(if ($prot -eq 1) { 'on' } else { 'off' })."
    }

    'media-volume' = {
        $disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and "$($_.BusType)" -notin @('USB', 'SD', 'MMC') })
        if (-not $disks) { return R 'NotApplicable' 'No second internal disk.' }
        $raw = @($disks | Where-Object { "$($_.PartitionStyle)" -eq 'RAW' })
        $ntfs = @($disks | Where-Object { "$($_.PartitionStyle)" -eq 'GPT' } | ForEach-Object {
            $d = $_
            Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue |
                Where-Object { $_.FileSystem -eq 'NTFS' } |
                ForEach-Object { "disk $($d.Number): $($_.DriveLetter): $($_.FileSystemLabel) $([math]::Round($_.Size / 1GB)) GB, $($_.AllocationUnitSize / 1KB) KB clusters" }
        })
        if ($raw) { return R 'NotDone' "Not initialised: $(($raw | ForEach-Object { "disk $($_.Number) ($($_.FriendlyName), $([math]::Round($_.Size / 1GB)) GB)" }) -join ', ')." }
        if ($ntfs) { return R 'Done' ($ntfs -join '; ') }
        R 'NotDone' 'The second disk has no GPT/NTFS volume.'
    }

    'media-indexing-off' = {
        $vols = @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $env:SystemDrive })
        if (-not $vols) { return R 'NotApplicable' 'No fixed drive besides the system drive.' }
        $on = @($vols | Where-Object { $_.IndexingEnabled })
        if ($on) { return R 'NotDone' "Indexing on: $(($on | ForEach-Object { $_.DriveLetter }) -join ', ')." }
        R 'Done' "Indexing off on $(($vols | ForEach-Object { $_.DriveLetter }) -join ', ')."
    }

    'disks-healthy' = {
        $bad = @(Get-Disk | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' -or "$($_.OperationalStatus)" -ne 'Online' })
        if ($bad) { return R 'NotDone' "$(($bad | ForEach-Object { "disk $($_.Number) $($_.FriendlyName): $($_.HealthStatus), $($_.OperationalStatus)" }) -join '; ')." }
        R 'Done' 'Every disk online and healthy as seen by Windows (check RAIDXpert2 / the RAID app for the array itself).'
    }

    'watchout-installed' = {
        if ("$($ctx.Profile)" -eq 'WO6') {
            $p = Get-WatchoutPathFor6
            if ($p) { return R 'Done' "WATCHOUT 6 in $p." }
            return R 'NotDone' 'WATCHPOINT.exe / WATCHMAKER.exe not found (set -WatchoutPath in Options if it is elsewhere).'
        }
        # [Uncertain] product name/version of the WATCHOUT 7 installer entry.
        $e = @(Get-Uninstall | Where-Object { $_.DisplayName -match 'WATCHOUT' -and (
                $_.DisplayName -match '\b7' -or ($_.PSObject.Properties['DisplayVersion'] -and "$($_.DisplayVersion)" -match '^7\.')) })
        if ($e) { return R 'Done' "$($e[0].DisplayName) $(if ($e[0].PSObject.Properties['DisplayVersion']) { $e[0].DisplayVersion })." }
        $any = @(Get-Uninstall | Where-Object { $_.DisplayName -match 'WATCHOUT' })
        if ($any) { return R 'CantCheck' "Found $(($any | ForEach-Object { $_.DisplayName }) -join ', ') but cannot tell if it is WATCHOUT 7." }
        R 'NotDone' 'No WATCHOUT entry in the installed programs.'
    }

    'wo7-workdir' = {
        $w = Get-Opt 'WorkingDirectory'
        if (-not $w) { return R 'CantCheck' 'Working directory not set in Options (-WorkingDirectory): the wizard cannot see the WATCHOUT setting.' }
        if (Test-Path -LiteralPath $w) { return R 'Done' "$w exists." }
        R 'NotDone' "$w does not exist."
    }

    'auto-logon' = {
        $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if ("$(Get-RegValue $wl 'AutoAdminLogon')" -eq '1') { return R 'Done' "Auto-logon set for $(Get-RegValue $wl 'DefaultUserName')." }
        $user = [Environment]::UserName
        $code = [WoLogon]::TryBlank($user)
        # [Uncertain] interpretation of the logon result, see WoLogon above.
        if ($code -eq 0 -or $code -eq 1327) { return R 'Done' "$user has no password: Windows signs in by itself." }
        if ($code -eq 1326) { return R 'NotDone' "$user has a password and auto-logon is not set." }
        R 'CantCheck' "Could not tell (logon test returned error $code)."
    }

    'static-ip' = {
        $up = @(Get-PhysicalNics | Where-Object { $_.Status -eq 'Up' })
        if (-not $up) { return R 'CantCheck' 'No connected physical adapter.' }
        $dhcp = @(); $ok = @()
        foreach ($n in $up) {
            $if = Get-NetIPInterface -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $ip = @(Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
            if ($if -and "$($if.Dhcp)" -eq 'Disabled' -and $ip) { $ok += "$($n.Name) $($ip -join ',')" } else { $dhcp += "$($n.Name) (DHCP $($ip -join ','))" }
        }
        if ($dhcp) { return R 'NotDone' "Not static: $($dhcp -join '; ')." }
        R 'Done' ($ok -join '; ')
    }

    'ipv4-only-bindings' = {
        $extra = 'ms_tcpip6', 'ms_pacer', 'ms_lltdio', 'ms_rspndr', 'ms_lldp', 'ms_implat'
        $found = @()
        foreach ($n in Get-PhysicalNics) {
            $on = @(Get-NetAdapterBinding -Name $n.Name -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $extra -contains $_.ComponentID } | ForEach-Object { $_.DisplayName })
            if ($on) { $found += "$($n.Name): $($on -join ', ')" }
        }
        if ($found) { return R 'NotDone' "Still bound: $($found -join '; ')." }
        R 'Done' 'Only IPv4 (and file sharing, if kept) bound on the physical adapters.'
    }

    'wol-magic-packet' = {
        $props = @(foreach ($n in Get-PhysicalNics) {
            Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Wake on Magic Packet' } })
        if (-not $props) { return R 'NotApplicable' 'No adapter exposes "Wake on Magic Packet".' }
        $off = @($props | Where-Object { $_.DisplayValue -notmatch '^(Enabled|On)$' })
        if ($off) { return R 'NotDone' "$(($off | ForEach-Object { "$($_.Name): $($_.DisplayValue)" }) -join '; ')." }
        R 'Done' "Enabled on $(($props | ForEach-Object { $_.Name }) -join ', ') (Wake-on-LAN in the BIOS is not visible from Windows)."
    }

    'tamper-off' = {
        if ("$(Get-Opt 'DefenderMode')" -ne 'Off') { return R 'NotApplicable' "Not needed with -DefenderMode $(Get-Opt 'DefenderMode')." }
        $s = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not $s) { return R 'NotApplicable' 'Microsoft Defender is not running.' }
        if ($s.IsTamperProtected) { return R 'NotDone' 'Tamper Protection is on.' }
        R 'Done' 'Tamper Protection is off.'
    }

    'defender-off' = {
        $mode = "$(Get-Opt 'DefenderMode')"
        if ($mode -eq 'Skip') { return R 'NotApplicable' 'Defender is not touched (-DefenderMode Skip).' }
        $s = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not $s) { return R 'Done' 'Microsoft Defender is not running.' }
        if ($mode -eq 'Exclusions') {
            $ex = @((Get-MpPreference).ExclusionPath)
            if ($ex) { return R 'Done' "Defender on, exclusions: $($ex -join ', ')." }
            return R 'NotDone' 'Defender on and no exclusions set.'
        }
        $on = @('RealTimeProtectionEnabled', 'BehaviorMonitorEnabled', 'OnAccessProtectionEnabled' | Where-Object { $s.$_ })
        if ($s.IsTamperProtected) { $on += 'IsTamperProtected' }
        if ($on) { return R 'NotDone' "Still on: $($on -join ', ')." }
        R 'Done' 'Real-time, behaviour and on-access protection off; Tamper Protection off.'
    }

    'power-plan' = {
        $guid = if ("$($ctx.Profile)" -eq 'WO6') { '6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e56' } else { '6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e57' }
        $active = (& powercfg.exe /getactivescheme) -join ' '
        if ($active -match $guid) { return R 'Done' $active.Trim() }
        R 'NotDone' "Active: $($active.Trim())"
    }

    'update-services-disabled' = {
        if ((Get-Opt 'KeepUpdateService') -eq $true) { return R 'NotApplicable' 'Update services are kept (-KeepUpdateService).' }
        $not = @('BITS', 'wuauserv', 'UsoSvc' | Where-Object { $m = Get-ServiceStart $_; $m -and $m -ne 'Disabled' } | ForEach-Object { "$_ ($(Get-ServiceStart $_))" })
        if ($not) { return R 'NotDone' "Not disabled: $($not -join ', ')." }
        R 'Done' 'BITS, wuauserv and UsoSvc disabled.'
    }

    'reg-tdr' = {
        $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $a = Test-RegEquals $gd 'TdrDelay' 15 'TdrDelay'
        $b = Test-RegEquals $gd 'TdrDdiDelay' 60 'TdrDdiDelay'
        if ($a.State -eq 'Done' -and $b.State -eq 'Done') { return R 'Done' "$($a.Detail) $($b.Detail)" }
        R 'NotDone' "$($a.Detail) $($b.Detail)"
    }

    'reg-sysresp' = { Test-RegEquals 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10 'SystemResponsiveness' }

    'reg-priosep' = { Test-RegEquals 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 40 'Win32PrioritySeparation' }

    'visual-effects' = { Test-RegEquals 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 'VisualFXSetting ("Adjust for best performance")' }

    'usb-notify-off' = { Test-RegEquals 'HKCU:\Software\Microsoft\Shell\USB' 'NotifyOnUsbErrors' 0 'NotifyOnUsbErrors' }

    'wsearch-disabled' = {
        $m = Get-ServiceStart 'WSearch'
        if (-not $m) { return R 'Done' 'Windows Search service not present.' }
        if ($m -eq 'Disabled') { return R 'Done' 'WSearch disabled.' }
        R 'NotDone' "WSearch is $m."
    }

    'codemeter-running' = {
        # [Uncertain] service name of the CodeMeter runtime.
        $s = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'CodeMeter' -or $_.DisplayName -match 'CodeMeter' })
        if (-not $s) { return R 'NotDone' 'No CodeMeter service found (runtime not installed?).' }
        $run = @($s | Where-Object { "$($_.Status)" -eq 'Running' })
        if ($run) { return R 'Done' "$($run[0].DisplayName) running. Check the licence itself in CodeMeter Control Center." }
        R 'NotDone' "$($s[0].DisplayName) is $($s[0].Status)."
    }

    'no-watchpoint-shortcut' = {
        $found = @()
        $shell = New-Object -ComObject WScript.Shell
        foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") {
            Get-ChildItem $dir -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
                if ($shell.CreateShortcut($_.FullName).TargetPath -match 'WATCHPOINT') { $found += $_.FullName }
            }
        }
        if ($found) { return R 'NotDone' "Startup shortcut(s) also start WATCHPOINT: $($found -join '; ')." }
        R 'Done' 'No Startup-folder shortcut to WATCHPOINT.'
    }

    'vendor-services' = {
        $s = @(Get-CimInstance Win32_Service | Where-Object { $_.DisplayName -match 'Content Protection HDCP|HECI|NvTelemetry|NVIDIA Telemetry' -or $_.Name -match 'NvTelemetry' })
        if (-not $s) { return R 'NotApplicable' 'None of these vendor services is installed.' }
        $on = @($s | Where-Object { $_.StartMode -ne 'Disabled' })
        if ($on) { return R 'NotDone' "$(($on | ForEach-Object { "$($_.DisplayName): $($_.StartMode)" }) -join '; ')." }
        R 'Done' "Disabled: $(($s | ForEach-Object { $_.DisplayName }) -join ', ')."
    }

    'watchpoint-task' = {
        $t = Get-ScheduledTask -TaskPath '\WATCHOUT\' -TaskName 'WATCHPOINT auto-start' -ErrorAction SilentlyContinue
        if (-not $t) { return R 'NotDone' 'Task \WATCHOUT\WATCHPOINT auto-start not found.' }
        $info = Get-ScheduledTaskInfo -InputObject $t
        $limit = "$($t.Settings.ExecutionTimeLimit)"
        $problems = @()
        if ($limit -ne 'PT0S') { $problems += "time limit $limit" }
        if ($info.LastTaskResult -ne 267009) { $problems += ('last result 0x{0:X} (0x41301 = running)' -f $info.LastTaskResult) }
        if ($problems) { return R 'NotDone' ($problems -join '; ') }
        R 'Done' 'Running, no time limit.'
    }
}

$Id = @($Ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$results = foreach ($i in $Id) {
    if (-not $Checks.Contains($i)) {
        [pscustomobject]@{ Id = $i; State = 'CantCheck'; Detail = "Unknown check '$i' in this build." }
        continue
    }
    try {
        $r = & $Checks[$i]
        [pscustomobject]@{ Id = $i; State = $r.State; Detail = $r.Detail }
    }
    catch {
        # An error is never a pass.
        [pscustomobject]@{ Id = $i; State = 'CantCheck'; Detail = "The check failed: $($_.Exception.Message)" }
    }
    Write-Host "  [check] $i"
}

$json = ConvertTo-Json -InputObject @($results) -Depth 4
[IO.File]::WriteAllText($ResultPath, $json, (New-Object System.Text.UTF8Encoding($false)))
