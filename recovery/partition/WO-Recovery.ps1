<#
.SYNOPSIS
    WATCHOUT server factory recovery: capture and restore the factory image
    of the system volume (C:) and the RAID0 data volume (D:).

.DESCRIPTION
    Runs inside WinPE (Windows PowerShell 5.1 with the WinPE-PowerShell,
    WinPE-StorageWMI and WinPE-DismCmdlets components), started by
    X:\WORecovery\Start-WORecovery.ps1 from the hidden WO_RECOVERY partition
    or from a recovery USB stick. Owner decisions: OPEN_QUESTIONS 29.

    What a factory reset means here (owner, 20 Nov 2026): the machine as it
    was at the end of the build, Windows and WATCHOUT freshly installed and
    tweaked. The image is a pair captured together before any show:
        Images\factory_C.wim   the system volume
        Images\factory_D.wim   the RAID0 (WATCHOUT folder + empty working dir)
        Images\factory.json    name, date, computer, sizes
    The previous pair is kept as the fallback (factory_prev_*). Restore
    formats C: and D: and applies both images; shows and assets are lost and
    uploaded again by the operator.

    Volumes are found by identity, never by drive letter (WinPE gives its
    own letters): target.json on the recovery partition holds the GPT
    partition GUIDs of C: and D:, written by the setup wizard
    (WO-Actions.ps1 recovery-install). A formatted partition keeps its GUID,
    so the boot configuration stays valid and no bcdboot is needed.

    Typed confirmations (AGENTS.md rule 7): RESTORE before a restore,
    CAPTURE before a capture started from this menu. A capture requested by
    the wizard (pending.json) was confirmed there with CAPTURE and runs after
    a 15-second countdown that any key cancels.

    Every run writes Logs\<stamp>_<action>.log and Logs\last-result.json on
    the recovery partition; the wizard reads them back (check factory-image).

    The wizard also dot-sources this file for the shared image-set helpers;
    the menu only starts when the file is run, not when it is dot-sourced.

    UNTESTED on real hardware: every DISM, format and partition step is
    [Uncertain] until run on a VM and on the ThinkStation (MILESTONES "R").

#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$script:EspGptType      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$script:RecoveryLabel   = 'WO_RECOVERY'
$script:LogFile         = $null

# ===========================================================================
# Pure helpers (Pester: tests/pester/Recovery.Tests.ps1)
# Functions returning lists return plain arrays; callers wrap them in @(...).
# ("return , $x" would make @(f) count 1 even for an empty list.)
# ===========================================================================

