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

# Not named "R": PowerShell resolves aliases before functions, and r is the
# built-in alias of Invoke-History.
function New-Check([string]$State, [string]$Detail) { [pscustomobject]@{ State = $State; Detail = $Detail } }

function Get-RegValue([string]$Path, [string]$Name) {
    $p = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($p -and $p.PSObject.Properties[$Name]) { return $p.$Name }
    return $null
}

function Test-RegEquals([string]$Path, [string]$Name, $Expected, [string]$Label) {
    $v = Get-RegValue $Path $Name
    if ($null -eq $v) { return New-Check 'NotDone' "$Label is not set ($Path\$Name missing)." }
    if ("$v" -eq "$Expected") { return New-Check 'Done' "$Label = $v." }
    return New-Check 'NotDone' "$Label = $v (expected $Expected)."
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
        if ($problems) { return New-Check 'NotDone' ($problems -join '; ') }
        New-Check 'Done' "Elevated, Windows PowerShell $($PSVersionTable.PSVersion), no forced execution policy, $osText."
    }

    'machine-info' = {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        $os = Get-CimInstance Win32_OperatingSystem
        New-Check 'Done' "$($cs.Manufacturer) $($cs.Model); BIOS $($bios.SMBIOSBIOSVersion) ($(if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'no date' })); $($os.Caption) build $($os.BuildNumber)."
    }

    'show-account' = {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $console = Get-ConsoleUser
        if (-not $console) { return New-Check 'CantCheck' 'Nobody is signed in at the console.' }
        if ($console -ne $me) { return New-Check 'NotDone' "The wizard runs as $me but $console is signed in: per-user settings would go to the wrong account. Start the wizard from the show account." }
        $local = Get-LocalUser -Name ($me -split '\\')[-1] -ErrorAction SilentlyContinue
        if ($local -and "$($local.PrincipalSource)" -ne 'Local') { return New-Check 'NotDone' "$me is a $($local.PrincipalSource) account, not a local account." }
        New-Check 'Done' "Running as the signed-in local account $me."
    }

    'nic-driver' = {
        $nics = Get-PhysicalNics
        if ($nics.Count -eq 0) { return New-Check 'NotDone' 'No physical network adapter with a driver.' }
        $bad = @(Get-PnpDevice -Class Net -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'OK' })
        if ($bad) { return New-Check 'NotDone' "Driver problem: $(($bad | ForEach-Object { $_.FriendlyName }) -join ', ')." }
        New-Check 'Done' "$(($nics | ForEach-Object { "$($_.Name) ($($_.InterfaceDescription))" }) -join '; ')."
    }

    'nic-link-up' = {
        $up = @(Get-PhysicalNics | Where-Object { $_.Status -eq 'Up' })
        if ($up) { return New-Check 'Done' "Link up: $(($up | ForEach-Object { "$($_.Name) $($_.LinkSpeed)" }) -join ', ')." }
        New-Check 'NotDone' 'No physical adapter has link.'
    }

    'updates' = {
        $last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                   (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        $text = if ($last) { "Last update: $($last.HotFixID) on $($last.InstalledOn.ToString('yyyy-MM-dd'))." } else { 'No installed update found.' }
        if ($pending) { $text += ' A restart is pending.' }
        New-Check 'CantCheck' "$text Whether more updates are available can only be seen in Windows Update."
    }

    'raid-driver' = {
        # Any RAID controller Windows sees: PCI class 01/04 ("RAID bus
        # controller", also reported by devices with no driver yet) or a
        # storage controller whose name says RAID. Vendor-neutral (AMD
        # RAIDXpert2, Broadcom MegaRAID, ...). [Uncertain] on real RAID hardware.
        $devs = @(Get-CimInstance Win32_PnPEntity | Where-Object {
                $ids = @($_.CompatibleID) + @($_.HardwareID)
                (@($ids | Where-Object { "$_" -match 'CC_0104' }).Count -gt 0) -or
                ("$($_.PNPClass)" -in @('SCSIAdapter', 'HDC') -and "$($_.Name)" -match 'RAID') })
        if (-not $devs) { return New-Check 'NotApplicable' 'Windows sees no RAID controller. If this machine uses RAID, look in Device Manager > Storage controllers.' }
        $bad = @($devs | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
        if ($bad) {
            return New-Check 'NotDone' "Install the RAID driver: $(($bad | ForEach-Object { "$(if ($_.Name) { $_.Name } else { $_.DeviceID }) (device error $($_.ConfigManagerErrorCode))" }) -join '; ')."
        }
        $drv = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -in @($devs | ForEach-Object { $_.DeviceID }) })
        $text = @($devs | ForEach-Object {
                $id = $_.DeviceID
                $dv = $drv | Where-Object { $_.DeviceID -eq $id } | Select-Object -First 1
                if ($dv) { "$($_.Name): $($dv.DriverProviderName) $($dv.DriverVersion)" } else { "$($_.Name)" } })
        $inbox = @($drv | Where-Object { "$($_.DriverProviderName)" -match '^Microsoft' })
        if ($inbox) { return New-Check 'NotDone' "Running on Windows' own driver: $($text -join '; '). Install the RAID vendor's driver package." }
        New-Check 'Done' "$($text -join '; ')."
    }

    'nvidia-driver' = {
        $gpus = @(Get-CimInstance Win32_VideoController)
        $nv = @($gpus | Where-Object { $_.Name -match 'NVIDIA' })
        if (-not $nv) {
            $basic = @($gpus | Where-Object { $_.Name -match 'Basic Display' })
            if ($basic) { return New-Check 'NotDone' 'Only the Microsoft Basic Display Adapter: no GPU driver installed.' }
            return New-Check 'NotApplicable' "No NVIDIA GPU ($(($gpus | ForEach-Object { $_.Name }) -join ', '))."
        }
        # 32.0.15.6094 -> 560.94: the NVIDIA version is the last five digits.
        $digits = ($nv[0].DriverVersion -replace '\.', '')
        $nvVer = if ($digits.Length -ge 5) { $d = $digits.Substring($digits.Length - 5); "$($d.Substring(0,3)).$($d.Substring(3))" } else { $nv[0].DriverVersion }
        New-Check 'Done' "$($nv[0].Name), driver $nvVer ($($nv[0].DriverVersion)). Compare with the version tested for your WATCHOUT release."
    }

    'bitlocker-off' = {
        $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter -eq $env:SystemDrive }
        if (-not $v) { return New-Check 'NotApplicable' 'BitLocker is not available on this Windows.' }
        $s = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
        $prot = (Invoke-CimMethod -InputObject $v -MethodName GetProtectionStatus).ProtectionStatus
        # ConversionStatus 0 = fully decrypted, 3 = decryption in progress.
        if ($s.ConversionStatus -eq 0 -and $prot -eq 0) { return New-Check 'Done' "$env:SystemDrive fully decrypted, protection off." }
        if ($s.ConversionStatus -eq 3) { return New-Check 'NotDone' "$env:SystemDrive is decrypting: $([math]::Round(100 - $s.EncryptionPercentage)) % done. Check again later." }
        New-Check 'NotDone' "$env:SystemDrive is encrypted ($($s.EncryptionPercentage) %), protection $(if ($prot -eq 1) { 'on' } else { 'off' })."
    }

    'media-volume' = {
        # Done when any internal non-system disk has an NTFS volume on GPT. Other
        # empty (RAW) disks do not make it "not done": they are listed as a note.
        $disks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and "$($_.BusType)" -notin @('USB', 'SD', 'MMC') })
        if (-not $disks) { return New-Check 'NotApplicable' 'No second internal disk.' }
        $ok = @(); $other = @()
        foreach ($d in $disks) {
            $name = "disk $($d.Number) ($($d.FriendlyName), $([math]::Round($d.Size / 1GB)) GB)"
            $vols = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.FileSystem })
            $ntfs = @($vols | Where-Object { $_.FileSystem -eq 'NTFS' })
            if ("$($d.PartitionStyle)" -eq 'GPT' -and $ntfs) {
                $ok += @($ntfs | ForEach-Object { "$name $($_.DriveLetter): '$($_.FileSystemLabel)' NTFS, $($_.AllocationUnitSize / 1KB) KB clusters" })
            }
            elseif ("$($d.PartitionStyle)" -eq 'RAW') { $other += "$name not initialised" }
            elseif ($ntfs) { $other += "$name NTFS but $($d.PartitionStyle), not GPT" }
            elseif ($vols) { $other += "$name $($d.PartitionStyle), $(($vols | ForEach-Object { $_.FileSystem }) -join '/') (not NTFS)" }
            else { $other += "$name $($d.PartitionStyle), no formatted volume" }
        }
        if ($ok) {
            $note = if ($other) { " Also: $($other -join '; ')." } else { '' }
            return New-Check 'Done' "$($ok -join '; ').$note"
        }
        New-Check 'NotDone' "No GPT/NTFS media volume: $($other -join '; ')."
    }

    'media-indexing-off' = {
        $vols = @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $env:SystemDrive })
        if (-not $vols) { return New-Check 'NotApplicable' 'No fixed drive besides the system drive.' }
        $on = @($vols | Where-Object { $_.IndexingEnabled })
        if ($on) { return New-Check 'NotDone' "Indexing on: $(($on | ForEach-Object { $_.DriveLetter }) -join ', ')." }
        New-Check 'Done' "Indexing off on $(($vols | ForEach-Object { $_.DriveLetter }) -join ', ')."
    }

    'disks-healthy' = {
        $bad = @(Get-Disk | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' -or "$($_.OperationalStatus)" -ne 'Online' })
        if ($bad) { return New-Check 'NotDone' "$(($bad | ForEach-Object { "disk $($_.Number) $($_.FriendlyName): $($_.HealthStatus), $($_.OperationalStatus)" }) -join '; ')." }
        New-Check 'Done' 'Every disk online and healthy as seen by Windows (check RAIDXpert2 / the RAID app for the array itself).'
    }

    'watchout-installed' = {
        # WATCHOUT 6 only: found by its executables, the same lookup as WO6-Setup.ps1.
        # WATCHOUT 7 has no check (owner, Oct 2026: its programs entry is not confirmed).
        if ("$($ctx.Profile)" -ne 'WO6') { return New-Check 'CantCheck' 'No check for WATCHOUT 7: confirm the install yourself.' }
        $p = Get-WatchoutPathFor6
        if ($p) { return New-Check 'Done' "WATCHOUT 6 in $p." }
        New-Check 'NotDone' 'WATCHPOINT.exe / WATCHMAKER.exe not found (set -WatchoutPath in Options if it is elsewhere).'
    }

    'wo7-workdir' = {
        $w = Get-Opt 'WorkingDirectory'
        if (-not $w) { return New-Check 'CantCheck' 'Working directory not set in Options (-WorkingDirectory): the wizard cannot see the WATCHOUT setting.' }
        if (Test-Path -LiteralPath $w) { return New-Check 'Done' "$w exists." }
        New-Check 'NotDone' "$w does not exist."
    }

    'static-ip' = {
        $up = @(Get-PhysicalNics | Where-Object { $_.Status -eq 'Up' })
        if (-not $up) { return New-Check 'CantCheck' 'No connected physical adapter.' }
        $dhcp = @(); $ok = @()
        foreach ($n in $up) {
            $if = Get-NetIPInterface -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            $ip = @(Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
            if ($if -and "$($if.Dhcp)" -eq 'Disabled' -and $ip) { $ok += "$($n.Name) $($ip -join ',')" } else { $dhcp += "$($n.Name) (DHCP $($ip -join ','))" }
        }
        if ($dhcp) { return New-Check 'NotDone' "Not static: $($dhcp -join '; ')." }
        New-Check 'Done' ($ok -join '; ')
    }

    'ipv4-only-bindings' = {
        $extra = 'ms_tcpip6', 'ms_pacer', 'ms_lltdio', 'ms_rspndr', 'ms_lldp', 'ms_implat'
        $found = @()
        foreach ($n in Get-PhysicalNics) {
            $on = @(Get-NetAdapterBinding -Name $n.Name -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $extra -contains $_.ComponentID } | ForEach-Object { $_.DisplayName })
            if ($on) { $found += "$($n.Name): $($on -join ', ')" }
        }
        if ($found) { return New-Check 'NotDone' "Still bound: $($found -join '; ')." }
        New-Check 'Done' 'Only IPv4 (and file sharing, if kept) bound on the physical adapters.'
    }

    'wol-magic-packet' = {
        $props = @(foreach ($n in Get-PhysicalNics) {
            Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Wake on Magic Packet' } })
        if (-not $props) { return New-Check 'NotApplicable' 'No adapter exposes "Wake on Magic Packet".' }
        $off = @($props | Where-Object { $_.DisplayValue -notmatch '^(Enabled|On)$' })
        if ($off) { return New-Check 'NotDone' "$(($off | ForEach-Object { "$($_.Name): $($_.DisplayValue)" }) -join '; ')." }
        New-Check 'Done' "Enabled on $(($props | ForEach-Object { $_.Name }) -join ', ') (Wake-on-LAN in the BIOS is not visible from Windows)."
    }

    'tamper-off' = {
        if ("$(Get-Opt 'DefenderMode')" -ne 'Off') { return New-Check 'NotApplicable' "Not needed with -DefenderMode $(Get-Opt 'DefenderMode')." }
        $s = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not $s) { return New-Check 'NotApplicable' 'Microsoft Defender is not running.' }
        if ($s.IsTamperProtected) { return New-Check 'NotDone' 'Tamper Protection is on.' }
        New-Check 'Done' 'Tamper Protection is off.'
    }

    'defender-off' = {
        $mode = "$(Get-Opt 'DefenderMode')"
        if ($mode -eq 'Skip') { return New-Check 'NotApplicable' 'Defender is not touched (-DefenderMode Skip).' }
        $s = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if (-not $s) { return New-Check 'Done' 'Microsoft Defender is not running.' }
        if ($mode -eq 'Exclusions') {
            $ex = @(Get-MpPreference | ForEach-Object { $_.ExclusionPath } | Where-Object { $_ })
            if ($ex) { return New-Check 'Done' "Defender on, exclusions: $($ex -join ', ')." }
            return New-Check 'NotDone' 'Defender on and no exclusions set.'
        }
        $on = @('RealTimeProtectionEnabled', 'BehaviorMonitorEnabled', 'OnAccessProtectionEnabled' | Where-Object { $s.$_ })
        if ($s.IsTamperProtected) { $on += 'IsTamperProtected' }
        if ($on) { return New-Check 'NotDone' "Still on: $($on -join ', ')." }
        New-Check 'Done' 'Real-time, behaviour and on-access protection off; Tamper Protection off.'
    }

    'power-plan' = {
        $guid = if ("$($ctx.Profile)" -eq 'WO6') { '6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e56' } else { '6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e57' }
        $active = (& powercfg.exe /getactivescheme) -join ' '
        if ($active -match $guid) { return New-Check 'Done' $active.Trim() }
        New-Check 'NotDone' "Active: $($active.Trim())"
    }

    'update-services-disabled' = {
        if ((Get-Opt 'KeepUpdateService') -eq $true) { return New-Check 'NotApplicable' 'Update services are kept (-KeepUpdateService).' }
        $not = @('BITS', 'wuauserv', 'UsoSvc' | Where-Object { $m = Get-ServiceStart $_; $m -and $m -ne 'Disabled' } | ForEach-Object { "$_ ($(Get-ServiceStart $_))" })
        if ($not) { return New-Check 'NotDone' "Not disabled: $($not -join ', ')." }
        New-Check 'Done' 'BITS, wuauserv and UsoSvc disabled.'
    }

    'reg-tdr' = {
        $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $a = Test-RegEquals $gd 'TdrDelay' 15 'TdrDelay'
        $b = Test-RegEquals $gd 'TdrDdiDelay' 60 'TdrDdiDelay'
        if ($a.State -eq 'Done' -and $b.State -eq 'Done') { return New-Check 'Done' "$($a.Detail) $($b.Detail)" }
        New-Check 'NotDone' "$($a.Detail) $($b.Detail)"
    }

    'reg-sysresp' = { Test-RegEquals 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10 'SystemResponsiveness' }

    'reg-priosep' = { Test-RegEquals 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 40 'Win32PrioritySeparation' }

    'visual-effects' = { Test-RegEquals 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2 'VisualFXSetting ("Adjust for best performance")' }

    'usb-notify-off' = { Test-RegEquals 'HKCU:\Software\Microsoft\Shell\USB' 'NotifyOnUsbErrors' 0 'NotifyOnUsbErrors' }

    'wsearch-disabled' = {
        $m = Get-ServiceStart 'WSearch'
        if (-not $m) { return New-Check 'Done' 'Windows Search service not present.' }
        if ($m -eq 'Disabled') { return New-Check 'Done' 'WSearch disabled.' }
        New-Check 'NotDone' "WSearch is $m."
    }

    'no-watchpoint-shortcut' = {
        $found = @()
        $shell = New-Object -ComObject WScript.Shell
        foreach ($dir in "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp") {
            Get-ChildItem $dir -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
                if ($shell.CreateShortcut($_.FullName).TargetPath -match 'WATCHPOINT') { $found += $_.FullName }
            }
        }
        if ($found) { return New-Check 'NotDone' "Startup shortcut(s) also start WATCHPOINT: $($found -join '; ')." }
        New-Check 'Done' 'No Startup-folder shortcut to WATCHPOINT.'
    }

    'vendor-services' = {
        $s = @(Get-CimInstance Win32_Service | Where-Object { $_.DisplayName -match 'Content Protection HDCP|HECI|NvTelemetry|NVIDIA Telemetry' -or $_.Name -match 'NvTelemetry' })
        if (-not $s) { return New-Check 'NotApplicable' 'None of these vendor services is installed.' }
        $on = @($s | Where-Object { $_.StartMode -ne 'Disabled' })
        if ($on) { return New-Check 'NotDone' "$(($on | ForEach-Object { "$($_.DisplayName): $($_.StartMode)" }) -join '; ')." }
        New-Check 'Done' "Disabled: $(($s | ForEach-Object { $_.DisplayName }) -join ', ')."
    }

    'watchpoint-task' = {
        $t = Get-ScheduledTask -TaskPath '\WATCHOUT\' -TaskName 'WATCHPOINT auto-start' -ErrorAction SilentlyContinue
        if (-not $t) { return New-Check 'NotDone' 'Task \WATCHOUT\WATCHPOINT auto-start not found.' }
        $info = Get-ScheduledTaskInfo -InputObject $t
        $limit = "$($t.Settings.ExecutionTimeLimit)"
        $problems = @()
        if ($limit -ne 'PT0S') { $problems += "time limit $limit" }
        if ($info.LastTaskResult -ne 267009) { $problems += ('last result 0x{0:X} (0x41301 = running)' -f $info.LastTaskResult) }
        if ($problems) { return New-Check 'NotDone' ($problems -join '; ') }
        New-Check 'Done' 'Running, no time limit.'
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
