#requires -RunAsAdministrator
<#
.SYNOPSIS
    The checklist steps the wizard performs itself, besides the two setup
    scripts. Owner-approved list (Oct 2026): BitLocker off, media drive
    initialise + format, indexing off, static IPs, Wake on Magic Packet.

.DESCRIPTION
    Each action prints the scripts' usual [OK] / [WARN] lines, reads back what
    it changed instead of trusting the call (AGENTS.md rule 2), and writes a
    small result file. The wizard has already shown a plain-language summary
    and got the operator's confirmation before calling an action.

    Two read-only queries feed the wizard's input dialogs:
      list-disks     disks that may be initialised (RAW, not boot/system, not USB)
      list-adapters  physical network adapters with their IPv4 settings

.PARAMETER Action
    bitlocker-off | media-disk-init | indexing-off | static-ip | wol-enable |
    list-disks | list-adapters

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
    switch ($Action) {
        'bitlocker-off'   { Invoke-BitLockerOff }
        'media-disk-init' { Invoke-MediaDiskInit }
        'indexing-off'    { Invoke-IndexingOff }
        'static-ip'       { Invoke-StaticIp }
        'wol-enable'      { Invoke-WolEnable }
        'list-disks'      { $data = Get-DiskList }
        'list-adapters'   { $data = Get-AdapterList }
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