function Test-ImageName([string]$Name) {
    # Becomes part of file metadata and log lines: keep it plain.
    # e.g. WO7.8.4_W11-25H2_2026-11-20
    return [bool]($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')
}

function Test-DriveLetter($Letter) {
    # Get-Partition reports "no letter" as the character 0, not as $null.
    return [bool]("$Letter" -match '^[A-Za-z]$')
}

function Get-Prop($Object, [string]$Name) {
    # Property value or '' (StrictMode-safe for JSON read from disk).
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return ''
}

function Format-Bytes([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return "$Bytes bytes"
}

function ConvertTo-NormalGuid([string]$Guid) {
    # '{ABC...}' / 'abc...' -> '{abc...}' so GUIDs from Get-Partition, JSON and
    # bcdedit compare equal.
    if (-not $Guid) { return '' }
    $g = $Guid.Trim().Trim('{', '}').ToLowerInvariant()
    return "{$g}"
}

function Select-PartitionByGuid($Partitions, [string]$Guid) {
    # $Partitions: objects with a Guid property (Get-Partition output).
    $want = ConvertTo-NormalGuid $Guid
    # An empty GUID must never match: MBR partitions have none either.
    if (-not $want -or $want -eq '{}') { return $null }
    foreach ($p in @($Partitions)) {
        if ($p.PSObject.Properties['Guid'] -and (ConvertTo-NormalGuid "$($p.Guid)") -eq $want) { return $p }
    }
    return $null
}

function Get-ImageSetFiles([string]$Folder, [string]$Prefix) {
    # One image set: <Prefix>_C.wim, <Prefix>_D.wim, <Prefix>.json.
    $c = Join-Path $Folder "${Prefix}_C.wim"
    $d = Join-Path $Folder "${Prefix}_D.wim"
    $m = Join-Path $Folder "$Prefix.json"
    $info = $null
    if (Test-Path -LiteralPath $m) {
        try { $info = Get-Content -Raw -LiteralPath $m -Encoding UTF8 | ConvertFrom-Json } catch { $info = $null }
    }
    $hasC = Test-Path -LiteralPath $c
    $hasD = Test-Path -LiteralPath $d
    $bytes = [long]0
    if ($hasC) { $bytes += (Get-Item -LiteralPath $c).Length }
    if ($hasD) { $bytes += (Get-Item -LiteralPath $d).Length }
    [pscustomobject]@{
        Folder   = $Folder
        Prefix   = $Prefix
        C        = $c
        D        = $d
        Meta     = $m
        Info     = $info
        Bytes    = $bytes
        Complete = ($hasC -and $hasD -and $null -ne $info)
        Name     = $(if ($null -ne $info -and $info.PSObject.Properties['Name']) { "$($info.Name)" } else { '' })
    }
}

function Find-ImageSets([string[]]$Roots) {
    # Every complete set under <root>\Images (internal partition) and
    # <root>\Images\<computer> (USB stick, one folder per machine).
    $sets = New-Object System.Collections.Generic.List[object]
    foreach ($r in @($Roots)) {
        if (-not $r) { continue }
        $base = Join-Path $r 'Images'
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $folders = @($base) + @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        foreach ($f in $folders) {
            foreach ($prefix in 'factory', 'factory_prev') {
                $s = Get-ImageSetFiles -Folder $f -Prefix $prefix
                if ($s.Complete) { $sets.Add($s) }
            }
        }
    }
    return $sets.ToArray()
}

function Remove-ImageSet([string]$Folder, [string]$Prefix) {
    foreach ($n in "${Prefix}_C.wim", "${Prefix}_D.wim", "$Prefix.json") {
        $p = Join-Path $Folder $n
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
}

function Invoke-ImageRotation([string]$Folder) {
    # After a successful capture: new_* -> factory_*, factory_* -> factory_prev_*,
    # the older fallback is deleted. Refuses an incomplete new set so a failed
    # capture never replaces a good image.
    $new = Get-ImageSetFiles -Folder $Folder -Prefix 'new'
    if (-not $new.Complete) { throw "New image set in $Folder is incomplete; nothing was replaced." }
    Remove-ImageSet -Folder $Folder -Prefix 'factory_prev'
    $cur = Get-ImageSetFiles -Folder $Folder -Prefix 'factory'
    foreach ($pair in @(@('factory_C.wim', 'factory_prev_C.wim'), @('factory_D.wim', 'factory_prev_D.wim'), @('factory.json', 'factory_prev.json'))) {
        $src = Join-Path $Folder $pair[0]
        if (Test-Path -LiteralPath $src) { Rename-Item -LiteralPath $src -NewName $pair[1] }
    }
    foreach ($pair in @(@('new_C.wim', 'factory_C.wim'), @('new_D.wim', 'factory_D.wim'), @('new.json', 'factory.json'))) {
        Rename-Item -LiteralPath (Join-Path $Folder $pair[0]) -NewName $pair[1]
    }
    return [bool]$cur.Complete   # true when a previous image became the fallback
}

function Get-CaptureEstimate([long]$UsedBytes, [long]$PreviousImageBytes) {
    # [Uncertain] DISM /Compress:max ratio for a finished WATCHOUT machine; 0.6
    # of the used space is a guess until the first real capture. When an image
    # exists already, its size (+15 %) is the better guide.
    $byUse = [long]($UsedBytes * 0.6)
    if ($PreviousImageBytes -gt 0) {
        $byPrev = [long]($PreviousImageBytes * 1.15)
        if ($byPrev -gt $byUse) { return $byPrev }
        return [long](($byPrev + $byUse) / 2)
    }
    return $byUse
}

function Get-CapturePlan([long]$FreeBytes, [long]$EstimateBytes, [long]$FallbackBytes) {
    # Ok: room for the new pair next to the existing ones.
    # DeleteFallback: room only once the older fallback pair is deleted (the
    #   current factory image is kept until the new one is complete).
    # NotEnough: not even then; the partition is too small for this image.
    $margin = [long]1GB
    if ($FreeBytes -ge ($EstimateBytes + $margin)) { return 'Ok' }
    if ($FallbackBytes -gt 0 -and ($FreeBytes + $FallbackBytes) -ge ($EstimateBytes + $margin)) { return 'DeleteFallback' }
    return 'NotEnough'
}

function Get-UnexpectedDataEntries([string[]]$Entries, [string[]]$Allowed) {
    # Top-level names on D: other than the WATCHOUT folder, the working
    # directory and NTFS/system folders. Anything else would become part of
    # the factory state (show data, assets, copies).
    $always = @('System Volume Information', '$RECYCLE.BIN', 'WO_DATA.tag')
    $ok = @($Allowed | Where-Object { $_ }) + $always
    return @($Entries | Where-Object { $e = $_; -not ($ok | Where-Object { $_ -ieq $e }) })
}

function Test-Target($Target) {
    # Problems in target.json; empty when usable.
    $p = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Target) { $p.Add('target.json is missing or unreadable.'); return $p.ToArray() }
    foreach ($part in 'System', 'Data') {
        if (-not $Target.PSObject.Properties[$part]) { $p.Add("target.json has no $part section."); continue }
        $s = $Target.$part
        if (-not $s.PSObject.Properties['PartitionGuid'] -or -not $s.PartitionGuid) { $p.Add("target.json: $part.PartitionGuid is empty.") }
    }
    return $p.ToArray()
}

# ===========================================================================
# WinPE side (not run by the tests)
# ===========================================================================

function Write-Log([string]$Message, [string]$Level = 'i') {
    $prefix = switch ($Level) { 'ok' { '  [OK]   ' } 'warn' { '  [WARN] ' } 'step' { "`n=== " } 'fatal' { '[FATAL] ' } default { '  [i]    ' } }
    $line = "$prefix$Message"
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $line" -Encoding UTF8 }
}

function Mount-RecoveryPartitions {
    # The WO_RECOVERY partition has the "no drive letter" GPT attribute, so
    # WinPE does not give it one by itself.
    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { "$($_.GptType)" -ieq $script:RecoveryGptType })) {
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        if ($v -and $v.FileSystemLabel -eq $script:RecoveryLabel -and -not (Test-DriveLetter $p.DriveLetter)) {
            try { $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop } catch { Write-Log "Could not give the recovery partition a letter: $($_.Exception.Message)" 'warn' }
        }
    }
}

