#requires -RunAsAdministrator
<#
.SYNOPSIS
    The checklist steps the wizard performs itself, besides the two setup
    scripts. Owner-approved list (Oct 2026): BitLocker off, media drive
    initialise + format, indexing off, static IPs, Wake on Magic Packet.
    Factory recovery (Nov 2026, OPEN_QUESTIONS 29): install the recovery
    boot, prepare a factory-image capture, copy the image off the machine.

.DESCRIPTION
    Each action prints the scripts' usual [OK] / [WARN] lines, reads back what
    it changed instead of trusting the call (AGENTS.md rule 2), and writes a
    small result file. The wizard has already shown a plain-language summary
    and got the operator's confirmation before calling an action.

    Read-only queries feed the wizard's input dialogs:
      list-disks         disks that may be initialised (RAW, not boot/system, not USB)
      list-adapters      physical network adapters with their IPv4 settings
      list-recovery-usb  recovery USB sticks (WO_RECOVERY_USB.tag) plugged in

    The recovery actions dot-source WO-Recovery.ps1 (extracted next to this
    script by the wizard) for the image-set helpers shared with the WinPE side.

.PARAMETER Action
    bitlocker-off | media-disk-init | indexing-off | static-ip | wol-enable |
    recovery-install | recovery-capture | recovery-export |
    list-disks | list-adapters | list-recovery-usb

.PARAMETER ParamsJson
    JSON with the action's input (see each action).

.PARAMETER ResultPath
    JSON { Status = Completed|Failed, Warnings = [...], Data = ... }.
#>
param(
    [Parameter(Mandatory)] [string]$Action,
    [string]$ParamsJson,
    [Parameter(Mandatory)] [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$script:Warnings = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$msg) { Write-Host "`n=== $msg" }
function Write-Ok  ([string]$msg) { Write-Host "  [OK]   $msg" }
function Write-Warn([string]$msg) { Write-Host "  [WARN] $msg"; $script:Warnings.Add($msg) }

$in = $null
if ($ParamsJson) { $in = Get-Content -Raw -LiteralPath $ParamsJson -Encoding UTF8 | ConvertFrom-Json }

function Get-In([string]$Name) {
    if ($in -and $in.PSObject.Properties[$Name]) { return $in.$Name }
    return $null
}

function Get-PhysicalNics { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' }) }

# ---------------------------------------------------------------------------
# Checklist "Disks": manage-bde -status C: -> if not fully decrypted,
# manage-bde -off C:. Windows 11 24H2+ encrypts by default; a BIOS or RAID
# change could then stop the machine at a recovery-key prompt.
# ---------------------------------------------------------------------------
function Invoke-BitLockerOff {
    Write-Step "BitLocker / device encryption off ($env:SystemDrive)"
    $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -eq $env:SystemDrive }
    if (-not $v) { Write-Ok 'BitLocker is not available on this Windows: nothing to do.'; return }
    $s = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
    if ($s.ConversionStatus -eq 0) { Write-Ok "$env:SystemDrive is already fully decrypted."; return }
    if ($s.ConversionStatus -eq 3) { Write-Ok "$env:SystemDrive is already decrypting ($([math]::Round(100 - $s.EncryptionPercentage)) % done)."; return }

    # manage-bde is the checklist command. Native stderr must not become a
    # terminating error under 'Stop' (Windows PowerShell 5.1), so relax it here.
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & manage-bde.exe -off $env:SystemDrive 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    $out | ForEach-Object { Write-Host "    $_" }
    if ($code -ne 0) { Write-Warn "manage-bde -off returned $code."; return }

    $s = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus
    if ($s.ConversionStatus -in 0, 3) { Write-Ok 'Decryption started. It continues in the background; the step is done when the check reports fully decrypted.' }
    else { Write-Warn "Decryption did not start (conversion status $($s.ConversionStatus))." }
}

# ---------------------------------------------------------------------------
# Checklist "Disks": initialise the media array as GPT, format NTFS (64 KB
# allocation unit optional). Writes to a disk: only a RAW disk (no partition
# table at all) that is not the boot/system disk is accepted, and the wizard
# has made the operator type the disk number (AGENTS.md rule 7).
# Input: DiskNumber, Label, AllocationUnitSize (4096 or 65536).
# ---------------------------------------------------------------------------
function Invoke-MediaDiskInit {
    $n = [int](Get-In 'DiskNumber')
    $label = "$(Get-In 'Label')"; if (-not $label) { $label = 'Media' }
    $au = [int](Get-In 'AllocationUnitSize'); if ($au -notin 4096, 65536) { $au = 65536 }
    Write-Step "Media drive: disk $n -> GPT, NTFS '$label', $($au / 1024) KB clusters"

    $d = Get-Disk -Number $n
    # Re-checked here, not only in the dialog: the disk list may have changed.
    if ($d.IsBoot -or $d.IsSystem) { throw "Disk $n is the boot/system disk. Refused." }
    if ("$($d.PartitionStyle)" -ne 'RAW') { throw "Disk $n is already initialised ($($d.PartitionStyle)). Refused: only empty (RAW) disks are formatted." }
    if ("$($d.BusType)" -in @('USB', 'SD', 'MMC')) { throw "Disk $n is a removable $($d.BusType) disk. Refused." }

    if ($d.IsOffline) { Set-Disk -Number $n -IsOffline $false }
    if ($d.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false }
    Initialize-Disk -Number $n -PartitionStyle GPT
    $part = New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter
    $vol = Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $label -AllocationUnitSize $au -Confirm:$false

    # Read back.
    $d = Get-Disk -Number $n
    $v = Get-Partition -DiskNumber $n | Get-Volume | Where-Object { $_.FileSystem -eq 'NTFS' } | Select-Object -First 1
    if ("$($d.PartitionStyle)" -eq 'GPT' -and $v) {
        Write-Ok "Disk $n is GPT; $($v.DriveLetter): NTFS '$($v.FileSystemLabel)', $([math]::Round($v.Size / 1GB)) GB, $($v.AllocationUnitSize / 1024) KB clusters."
    }
    else { Write-Warn "Disk $n could not be confirmed as GPT/NTFS after formatting." }
}

# ---------------------------------------------------------------------------
# Checklist "Disks": turn off indexing on the media drive (guide 10.15, per
# drive: untick "Allow files on this drive to have contents indexed").
# Applied to every fixed drive except the system drive, as Explorer's
# "Apply changes to <drive> only": the NotContentIndexed attribute is set
# on the drive's root folder; existing files are not touched. Read back
# from the same attribute. Win32_Volume.IndexingEnabled alone proved
# unreliable (owner, Oct 2026). [Uncertain] whether Explorer's box follows
# the root attribute in every case: the read-back says so if not.
# ---------------------------------------------------------------------------
function Invoke-IndexingOff {
    Write-Step 'Indexing off on the data drives'
    $vols = @(Get-CimInstance Win32_Volume -Filter 'DriveType=3' | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $env:SystemDrive })
    if (-not $vols) { Write-Ok 'No fixed drive besides the system drive.'; return }
    $flag = [IO.FileAttributes]::NotContentIndexed
    foreach ($v in $vols) {
        $root = "$($v.DriveLetter)\"
        $attr = [IO.File]::GetAttributes($root)
        if (($attr -band $flag) -eq $flag) { Write-Ok "$($v.DriveLetter) already off"; continue }
        try { [IO.File]::SetAttributes($root, ($attr -bor $flag)) }
        catch { Write-Warn "$($v.DriveLetter): could not change the root folder ($($_.Exception.Message)). Untick the box in the drive's Properties."; continue }
        # The WMI value too, so tools that read it agree; its result is not trusted.
        try { Set-CimInstance -InputObject $v -Property @{ IndexingEnabled = $false } -ErrorAction Stop } catch { }
        if (([IO.File]::GetAttributes($root) -band $flag) -eq $flag) { Write-Ok "$($v.DriveLetter) contents indexing off" }
        else { Write-Warn "$($v.DriveLetter): still allowed after the change. Untick the box in the drive's Properties." }
    }
}