function Get-TaggedRoots {
    # Volumes carrying WO_RECOVERY.tag: the internal partition and USB sticks.
    $roots = @()
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { Test-DriveLetter $_.DriveLetter })) {
        $r = "$($v.DriveLetter):\"
        if (Test-Path -LiteralPath (Join-Path $r 'WO_RECOVERY.tag')) { $roots += $r }
    }
    return $roots
}

function Get-InternalRoot([string[]]$Roots) {
    # The tagged volume that holds target.json and is not on a USB disk.
    foreach ($r in $Roots) {
        if (-not (Test-Path -LiteralPath (Join-Path $r 'target.json'))) { continue }
        $part = Get-Partition -DriveLetter $r.Substring(0, 1) -ErrorAction SilentlyContinue
        if (-not $part) { continue }
        $disk = Get-Disk -Number $part.DiskNumber -ErrorAction SilentlyContinue
        if ($disk -and "$($disk.BusType)" -ne 'USB') { return $r }
    }
    return $null
}

function Read-Target([string]$RootPath) {
    if (-not $RootPath) { return $null }
    $f = Join-Path $RootPath 'target.json'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return Get-Content -Raw -LiteralPath $f -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-PartitionLetter($Partition) {
    # Letter of a partition, assigning one when WinPE gave none.
    $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
    if (-not (Test-DriveLetter $p.DriveLetter)) {
        $p | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
        $p = Get-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber
    }
    return "$($p.DriveLetter)"
}

function Select-PartitionByHand([string]$Role) {
    # Fallback when target.json is missing or a partition was replaced (disk
    # swapped, RAID0 rebuilt). The operator picks; RESTORE is still typed later.
    $list = @(Get-Partition | Where-Object { "$($_.GptType)" -notin @($script:RecoveryGptType, $script:EspGptType, '{e3c9e316-0b5c-4db8-817d-f92df00215ae}') -and $_.Size -gt 1GB })
    Write-Host ''
    Write-Host "  Choose the $Role partition:"
    $i = 0
    foreach ($p in $list) {
        $i++
        $v = $p | Get-Volume -ErrorAction SilentlyContinue
        $label = if ($v) { "$($v.FileSystemLabel) $($v.FileSystem)" } else { '(no volume)' }
        $disk = Get-Disk -Number $p.DiskNumber
        Write-Host ("   {0,2}  disk {1} ({2}, {3})  partition {4}  {5}  {6}" -f $i, $p.DiskNumber, $disk.FriendlyName, $disk.BusType, $p.PartitionNumber, (Format-Bytes $p.Size), $label)
    }
    $a = Read-Host "  Number (empty = cancel)"
    $n = 0
    if (-not [int]::TryParse($a, [ref]$n) -or $n -lt 1 -or $n -gt $list.Count) { return $null }
    return $list[$n - 1]
}

function Resolve-Targets($Target, [switch]$AllowManual) {
    $all = @(Get-Partition -ErrorAction SilentlyContinue)
    $sys = $null; $data = $null
    if ($Target) {
        $sys = Select-PartitionByGuid $all $Target.System.PartitionGuid
        $data = Select-PartitionByGuid $all $Target.Data.PartitionGuid
    }
    if (-not $sys) {
        Write-Log 'The system partition (C:) recorded at install time was not found.' 'warn'
        if ($AllowManual) { $sys = Select-PartitionByHand 'system (C:)' }
    }
    if (-not $data) {
        Write-Log 'The data partition (RAID0, D:) recorded at install time was not found (rebuilt array?). It must exist and be formatted NTFS.' 'warn'
        if ($AllowManual) { $data = Select-PartitionByHand 'data (RAID0, D:)' }
    }
    if ($sys -and $data -and $sys.DiskNumber -eq $data.DiskNumber -and $sys.PartitionNumber -eq $data.PartitionNumber) {
        Write-Log 'System and data are the same partition. Refused.' 'warn'
        return $null
    }
    if (-not $sys -or -not $data) { return $null }
    return [pscustomobject]@{ System = $sys; Data = $data }
}

function Invoke-Dism([string[]]$Arguments, [string]$LogName) {
    # DISM writes its own detailed log next to ours; its console progress
    # stays on screen.
    $dismLog = Join-Path (Split-Path $script:LogFile) $LogName
    Write-Log "dism $($Arguments -join ' ')"
    & dism.exe @Arguments "/LogPath:$dismLog"
    $code = $LASTEXITCODE
    if ($code -ne 0) { Write-Log "DISM returned $code (log: $dismLog)." 'warn' }
    return $code
}

function Write-ExclusionFile([string]$Path) {
    # Same as DISM's defaults plus the recycle bin. Written explicitly
    # because a /ConfigFile replaces the default list.
    @(
        '[ExclusionList]',
        '\$ntfs.log',
        '\hiberfil.sys',
        '\pagefile.sys',
        '\swapfile.sys',
        '"\System Volume Information"',
        '\RECYCLER',
        '\$Recycle.Bin',
        '\Windows\CSC',
        '',
        '[CompressionExclusionList]',
        '*.mp3', '*.zip', '*.cab', '\WINDOWS\inf\*.pnf'
    ) | Set-Content -LiteralPath $Path -Encoding ASCII
}

function Set-DataRootNotIndexed([string]$Letter) {
    # Formatting D: drops the root folder's "not content indexed" attribute
    # set by the wizard (step 3.3, guide 10.15). Set it again. [Uncertain]
    # whether DISM already restored it from the image.
    $root = "${Letter}:\"
    $flag = [IO.FileAttributes]::NotContentIndexed
    $attr = [IO.File]::GetAttributes($root)
    if (($attr -band $flag) -ne $flag) { [IO.File]::SetAttributes($root, ($attr -bor $flag)) }
    if (([IO.File]::GetAttributes($root) -band $flag) -eq $flag) { Write-Log "${Letter}: contents indexing off" 'ok' }
    else { Write-Log "${Letter}: contents indexing could not be turned off; the wizard's check will show it." 'warn' }
}

function Write-LastResult([string]$RootPath, [string]$Action, [string]$Status, [string]$Name, [datetime]$Started, [string]$Message) {
    $r = [ordered]@{
        Action    = $Action
        Status    = $Status
        Name      = $Name
        StartedAt = $Started.ToString('o')
        EndedAt   = (Get-Date).ToString('o')
        Message   = $Message
        Log       = $(if ($script:LogFile) { Split-Path $script:LogFile -Leaf } else { '' })
    }
    $json = ConvertTo-Json -InputObject $r -Depth 3
    [IO.File]::WriteAllText((Join-Path $RootPath 'Logs\last-result.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Start-Log([string]$RootPath, [string]$Action) {
    $dir = Join-Path $RootPath 'Logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $script:LogFile = Join-Path $dir ("{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $Action)
}

function Read-Typed([string]$Word) {
    $a = Read-Host "  Type $Word to continue (anything else cancels)"
    return ($a -ceq $Word)
}

function Wait-OrCancel([int]$Seconds, [string]$What) {
    # True = go on; a key press cancels (back to the menu).
    Write-Host ''
    Write-Host "  $What in $Seconds seconds. Press any key for the menu instead."
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); return $false }
        Start-Sleep -Milliseconds 200
    }
    return $true
}