# ---------------------------------------------------------------------------
# Checklist "WATCHOUT ... and NVIDIA": static IPs, one subnet. Input:
# Adapters = [ { Name, IPAddress, PrefixLength, Gateway?, Dns? } ]. Changing
# the address resets the link (the wizard warns before).
# ---------------------------------------------------------------------------
function Invoke-StaticIp {
    Write-Step 'Static IPv4 addresses'
    $list = @(Get-In 'Adapters')
    if (-not $list) { Write-Warn 'No adapter given.'; return }
    foreach ($a in $list) {
        $name = "$($a.Name)"; $ip = "$($a.IPAddress)"; $prefix = [int]$a.PrefixLength
        $gw = if ($a.PSObject.Properties['Gateway']) { "$($a.Gateway)" } else { '' }
        $dns = if ($a.PSObject.Properties['Dns']) { "$($a.Dns)" } else { '' }
        $nic = Get-NetAdapter -Name $name
        $idx = $nic.ifIndex
        try {
            Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
            Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            Get-NetRoute -InterfaceIndex $idx -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
            $ipArgs = @{ InterfaceIndex = $idx; IPAddress = $ip; PrefixLength = $prefix; AddressFamily = 'IPv4' }
            if ($gw) { $ipArgs.DefaultGateway = $gw }
            New-NetIPAddress @ipArgs | Out-Null
            if ($dns) { Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses @($dns -split '[,; ]+' | Where-Object { $_ }) }
            else { Set-DnsClientServerAddress -InterfaceIndex $idx -ResetServerAddresses }
        }
        catch { Write-Warn "${name}: $($_.Exception.Message)"; continue }

        $now = @(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
        $dhcp = (Get-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4).Dhcp
        if ($now -contains "$ip/$prefix" -and "$dhcp" -eq 'Disabled') { Write-Ok "${name}: $ip/$prefix$(if ($gw) { " gw $gw" })$(if ($dns) { " dns $dns" })" }
        else { Write-Warn "${name}: now $($now -join ', ') (DHCP $dhcp), expected $ip/$prefix." }
    }
}

# ---------------------------------------------------------------------------
# Checklist "Wake-on-LAN": NIC advanced property "Wake on Magic Packet" =
# Enabled (guide 10.11). The BIOS part stays manual. Display names are
# vendor-specific; the property is matched by name and its "on" value by
# Enabled/On, as the scripts do for EEE.
# ---------------------------------------------------------------------------
function Invoke-WolEnable {
    Write-Step 'Wake on Magic Packet'
    $any = $false
    foreach ($n in Get-PhysicalNics) {
        $props = @(Get-NetAdapterAdvancedProperty -Name $n.Name -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Wake on Magic Packet' })
        foreach ($p in $props) {
            $any = $true
            $on = $p.ValidDisplayValues | Where-Object { $_ -match '^(Enabled|On)$' } | Select-Object -First 1
            if (-not $on) { Write-Warn "$($n.Name): '$($p.DisplayName)' has no recognisable 'on' value ($($p.ValidDisplayValues -join ', ')). Set it by hand."; continue }
            if ($p.DisplayValue -eq $on) { Write-Ok "$($n.Name): already $on"; continue }
            # Changing an advanced property briefly resets the link.
            Set-NetAdapterAdvancedProperty -Name $n.Name -DisplayName $p.DisplayName -DisplayValue $on
            $after = (Get-NetAdapterAdvancedProperty -Name $n.Name -DisplayName $p.DisplayName).DisplayValue
            if ($after -eq $on) { Write-Ok "$($n.Name): '$($p.DisplayName)' -> $on" } else { Write-Warn "$($n.Name): still '$after'." }
        }
    }
    if (-not $any) { Write-Ok 'No adapter exposes "Wake on Magic Packet": nothing to set.' }
    Write-Host '  [i]    Wake-on-LAN must also be enabled in the BIOS.'
}

# ===========================================================================
# Factory recovery (owner, Nov 2026; OPEN_QUESTIONS 29). The factory image is
# the machine at the end of the build: C: and the RAID0 (D:, WATCHOUT folder
# + empty working directory), captured together before any show, restored
# from a WinPE booted from the hidden WO_RECOVERY partition (created in
# Windows Setup, PROJECT_CONTEXT 2a) or a recovery USB stick. The WinPE side
# is recovery/partition/WO-Recovery.ps1. [Uncertain] on real hardware until
# tested (MILESTONES "R").
# ===========================================================================

function ConvertTo-BootKeyAction([string]$Key) {
    # Windows Boot Manager "custom action": pressing the key at start boots
    # the entry bound to 0x54000001. Value = 0x10000 + PS/2 scan code (set 1)
    # + 000001, e.g. F10 (0x44) -> 0x1000044000001.
    # [Uncertain] The format comes from Microsoft's old "hardware recovery
    # button" page and community reports, not from current documentation;
    # whether the firmware passes the key in time is per machine model.
    $scan = @{ F8 = 0x42; F9 = 0x43; F10 = 0x44; F11 = 0x57 }
    if (-not $Key -or -not $scan.ContainsKey($Key)) { throw "Recovery key '$Key' is not supported (F8, F9, F10, F11)." }
    return ('0x10000{0:x2}000001' -f $scan[$Key])
}

function Get-BcdGuid([string[]]$Lines) {
    # First {GUID} in bcdedit output ("The entry {...} was successfully
    # created."): works in every display language.
    foreach ($l in @($Lines)) {
        $m = [regex]::Match("$l", '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}')
        if ($m.Success) { return $m.Value.ToLowerInvariant() }
    }
    return $null
}

function Invoke-BcdEdit([string[]]$Arguments, [switch]$AllowFail) {
    # bcdedit writes errors to stderr; under 'Stop' that would throw before
    # the exit code is read (Windows PowerShell 5.1).
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& bcdedit.exe @Arguments 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) { throw "bcdedit $($Arguments -join ' ') failed ($code): $($out -join ' ')" }
    return [pscustomobject]@{ Code = $code; Lines = $out }
}

function Set-Bcd([string[]]$Arguments) { [void](Invoke-BcdEdit $Arguments) }

function Get-WORecoveryPartition {
    # The partition made in Windows Setup: type Recovery, label WO_RECOVERY,
    # on the system disk.
    $sysDisk = (Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1)).DiskNumber
    foreach ($p in @(Get-Partition -DiskNumber $sysDisk | Where-Object { "$($_.GptType)" -ieq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' })) {
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel -eq 'WO_RECOVERY') { return $p }
    }
    return $null
}

function Mount-WORecovery($Partition) {
    # A temporary drive letter; Dismount-WORecovery removes it again so
    # Windows and WATCHOUT never see the partition.
    $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
    if (Test-DriveLetter $p.DriveLetter) { return [pscustomobject]@{ Letter = "$($p.DriveLetter)"; Added = $false; Partition = $p } }
    $p | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
    $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
    if (-not (Test-DriveLetter $p.DriveLetter)) { throw 'Could not give the recovery partition a temporary drive letter.' }
    return [pscustomobject]@{ Letter = "$($p.DriveLetter)"; Added = $true; Partition = $p }
}

function Dismount-WORecovery($Mount) {
    if (-not $Mount -or -not $Mount.Added) { return }
    try { Remove-PartitionAccessPath -DiskNumber $Mount.Partition.DiskNumber -PartitionNumber $Mount.Partition.PartitionNumber -AccessPath "$($Mount.Letter):\" }
    catch { Write-Warn "The recovery partition keeps the letter $($Mount.Letter): ($($_.Exception.Message)). Remove it in Disk Management." }
}

function Test-VolumeDecrypted([string]$Letter) {
    # DISM in WinPE cannot read a BitLocker volume.
    $v = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -eq "${Letter}:" }
    if (-not $v) { return $true }
    return ((Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus).ConversionStatus -eq 0)
}

function Get-FolderBytes([string]$Path) {
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

# ---------------------------------------------------------------------------
# Install the recovery boot (WO7 checklist 8, "Install the recovery boot").
# Input: SourceFolder (Build-WinPE.ps1 output, next to the wizard exe),
# Hotkey (F8-F11), DataDrive (letter of the RAID0), WatchoutPath,
# WorkingDirectory. Writes to the recovery partition and the boot
# configuration (BCD, backed up first); typed BOOT in the wizard.
# ---------------------------------------------------------------------------
function Invoke-RecoveryInstall {
    $src = "$(Get-In 'SourceFolder')"
    $key = "$(Get-In 'Hotkey')"; if (-not $key) { $key = 'F9' }
    $dataDrive = "$(Get-In 'DataDrive')"; if (-not $dataDrive) { $dataDrive = 'D' }
    $dataDrive = $dataDrive.Substring(0, 1).ToUpperInvariant()
    $woPath = "$(Get-In 'WatchoutPath')"
    $workDir = "$(Get-In 'WorkingDirectory')"
    Write-Step 'Recovery boot: WinPE on WO_RECOVERY, boot entry, recovery key, failover'

    # 1. The WinPE built by tools/recovery/Build-WinPE.ps1, checked against its manifest.
    $manifestPath = Join-Path $src 'manifest.json'
    if (-not $src -or -not (Test-Path -LiteralPath $manifestPath)) {
        throw "No recovery WinPE in '$src' (manifest.json missing). Build it with tools/recovery/Build-WinPE.ps1 and put the WOSetupRecovery folder next to WOSetupWizard.exe."
    }
    $man = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
    $wim = Join-Path $src "$($man.BootWim)"
    $sdi = Join-Path $src "$($man.BootSdi)"
    foreach ($f in @(@($wim, "$($man.BootWimSha256)"), @($sdi, "$($man.BootSdiSha256)"))) {
        if (-not (Test-Path -LiteralPath $f[0])) { throw "Missing $($f[0])." }
        if ((Get-FileHash -LiteralPath $f[0] -Algorithm SHA256).Hash -ne $f[1]) { throw "$($f[0]) does not match manifest.json (damaged or mixed-up copy)." }
    }
    $drivers = @($man.Drivers)
    Write-Ok "WinPE from ADK $($man.AdkVersion), built $($man.BuiltAt); drivers: $(if ($drivers.Count) { $drivers -join ', ' } else { 'none' })"
    if ($drivers.Count -eq 0) { Write-Warn 'The recovery WinPE contains no added driver: on a RAID system array it cannot see C:. Rebuild it with -DriverFolder.' }

    # 2. Partitions, by identity.
    $rp = Get-WORecoveryPartition
    if (-not $rp) { throw 'No WO_RECOVERY partition (type Recovery) on the system disk. It is created in Windows Setup: docs/PROJECT_CONTEXT.md section 2a.' }
    $sys = Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1)
    $data = Get-Partition -DriveLetter $dataDrive -ErrorAction SilentlyContinue
    if (-not $data) { throw "No ${dataDrive}: drive. The factory image covers C: and the RAID0 (D:)." }
    $sysVol = Get-Volume -DriveLetter $env:SystemDrive.Substring(0, 1)
    $dataVol = Get-Volume -DriveLetter $dataDrive
    foreach ($pair in @(@('WATCHOUT folder', $woPath), @('Working directory', $workDir))) {
        if ($pair[1] -and -not $pair[1].StartsWith("${dataDrive}:\", [StringComparison]::OrdinalIgnoreCase)) {
            Write-Warn "$($pair[0]) $($pair[1]) is not on ${dataDrive}: (the factory image holds C: and ${dataDrive}: only)."
        }
    }
    $au = 65536
    if ($dataVol.PSObject.Properties['AllocationUnitSize'] -and $dataVol.AllocationUnitSize) { $au = [int]$dataVol.AllocationUnitSize }

    $m = Mount-WORecovery $rp
    try {
        $R = "$($m.Letter):"
        # 3. Files.
        New-Item -ItemType Directory -Path "$R\WORecovery", "$R\Images", "$R\Logs" -Force | Out-Null
        Copy-Item -LiteralPath $wim -Destination "$R\WORecovery\boot.wim" -Force
        Copy-Item -LiteralPath $sdi -Destination "$R\WORecovery\boot.sdi" -Force
        if ((Get-FileHash -LiteralPath "$R\WORecovery\boot.wim" -Algorithm SHA256).Hash -ne "$($man.BootWimSha256)") { throw 'boot.wim on the recovery partition does not match after copying.' }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'WO-Recovery.ps1') -Destination "$R\WO-Recovery.ps1" -Force
        Set-Content -LiteralPath "$R\WO_RECOVERY.tag" -Value 'WATCHOUT factory recovery' -Encoding ASCII
        $free = (Get-Volume -DriveLetter $m.Letter).SizeRemaining
        Write-Ok "WinPE and WO-Recovery.ps1 on the recovery partition ($(Format-Bytes $m.Partition.Size), $(Format-Bytes $free) free)"

        # 4. Boot entry (RAM-disk WinPE, UEFI). Entries of an earlier run are replaced.
        $old = Read-Target "$R\"
        $bak = Join-Path (Split-Path $ResultPath) ('BCD_Backup_{0}.bcd' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Set-Bcd @('/export', $bak)
        Write-Host "  [i]    Restore: bcdedit /import `"$bak`""
        $oldBoot = Get-Prop $old 'Boot'
        foreach ($g in @("$(Get-Prop $oldBoot 'EntryGuid')", "$(Get-Prop $oldBoot 'DeviceGuid')")) {
            if ($g) { [void](Invoke-BcdEdit @('/delete', $g, '/f') -AllowFail) }
        }
        # A device object of its own, not the shared {ramdiskoptions} (WinRE may use it).
        $dev = Get-BcdGuid (Invoke-BcdEdit @('/create', '/d', 'WATCHOUT recovery ramdisk', '/device')).Lines
        if (-not $dev) { throw 'bcdedit did not return the ramdisk device id.' }
        Set-Bcd @('/set', $dev, 'ramdisksdidevice', "partition=$R")
        Set-Bcd @('/set', $dev, 'ramdisksdipath', '\WORecovery\boot.sdi')
        $entry = Get-BcdGuid (Invoke-BcdEdit @('/create', '/d', 'WATCHOUT Factory Recovery', '/application', 'osloader')).Lines
        if (-not $entry) { throw 'bcdedit did not return the boot entry id.' }
        $rd = "ramdisk=[$R]\WORecovery\boot.wim,$dev"
        $winload = "$($man.WinloadPath)"; if (-not $winload) { $winload = '\windows\system32\boot\winload.efi' }
        foreach ($kv in @(@('device', $rd), @('osdevice', $rd), @('path', $winload), @('systemroot', '\windows'),
                          @('detecthal', 'yes'), @('winpe', 'yes'), @('recoveryenabled', 'no'))) {
            Set-Bcd @('/set', $entry, $kv[0], $kv[1])
        }
        Write-Ok "Boot entry $entry (not in the boot menu; the BCD keeps the partition, not the letter)"

        # 5. Ways in before Windows starts (owner decision 29a). [Uncertain] both, test per model.
        Set-Bcd @('/set', '{default}', 'recoverysequence', $entry)
        Set-Bcd @('/set', '{default}', 'recoveryenabled', 'yes')
        Set-Bcd @('/set', '{bootmgr}', 'customactions', (ConvertTo-BootKeyAction $key), '0x54000001')
        Set-Bcd @('/set', '{bootmgr}', 'custom:54000001', $entry)

        # 6. target.json: what WinPE needs to find C: and D: by identity.
        $target = [ordered]@{
            SchemaVersion = 1
            Computer      = $env:COMPUTERNAME
            CreatedAt     = (Get-Date).ToString('o')
            System        = [ordered]@{ PartitionGuid = (ConvertTo-NormalGuid "$($sys.Guid)"); DiskNumber = $sys.DiskNumber; Size = $sys.Size; Label = "$($sysVol.FileSystemLabel)" }
            Data          = [ordered]@{ PartitionGuid = (ConvertTo-NormalGuid "$($data.Guid)"); DiskNumber = $data.DiskNumber; Size = $data.Size; Label = "$($dataVol.FileSystemLabel)";
                                        AllocationUnitSize = $au; DriveLetter = $dataDrive; WatchoutPath = $woPath; WorkingDirectory = $workDir }
            Recovery      = [ordered]@{ PartitionGuid = (ConvertTo-NormalGuid "$($rp.Guid)") }
            Boot          = [ordered]@{ EntryGuid = $entry; DeviceGuid = $dev; Hotkey = $key;
                                        AdkVersion = "$($man.AdkVersion)"; WinPEBuiltAt = "$($man.BuiltAt)"; BootWimSha256 = "$($man.BootWimSha256)" }
        }
        foreach ($s in 'System', 'Data') { if (-not $target[$s].PartitionGuid -or $target[$s].PartitionGuid -eq '{}') { throw "$s partition has no GPT GUID (MBR disk?). Not supported." } }
        [IO.File]::WriteAllText("$R\target.json", (ConvertTo-Json -InputObject $target -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

        # 7. Desktop file for a running Windows: restart once into the recovery.
        $cmd = Join-Path $env:PUBLIC 'Desktop\Factory recovery.cmd'
        $lines = @(
            '@echo off',
            'REM Restarts ONCE into the WATCHOUT factory recovery (restore / capture menu).',
            'REM Nothing is erased by this file: the recovery asks you to type RESTORE first.',
            'net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -FilePath ''%~f0'' -Verb RunAs" & exit /b)',
            "bcdedit /bootsequence $entry || (echo Could not set the next start. & pause & exit /b 1)",
            'shutdown /r /t 10 /c "Restarting into the WATCHOUT factory recovery"'
        )
        [IO.File]::WriteAllLines($cmd, $lines, (New-Object System.Text.ASCIIEncoding))
        Write-Ok "Desktop file '$cmd' (restart into the recovery from a running Windows)"

        # 8. Read back (GUIDs are language-independent in bcdedit output).
        if ((Invoke-BcdEdit @('/enum', $entry) -AllowFail).Code -eq 0) { Write-Ok 'Boot entry present' } else { Write-Warn 'Boot entry not found after creating it.' }
        if (((Invoke-BcdEdit @('/enum', '{default}') -AllowFail).Lines -join "`n") -match [regex]::Escape($entry)) { Write-Ok 'Failover: Windows not starting -> the recovery [Uncertain: test it]' }
        else { Write-Warn 'Failover to the recovery is not set on the Windows entry.' }
        if (((Invoke-BcdEdit @('/enum', '{bootmgr}') -AllowFail).Lines -join "`n") -match [regex]::Escape($entry)) { Write-Ok "Recovery key: $key at power-on [Uncertain: test it on this model]" }
        else { Write-Warn "Recovery key $key is not set in the boot manager." }
        $check = Read-Target "$R\"
        if (@(Test-Target $check).Count -eq 0) { Write-Ok "target.json: C: $($target.System.PartitionGuid), ${dataDrive}: $($target.Data.PartitionGuid)" } else { Write-Warn 'target.json could not be read back.' }
        return [pscustomobject]@{ EntryGuid = $entry; Hotkey = $key }
    }
    finally { Dismount-WORecovery $m }
}

# ---------------------------------------------------------------------------
# Capture the factory image (WO7 checklist 8). Input: Name. Checks what WinPE
# cannot (BitLocker, D: content, room), leaves pending.json for WO-Recovery.ps1,
# sets the next start to the recovery once and restarts in 30 s. The capture
# itself runs in WinPE, which restarts into Windows by itself. Typed CAPTURE
# in the wizard.
# ---------------------------------------------------------------------------
function Invoke-RecoveryCapture {
    $name = "$(Get-In 'Name')"
    if (-not (Test-ImageName $name)) { throw "Image name '$name' is not valid: letters, digits, . _ - (e.g. WO7.8.4_W11-25H2_2026-11-20)." }
    Write-Step "Factory image '$name': prepare the capture"
    $rp = Get-WORecoveryPartition
    if (-not $rp) { throw 'No WO_RECOVERY partition on the system disk.' }
    $m = Mount-WORecovery $rp
    try {
        $R = "$($m.Letter):"
        $target = Read-Target "$R\"
        $problems = @(Test-Target $target)
        if ($problems.Count -gt 0) { throw "Run 'Install the recovery boot' first ($($problems -join ' '))." }
        $entry = "$(Get-Prop (Get-Prop $target 'Boot') 'EntryGuid')"
        if (-not $entry -or (Invoke-BcdEdit @('/enum', $entry) -AllowFail).Code -ne 0) { throw "The recovery boot entry is missing. Run 'Install the recovery boot' again." }
        $dl = "$(Get-Prop $target.Data 'DriveLetter')"; if (-not $dl) { $dl = 'D' }
        $c = $env:SystemDrive.Substring(0, 1)

        foreach ($l in $c, $dl) { if (-not (Test-VolumeDecrypted $l)) { throw "${l}: is encrypted (BitLocker); the recovery cannot read it. Decrypt it first (step 3.1)." } }
        Write-Ok "${c}: and ${dl}: not encrypted"

        # Factory state = no show yet (owner, Nov 2026).
        $allowed = @()
        foreach ($p in 'WatchoutPath', 'WorkingDirectory') { $v = "$(Get-Prop $target.Data $p)"; if ($v) { $allowed += Split-Path -Leaf $v } }
        $extra = @(Get-UnexpectedDataEntries -Entries @(Get-ChildItem -LiteralPath "${dl}:\" -Force | ForEach-Object { $_.Name }) -Allowed $allowed)
        if ($extra.Count -gt 0) { throw "${dl}: holds more than the WATCHOUT folder and the working directory: $($extra -join ', '). It would become factory state: move it off, then capture." }
        $wd = "$(Get-Prop $target.Data 'WorkingDirectory')"
        if ($wd -and (Test-Path -LiteralPath $wd)) {
            $wdBytes = Get-FolderBytes $wd
            # [Uncertain] threshold: what WATCHOUT 7 keeps in an unused working directory is unknown.
            if ($wdBytes -gt 100MB) { throw "The working directory $wd holds $(Format-Bytes $wdBytes): capture before loading any show (factory reset = empty working directory)." }
        }
        Write-Ok "${dl}: holds only $(if ($allowed.Count) { $allowed -join ' and ' } else { 'nothing besides system folders' })"

        # Room on the recovery partition (WinPE re-checks with the same rule).
        $cv = Get-Volume -DriveLetter $c; $dv = Get-Volume -DriveLetter $dl
        $used = [long](($cv.Size - $cv.SizeRemaining) + ($dv.Size - $dv.SizeRemaining))
        $cur = Get-ImageSetFiles -Folder "$R\Images" -Prefix 'factory'
        $prev = Get-ImageSetFiles -Folder "$R\Images" -Prefix 'factory_prev'
        $estimate = Get-CaptureEstimate -UsedBytes $used -PreviousImageBytes $cur.Bytes
        $free = (Get-Volume -DriveLetter $m.Letter).SizeRemaining
        $plan = Get-CapturePlan -FreeBytes $free -EstimateBytes $estimate -FallbackBytes $prev.Bytes
        Write-Host "  [i]    Used on ${c}: + ${dl}: $(Format-Bytes $used); estimated image $(Format-Bytes $estimate) [Uncertain]; free on the recovery partition $(Format-Bytes $free)"
        if ($plan -eq 'NotEnough') { throw 'Not enough room on the recovery partition for this image, even without the fallback. A larger partition is needed (Windows Setup), or copy the images off and delete them.' }
        if ($plan -eq 'DeleteFallback') { Write-Warn "The older fallback image '$($prev.Name)' will be deleted to make room (the current factory image is kept until the new one is complete)." }

        $req = [ordered]@{ Action = 'Capture'; Name = $name; RequestedAt = (Get-Date).ToString('o'); RequestedBy = "$env:USERDOMAIN\$env:USERNAME" }
        [IO.File]::WriteAllText("$R\pending.json", (ConvertTo-Json -InputObject $req), (New-Object System.Text.UTF8Encoding($false)))
        Set-Bcd @('/bootsequence', $entry)
        Write-Ok 'Next start: the recovery captures C: and D:, then restarts into Windows by itself'
    }
    finally { Dismount-WORecovery $m }
    & shutdown.exe /r /t 30 /c 'WATCHOUT setup wizard: restarting into the factory recovery to capture the factory image.'
    Write-Ok 'Restarting in 30 seconds. Afterwards start the wizard again; the step is checked then.'
    return [pscustomobject]@{ Name = $name; RestartSeconds = 30 }
}

# ---------------------------------------------------------------------------
# Copy the factory image off the machine (WO7 checklist 8). Input:
# Destination folder (default: the recovery stick's Images\<COMPUTERNAME>).
# The copy is checked with SHA-256 against the original; an older copy there
# becomes the stick's fallback.
# ---------------------------------------------------------------------------
function Invoke-RecoveryExport {
    $dest = "$(Get-In 'Destination')"
    if (-not $dest) { throw 'No destination folder.' }
    Write-Step "Copy the factory image to $dest"
    $rp = Get-WORecoveryPartition
    if (-not $rp) { throw 'No WO_RECOVERY partition on the system disk.' }
    $m = Mount-WORecovery $rp
    try {
        $set = Get-ImageSetFiles -Folder "$($m.Letter):\Images" -Prefix 'factory'
        if (-not $set.Complete) { throw 'No complete factory image on the recovery partition. Capture it first.' }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        if ($dest -match '^[A-Za-z]:') {
            $freeDest = ([IO.DriveInfo]$dest.Substring(0, 1)).AvailableFreeSpace
            if ($freeDest -lt ($set.Bytes + 1GB)) { throw "Not enough room on $($dest.Substring(0, 2)): $(Format-Bytes $freeDest) free, $(Format-Bytes $set.Bytes) needed." }
        }
        $there = Get-ImageSetFiles -Folder $dest -Prefix 'factory'
        $hash = @{}
        foreach ($f in $set.C, $set.D) { $hash[(Split-Path -Leaf $f)] = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash }
        if ($there.Complete -and $there.Name -eq $set.Name -and
            (Get-FileHash -LiteralPath $there.C -Algorithm SHA256).Hash -eq $hash['factory_C.wim'] -and
            (Get-FileHash -LiteralPath $there.D -Algorithm SHA256).Hash -eq $hash['factory_D.wim']) {
            Write-Ok "'$($set.Name)' is already there, identical."
            return [pscustomobject]@{ Destination = $dest; Name = $set.Name }
        }
        Remove-ImageSet -Folder $dest -Prefix 'new'
        Copy-Item -LiteralPath $set.C -Destination (Join-Path $dest 'new_C.wim')
        Copy-Item -LiteralPath $set.D -Destination (Join-Path $dest 'new_D.wim')
        Copy-Item -LiteralPath $set.Meta -Destination (Join-Path $dest 'new.json')
        foreach ($pair in @(@('new_C.wim', 'factory_C.wim'), @('new_D.wim', 'factory_D.wim'))) {
            if ((Get-FileHash -LiteralPath (Join-Path $dest $pair[0]) -Algorithm SHA256).Hash -ne $hash[$pair[1]]) {
                Remove-ImageSet -Folder $dest -Prefix 'new'
                throw "The copy of $($pair[1]) does not match the original. Nothing was replaced."
            }
        }
        $hadOlder = Invoke-ImageRotation -Folder $dest
        Write-Ok "'$($set.Name)' copied and verified (SHA-256), $(Format-Bytes $set.Bytes)$(if ($hadOlder) { '; the older copy there is now its fallback' })"
        return [pscustomobject]@{ Destination = $dest; Name = $set.Name }
    }
    finally { Dismount-WORecovery $m }
}

function Get-RecoveryUsbList {
    # Sticks made by tools/recovery/New-RecoveryUsb.ps1.
    @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { Test-DriveLetter $_.DriveLetter } |
        Where-Object { Test-Path -LiteralPath "$($_.DriveLetter):\WO_RECOVERY_USB.tag" } |
        ForEach-Object { [pscustomobject]@{ Letter = "$($_.DriveLetter)"; Label = "$($_.FileSystemLabel)"; FreeGB = [math]::Round($_.SizeRemaining / 1GB)
                                            Destination = "$($_.DriveLetter):\Images\$env:COMPUTERNAME" } })
}

function Get-DiskList {
    @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and "$($_.BusType)" -notin @('USB', 'SD', 'MMC') -and "$($_.PartitionStyle)" -eq 'RAW' } |
        ForEach-Object { [pscustomobject]@{ Number = $_.Number; Name = "$($_.FriendlyName)"; SizeGB = [math]::Round($_.Size / 1GB); BusType = "$($_.BusType)" } })
}

function Get-AdapterList {
    @(Get-PhysicalNics | ForEach-Object {
        $n = $_
        $ip = Get-NetIPAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
        $gw = Get-NetRoute -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1
        # Pipeline, not (...).ServerAddresses: under StrictMode a missing entry would throw.
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
        $if = Get-NetIPInterface -InterfaceIndex $n.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Name = $n.Name; Description = $n.InterfaceDescription; Status = "$($n.Status)"
            Dhcp = if ($if) { "$($if.Dhcp)" } else { '' }
            IPAddress = if ($ip) { $ip.IPAddress } else { '' }
            PrefixLength = if ($ip) { [int]$ip.PrefixLength } else { 24 }
            Gateway = if ($gw) { $gw.NextHop } else { '' }
            Dns = ($dns -join ', ')
        }
    })
}