function Invoke-Capture([string]$RecRoot, $Target, [string]$Name, [switch]$FromWizard) {
    $started = Get-Date
    Start-Log $RecRoot 'Capture'
    Write-Log "Capture factory image '$Name'" 'step'
    try {
        if (-not (Test-ImageName $Name)) { throw "Image name '$Name' is not valid (letters, digits, . _ -)." }
        $t = Resolve-Targets $Target
        if (-not $t) { throw 'C: or D: not found by the GUIDs in target.json. Run "Install the recovery boot" in the wizard again.' }
        $c = Get-PartitionLetter $t.System
        $d = Get-PartitionLetter $t.Data
        $cv = Get-Volume -DriveLetter $c
        $dv = Get-Volume -DriveLetter $d
        Write-Log "System: ${c}: $($cv.FileSystemLabel), used $(Format-Bytes ($cv.Size - $cv.SizeRemaining))"
        Write-Log "Data:   ${d}: $($dv.FileSystemLabel), used $(Format-Bytes ($dv.Size - $dv.SizeRemaining))"
        if (-not (Test-Path -LiteralPath "${c}:\Windows\System32\config\SYSTEM")) { throw "${c}: does not hold Windows. Refused." }

        # D: must hold only the WATCHOUT folder and the working directory.
        $allowed = @()
        foreach ($p in 'WatchoutPath', 'WorkingDirectory') {
            $v = "$(Get-Prop $Target.Data $p)"
            if ($v) { $allowed += Split-Path -Leaf $v }
        }
        $entries = @(Get-ChildItem -LiteralPath "${d}:\" -Force | ForEach-Object { $_.Name })
        $extra = @(Get-UnexpectedDataEntries -Entries $entries -Allowed $allowed)
        if ($extra.Count -gt 0) { throw "D: holds more than the WATCHOUT folder and the working directory: $($extra -join ', '). It would become factory state. Move it away, then capture again." }

        $imgDir = Join-Path $RecRoot 'Images'
        if (-not (Test-Path -LiteralPath $imgDir)) { New-Item -ItemType Directory -Path $imgDir | Out-Null }
        Remove-ImageSet -Folder $imgDir -Prefix 'new'   # leftovers of an interrupted capture

        $cur = Get-ImageSetFiles -Folder $imgDir -Prefix 'factory'
        $prev = Get-ImageSetFiles -Folder $imgDir -Prefix 'factory_prev'
        $used = [long](($cv.Size - $cv.SizeRemaining) + ($dv.Size - $dv.SizeRemaining))
        $estimate = Get-CaptureEstimate -UsedBytes $used -PreviousImageBytes $cur.Bytes
        $rv = Get-Volume -DriveLetter $RecRoot.Substring(0, 1)
        $plan = Get-CapturePlan -FreeBytes $rv.SizeRemaining -EstimateBytes $estimate -FallbackBytes $prev.Bytes
        Write-Log "Recovery partition free $(Format-Bytes $rv.SizeRemaining), estimated image $(Format-Bytes $estimate) [Uncertain estimate]: $plan"
        if ($plan -eq 'NotEnough') { throw 'Not enough room on the recovery partition, even without the fallback image. A larger partition is needed (made in Windows Setup), or copy the images off and delete them.' }
        if ($plan -eq 'DeleteFallback') { Write-Log 'Deleting the older fallback image first to make room.' 'warn'; Remove-ImageSet -Folder $imgDir -Prefix 'factory_prev' }

        if (-not $FromWizard) {
            Write-Host ''
            Write-Host "  Captures ${c}: and ${d}: as the new factory image '$Name'. The current one becomes the fallback."
            if (-not (Read-Typed 'CAPTURE')) { Write-LastResult $RecRoot 'Capture' 'Cancelled' $Name $started 'Cancelled by the operator.'; return }
        }

        $cfg = Join-Path $env:TEMP 'wo-capture.ini'
        Write-ExclusionFile $cfg
        foreach ($part in @(@{ L = $c; F = 'new_C.wim'; Tag = 'C' }, @{ L = $d; F = 'new_D.wim'; Tag = 'D' })) {
            $code = Invoke-Dism @('/Capture-Image', "/ImageFile:$(Join-Path $imgDir $part.F)", "/CaptureDir:$($part.L):\", "/Name:${Name}_$($part.Tag)",
                                  '/Compress:max', '/CheckIntegrity', '/Verify', "/ConfigFile:$cfg") "dism_capture_$($part.Tag).log"
            if ($code -ne 0) { throw "Capture of $($part.L): failed (DISM $code). The existing factory image is kept." }
            Write-Log "$($part.L): captured" 'ok'
        }

        $meta = [ordered]@{
            SchemaVersion = 1
            Name          = $Name
            CapturedAt    = (Get-Date).ToString('o')
            Computer      = "$(Get-Prop $Target 'Computer')"
            SystemLabel   = "$($cv.FileSystemLabel)"
            DataLabel     = "$($dv.FileSystemLabel)"
            UsedBytes     = $used
            Files         = @('factory_C.wim', 'factory_D.wim')
        }
        [IO.File]::WriteAllText((Join-Path $imgDir 'new.json'), (ConvertTo-Json -InputObject $meta -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        $hadPrevious = Invoke-ImageRotation -Folder $imgDir
        $set = Get-ImageSetFiles -Folder $imgDir -Prefix 'factory'
        Write-Log "Factory image '$Name' saved ($(Format-Bytes $set.Bytes))$(if ($hadPrevious) { '; the previous one is the fallback' })." 'ok'
        Write-LastResult $RecRoot 'Capture' 'Completed' $Name $started "Factory image saved ($(Format-Bytes $set.Bytes))."
    }
    catch {
        Write-Log $_.Exception.Message 'fatal'
        Write-LastResult $RecRoot 'Capture' 'Failed' $Name $started $_.Exception.Message
    }
}

function Invoke-Restore([string]$RecRoot, $Target, $Set) {
    $started = Get-Date
    # Log on the internal partition, or on the stick the image came from.
    $logRoot = $(if ($RecRoot) { $RecRoot } else { [IO.Path]::GetPathRoot($Set.Folder) })
    Start-Log $logRoot 'Restore'
    Write-Log "Restore factory image '$($Set.Name)' from $($Set.Folder)" 'step'
    try {
        $from = "$(Get-Prop $Set.Info 'Computer')"; $here = "$(Get-Prop $Target 'Computer')"
        if ($from -and $here -and $from -ne $here) { Write-Log "This image was captured on $from, this machine is $here." 'warn' }
        $t = Resolve-Targets $Target -AllowManual
        if (-not $t) { throw 'No system/data partition chosen. Nothing was changed.' }
        $c = Get-PartitionLetter $t.System
        $d = Get-PartitionLetter $t.Data
        $sysLabel = 'Windows'; $dataLabel = 'Media'; $au = 65536
        if ($Target) {
            if ("$(Get-Prop $Target.System 'Label')") { $sysLabel = "$($Target.System.Label)" }
            if ("$(Get-Prop $Target.Data 'Label')") { $dataLabel = "$($Target.Data.Label)" }
            if ([int]("0$(Get-Prop $Target.Data 'AllocationUnitSize')") -gt 0) { $au = [int]$Target.Data.AllocationUnitSize }
        }

        Write-Host ''
        Write-Host "  Image:   $($Set.Name)  (captured $(Get-Prop $Set.Info 'CapturedAt'), $(Format-Bytes $Set.Bytes))"
        Write-Host "  System:  disk $($t.System.DiskNumber) partition $($t.System.PartitionNumber), $(Format-Bytes $t.System.Size)  -> ${c}:"
        Write-Host "  Data:    disk $($t.Data.DiskNumber) partition $($t.Data.PartitionNumber), $(Format-Bytes $t.Data.Size)  -> ${d}:"
        Write-Host ''
        Write-Host "  EVERYTHING on ${c}: AND ${d}: IS ERASED (Windows, WATCHOUT, shows, assets)."
        Write-Host '  Both are formatted and get the factory image back. Upload shows and assets again afterwards.'
        if (-not (Read-Typed 'RESTORE')) { Write-LastResult $logRoot 'Restore' 'Cancelled' $Set.Name $started 'Cancelled by the operator.'; return }

        foreach ($part in @(@{ P = $t.System; L = $c; Label = $sysLabel; Au = 4096; Wim = $Set.C; Tag = 'C' },
                            @{ P = $t.Data; L = $d; Label = $dataLabel; Au = $au; Wim = $Set.D; Tag = 'D' })) {
            Write-Log "Formatting $($part.L): (NTFS '$($part.Label)')"
            # Quick format keeps the partition and its GUID: the boot entry stays valid.
            Format-Volume -DriveLetter $part.L -FileSystem NTFS -NewFileSystemLabel $part.Label -AllocationUnitSize $part.Au -Force -Confirm:$false | Out-Null
            $code = Invoke-Dism @('/Apply-Image', "/ImageFile:$($part.Wim)", '/Index:1', "/ApplyDir:$($part.L):\", '/CheckIntegrity', '/Verify') "dism_apply_$($part.Tag).log"
            if ($code -ne 0) { throw "Applying the image to $($part.L): failed (DISM $code). $($part.L): is now incomplete: run Restore again, or from the USB stick." }
            Write-Log "$($part.L): restored" 'ok'
        }
        Set-DataRootNotIndexed $d
        if (-not (Test-Path -LiteralPath "${c}:\Windows\System32\config\SYSTEM")) { throw "${c}:\Windows is missing after the restore." }
        Write-Log 'Factory image restored. Restart; if Windows does not start, use "Repair boot files" here.' 'ok'
        Write-LastResult $logRoot 'Restore' 'Completed' $Set.Name $started 'Factory image restored.'
    }
    catch {
        Write-Log $_.Exception.Message 'fatal'
        Write-LastResult $logRoot 'Restore' 'Failed' $Set.Name $started $_.Exception.Message
    }
}

function Repair-BootFiles($Target) {
    # bcdboot rebuilds the Windows Boot Manager files on the ESP from C:\Windows.
    # The recovery entry may be lost; run "Install the recovery boot" in the
    # wizard again afterwards.
    $t = Resolve-Targets $Target -AllowManual
    if (-not $t) { Write-Host '  Cancelled.'; return }
    $c = Get-PartitionLetter $t.System
    $esp = Get-Partition -DiskNumber $t.System.DiskNumber | Where-Object { "$($_.GptType)" -ieq $script:EspGptType } | Select-Object -First 1
    if (-not $esp) { Write-Host '  No EFI system partition on the system disk.'; return }
    $s = Get-PartitionLetter $esp
    & bcdboot.exe "${c}:\Windows" /s "${s}:" /f UEFI
    Write-Host "  bcdboot returned $LASTEXITCODE. Afterwards run the wizard step 'Install the recovery boot' again."
}

function Show-Menu([string]$RecRoot, $Target, [string[]]$Roots) {
    while ($true) {
        $sets = @(Find-ImageSets $Roots)
        Clear-Host
        Write-Host '  ========================================================'
        Write-Host '   WATCHOUT server - factory recovery'
        Write-Host '  ========================================================'
        if ($Target) { Write-Host "   Machine: $(Get-Prop $Target 'Computer')" } else { Write-Host '   No target.json found: partitions are chosen by hand.' }
        Write-Host "   Images:"
        $i = 0
        foreach ($s in $sets) { $i++; Write-Host ("    [{0}] {1,-34} {2}  {3}" -f $i, $s.Name, (Format-Bytes $s.Bytes), $s.Folder) }
        if ($i -eq 0) { Write-Host '    none' }
        Write-Host ''
        Write-Host '   1  Restore a factory image (ERASES C: and D:)'
        Write-Host '   2  Capture C: and D: as the new factory image'
        Write-Host '   3  Last result'
        Write-Host '   4  Repair boot files (only if Windows does not start after a restore)'
        Write-Host '   5  Command prompt'
        Write-Host '   6  Restart'
        $o = Read-Host '  Choice'
        switch ($o) {
            '1' {
                if ($sets.Count -eq 0) { Read-Host '  No image found. Enter'; break }
                $pick = 1
                if ($sets.Count -gt 1) {
                    $a = Read-Host "  Image number [1-$($sets.Count)], Enter = 1 (the current factory image)"
                    if ($a) { if (-not [int]::TryParse($a, [ref]$pick) -or $pick -lt 1 -or $pick -gt $sets.Count) { break } }
                }
                Invoke-Restore $RecRoot $Target $sets[$pick - 1]
                Read-Host '  Enter'
            }
            '2' {
                if (-not $RecRoot) { Read-Host '  Capture needs the internal recovery partition (target.json). Enter'; break }
                $n = Read-Host '  Image name (e.g. WO7.8.4_W11-25H2_2026-11-20)'
                Invoke-Capture $RecRoot $Target $n
                Read-Host '  Enter'
            }
            '3' {
                foreach ($r in $Roots) { $f = Join-Path $r 'Logs\last-result.json'; if (Test-Path -LiteralPath $f) { Write-Host "  $f"; Get-Content -LiteralPath $f | Write-Host } }
                Read-Host '  Enter'
            }
            '4' { Repair-BootFiles $Target; Read-Host '  Enter' }
            '5' { Write-Host '  Type exit to come back.'; & cmd.exe }
            '6' { & wpeutil.exe reboot; return }
        }
    }
}

function Start-Recovery {
    Mount-RecoveryPartitions
    $roots = @(Get-TaggedRoots)
    $rec = Get-InternalRoot $roots
    $target = Read-Target $rec
    foreach ($p in (Test-Target $target)) { Write-Host "  [WARN] $p" }
    if (@(Test-Target $target).Count -gt 0) { $target = $null }

    # A capture requested by the wizard (confirmed there with CAPTURE).
    if ($rec) {
        $pending = Join-Path $rec 'pending.json'
        if (Test-Path -LiteralPath $pending) {
            $req = $null
            try { $req = Get-Content -Raw -LiteralPath $pending -Encoding UTF8 | ConvertFrom-Json } catch { }
            # Removed first: a crash must not start the capture again at every boot.
            Remove-Item -LiteralPath $pending -Force
            if ("$(Get-Prop $req 'Action')" -eq 'Capture' -and $target) {
                $name = "$(Get-Prop $req 'Name')"
                if (Wait-OrCancel 15 "Capture of the factory image '$name' (requested by the setup wizard) starts") {
                    Invoke-Capture $rec $target $name -FromWizard
                    if (Wait-OrCancel 15 'Restart into Windows') { & wpeutil.exe reboot; return }
                }
            }
        }
    }
    Show-Menu $rec $target $roots
}

if ($MyInvocation.InvocationName -ne '.') { Start-Recovery }