$data = $null
$status = 'Completed'
try {
    # Shared image-set helpers of the WinPE side (the wizard extracts
    # WO-Recovery.ps1 next to this script). Dot-sourced: its menu does not start.
    if ($Action -like 'recovery-*' -or $Action -eq 'list-recovery-usb') {
        $shared = Join-Path $PSScriptRoot 'WO-Recovery.ps1'
        if (-not (Test-Path -LiteralPath $shared)) { throw "WO-Recovery.ps1 is missing next to $PSCommandPath." }
        . $shared
    }
    switch ($Action) {
        'bitlocker-off'   { Invoke-BitLockerOff }
        'media-disk-init' { Invoke-MediaDiskInit }
        'indexing-off'    { Invoke-IndexingOff }
        'static-ip'       { Invoke-StaticIp }
        'wol-enable'      { Invoke-WolEnable }
        'recovery-install' { $data = Invoke-RecoveryInstall }
        'recovery-capture' { $data = Invoke-RecoveryCapture }
        'recovery-export'  { $data = Invoke-RecoveryExport }
        'list-disks'      { $data = Get-DiskList }
        'list-adapters'   { $data = Get-AdapterList }
        'list-recovery-usb' { $data = Get-RecoveryUsbList }
        default           { throw "Unknown action '$Action'." }
    }
}
catch {
    $status = 'Failed'
    Write-Host "[FATAL] $($_.Exception.Message)"
    $script:Warnings.Add($_.Exception.Message)
}
finally {
    $list = if ($null -eq $data) { @() } else { @($data) }
    $result = [ordered]@{ Status = $status; Warnings = @($script:Warnings); Data = $list }
    [IO.File]::WriteAllText($ResultPath, (ConvertTo-Json -InputObject $result -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
}
if ($status -eq 'Failed') { exit 2 }
exit 0
