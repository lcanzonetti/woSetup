#requires -RunAsAdministrator
<#
.SYNOPSIS
    WATCHOUT 6 display/production server setup automation for Windows 11 Pro
    64-bit (24H2/25H2). Applies the Dataton "WATCHOUT Windows 10 Enterprise
    Tweaking Guide" (doc. 3749, rev 1.3) as completely as Windows 11 allows:
    chapter 7 Group Policies, chapter 10 Windows settings, chapter 11
    services, chapter 12 registry values and chapter 13 scheduled tasks,
    plus driver lockdown, power, NIC and notification hardening.

.DESCRIPTION
    WATCHOUT 6 vs WATCHOUT 7 - WHAT IS DIFFERENT HERE
      * Auto-start: WATCHOUT 6's display software (WATCHPOINT.exe) is a
        normal desktop application, not a set of services. The script creates
        the guide's logon task (13.1): run with highest privileges (needed for
        remote software upgrades), working directory = install folder, and NO
        3-day execution time limit (the Task Scheduler default would kill
        WATCHPOINT after 72 hours of uptime).
      * Firewall: WATCHOUT 6 does not create its own firewall rules (WATCHOUT
        7 does). Default = firewall off, as both the guide (7.1) and the
        WATCHOUT 6.7 User Guide say. -KeepFirewall instead adds program rules
        for WATCHPOINT, WATCHMAKER and the Dynamic Image Server.
      * Services: the guide's chapter 11 list is applied (Disabled), with the
        previous start types saved to a CSV so they can be restored.
      * Network bindings: guide 10.10 (everything except IPv4 unbound on
        physical adapters) is applied.
      * Registry: the full chapter 12 set that still applies, including the
        DirectShow thread priority and 100% DPI values used by WATCHOUT 6.

    TWO PHASES, matching the install routine:

      -Phase PreUpdate      Run right after Windows is installed, BEFORE
                            Windows Update and BEFORE installing drivers
                            (network cable unplugged).
                              * SearchOrderConfig = 0  (no driver download on new hardware)
                              * "Do not include drivers with Windows Updates" policy
                              * Driver-search prompt off
                            Windows Update is deliberately left ON here.

      -Phase PostInstall    Run AFTER every update and driver is installed,
                            after the debloat and after the WATCHOUT 6 install.
                              * Power plan, hibernation, USB selective suspend, PCIe ASPM
                              * NIC power management, EEE off, IPv4-only bindings
                              * Network location Private, discovery flyout off
                              * Notifications off
                              * Dataton guide chapter 7 GPOs (Win11-adapted) + Win11 additions
                              * Windows Update fully disabled (policies, version pin, no notifications,
                                BITS/wuauserv/UsoSvc and update tasks off; -KeepUpdateService to skip)
                              * Guide ch. 10 settings: UAC never notify, visual effects,
                                Remote Assistance off, no sounds, defrag schedule off,
                                taskbar badges off, USB notifications off
                              * Guide ch. 11 services disabled (CSV backup)
                              * Guide ch. 12 registry values
                              * Guide ch. 13.1: WATCHPOINT auto-start task (Display role).
                                Guide 13.2 (SSD retrim task at logon) is deliberately
                                NOT applied; NTFS still sends TRIM as files are deleted.
                              * Defender: -DefenderMode Off (default), Exclusions or Skip

    HOW POLICIES ARE WRITTEN
      Policy-type settings are queued, de-duplicated (last definition of a
      Scope+Key+Name wins) and imported in one go with LGPO.exe /t when
      LGPO.exe sits next to the script, so they show as "Configured" in
      gpedit.msc. The existing Local GPO is backed up first (LGPO /b); roll
      back with:  LGPO.exe /g "<backup folder>\{GUID}"
      Without LGPO.exe the same values are written directly to the registry.

    PER-USER SETTINGS
      * User-scope policies (via LGPO) apply to EVERY local account.
      * Non-policy HKCU preferences (sounds, visual effects, DPI, badges, the
        WATCHPOINT logon task) go to the account that RUNS the script: run it
        elevated FROM THE SHOW (auto-logon) ACCOUNT.

    MANUAL STEPS THE SCRIPT CANNOT DO
      * Tamper Protection OFF (required for -DefenderMode Off).
      * Guide 7.2 "User cannot change location" (secpol.msc).
      * Startup apps, Wake-on-LAN, display Scale check, vendor services
        (Intel HDCP/HECI, NVIDIA telemetry on old drivers): see the checklist.

    ROLLBACK
      * Policies: the LGPO backup folder (LGPO_Backup_<timestamp>).
      * Services: Services_Backup_<timestamp>.csv + the restore line printed
        at the end of the services step.
      * Bindings: Enable-NetAdapterBinding -Name <adapter> -AllBindings
      * Everything else: your disk image.

    IDEMPOTENT
      Safe to re-run with the SAME options. Switching an option later does not
      remove what an earlier run applied (see the checklist).

    LOG
      Full transcript saved next to the script as WO6-Setup_<phase>_<timestamp>.log

.PARAMETER Phase
    PreUpdate or PostInstall (see above).

.PARAMETER Role
    Display (default)  Display server: everything, including the WATCHPOINT
                       auto-start task and the guide's "only on display
                       server" user policies.
    Production         WATCHMAKER production PC: no WATCHPOINT task, no
                       Ctrl+Alt+Del / thumbnail policies, plus
                       Win32PrioritySeparation 0x28 (guide 12.3).

.PARAMETER DefenderMode
    Off (default)  Guide 7.4.8: real-time protection disabled by policy.
                   Requires Tamper Protection OFF first. Exclusions are always
                   added too, as a fallback.
    Exclusions     Defender stays on; WATCHOUT folders and processes excluded.
    Skip           Defender untouched.

.PARAMETER KeepFirewall
    Keep Windows Firewall on (skip guide 7.1) and add inbound allow rules for
    WATCHPOINT.exe, WATCHMAKER.exe and ImageServer.exe on all profiles.

.PARAMETER KeepServices
    Skip the guide's chapter 11 service changes entirely.

.PARAMETER KeepService
    Service names to leave untouched while applying the rest of chapter 11,
    e.g. -KeepService TermService,SessionEnv,UmRdpService to keep Remote
    Desktop for maintenance, or bthserv for Bluetooth peripherals.

.PARAMETER KeepAdapterBindings
    Skip guide 10.10 (unbinding everything except IPv4). Use it if the
    machine needs file shares (Client for Microsoft Networks / File and
    Printer Sharing) or IPv6.

.PARAMETER PinVersion
    Feature version to pin Windows Update to (e.g. 25H2). Default: installed version.

.PARAMETER KeepUpdateService
    Do NOT disable BITS / Windows Update / Update Orchestrator and their
    tasks (default: disabled, as WinUtil's "Disable all updates" and the
    guide's chapter 11 do). Use it on a machine you still want to patch.

.PARAMETER ForcePcieLinkSpeed
    Guide 12.2 ForcePcieLinkSpeed = 3 on every display adapter. Read only by
    AMD GPU drivers; the guide warns some AMD drivers crash at startup with
    it. Off by default.

.PARAMETER StartDelay
    Seconds WATCHPOINT waits before starting (its -Delay option). Default 8.
    Raise it if another program starting later still knocks WATCHPOINT out of
    full screen; -StartDelay 0 removes the delay.

.PARAMETER WatchoutPath
    WATCHOUT 6 install folder (the one containing WATCHPOINT.exe).
    Auto-detected if omitted (Uninstall registry, then C:\WATCHOUT 6,
    D:\WATCHOUT 6, D:\WATCHOUT).

.PARAMETER ShowsPath
    Custom location of WATCHPOINT's "Shows" folder. Passed to WATCHPOINT as
    -ShowsPath and used for the Defender exclusion. Default: <install>\Shows.

.PARAMETER Audit
    Read-only check, with the same phase and options as a real run: every
    setting, registry value, policy, service, task and adapter property the
    phase applies is reported as [SET], [NOT SET] or [N/A]. Changes nothing.

.PARAMETER ResultPath
    Optional. File to write a JSON summary of the run to (phase, effective
    options, status, warnings, backups with restore commands, LGPO use,
    transcript path). Used by the setup wizard instead of parsing the console
    text. Writing it never changes what the run does.

.EXAMPLE
    .\WO6-Setup.ps1 -Phase PreUpdate
.EXAMPLE
    .\WO6-Setup.ps1 -Phase PostInstall
.EXAMPLE
    .\WO6-Setup.ps1 -Phase PostInstall -Audit
.EXAMPLE
    .\WO6-Setup.ps1 -Phase PostInstall -ShowsPath 'E:\Shows' -StartDelay 15
.EXAMPLE
    .\WO6-Setup.ps1 -Phase PostInstall -Role Production -KeepAdapterBindings
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('PreUpdate', 'PostInstall')]
    [string]$Phase,

    [ValidateSet('Display', 'Production')]
    [string]$Role = 'Display',

    [ValidateSet('Off', 'Exclusions', 'Skip')]
    [string]$DefenderMode = 'Off',

    [switch]$KeepFirewall,
    [switch]$KeepServices,
    [string[]]$KeepService = @(),
    [switch]$KeepAdapterBindings,

    [string]$PinVersion,
    [switch]$KeepUpdateService,
    [switch]$ForcePcieLinkSpeed,

    # Default 8 s: WATCHPOINT starts after other logon programs have settled,
    # so they cannot pull it out of full screen (WATCHOUT 6 User Guide, -Delay).
    [ValidateRange(0, 600)]
    [int]$StartDelay = 8,

    [string]$WatchoutPath,
    [string]$ShowsPath,

    [switch]$Audit,

    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$Stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:TranscriptPath = Join-Path $ScriptDir "WO6-Setup_${Phase}$(if ($Audit) { '_Audit' })_$Stamp.log"
Start-Transcript -Path $script:TranscriptPath | Out-Null

# Warnings are collected so the final summary shows what needs attention.
$script:Warnings = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$msg) { $script:CurrentSection = $msg; Write-Host "`n=== $msg" -ForegroundColor Cyan }
# In audit mode nothing is applied, so the "[OK] <applied>" lines are not printed.
function Write-Ok  ([string]$msg) { if ($script:AuditMode) { return }; Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:Warnings.Add($msg) }

# ---------------------------------------------------------------------------
# Audit mode (-Audit): read-only. Every place that would change the machine
# checks the current value instead and reports it as [SET] (already as this
# script applies it with these options), [NOT SET] (a real run would change
# it) or [N/A] (not applied with these options or on this hardware). The
# expected values come from the same code a real run uses, so audit and
# apply cannot drift apart. Nothing is written except the transcript and the
# optional -ResultPath file.
# ---------------------------------------------------------------------------
$script:AuditMode      = [bool]$Audit
$script:CurrentSection = ''
$script:AuditItems     = New-Object System.Collections.Generic.List[object]

function Write-Audit {
    param(
        [ValidateSet('Set', 'NotSet', 'NA')] [string]$State,
        [string]$Item,
        [string]$Detail
    )
    $suffix = if ($Detail) { " ($Detail)" } else { '' }
    switch ($State) {
        'Set'    { Write-Host "  [SET]     $Item" -ForegroundColor Green }
        'NotSet' { Write-Host "  [NOT SET] $Item$suffix" -ForegroundColor Yellow }
        'NA'     { Write-Host "  [N/A]     $Item$suffix" -ForegroundColor DarkGray }
    }
    $script:AuditItems.Add([pscustomobject]@{ Section = $script:CurrentSection; Item = $Item; State = $State; Detail = $Detail })
}

function Format-AuditValue([object]$Value) {
    # Text form used both to compare and to display values.
    if ($null -eq $Value) { return '(none)' }
    if ($Value -is [byte[]]) { return (($Value | ForEach-Object { $_.ToString('X2') }) -join ' ') }
    return [string]$Value
}

function Test-RegValue {
    # Audit: compares one registry value with what the script writes.
    param([string]$Path, [string]$Name, [object]$Expected, [string]$Label)
    $item = "$Path\$Name = $(Format-AuditValue $Expected)"
    if ($Label) { $item = "$Label [$item]" }
    $current = $null
    $props = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
    if ($props -and $props.PSObject.Properties[$Name]) { $current = $props.$Name }
    if ($null -eq $current) { Write-Audit 'NotSet' $item 'current: missing'; return }
    if ((Format-AuditValue $current) -eq (Format-AuditValue $Expected)) { Write-Audit 'Set' $item }
    else { Write-Audit 'NotSet' $item "current: $(Format-AuditValue $current)" }
}

function Test-ServiceStartType([string]$Name, [string]$Label, [string]$Expected = 'Disabled') {
    # Audit: service start type (Win32_Service StartMode: Auto/Manual/Disabled).
    $item = "$Label ($Name) = $Expected"
    $svc = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Audit 'NA' $item 'service not present'; return }
    if ($svc.StartMode -eq $Expected) { Write-Audit 'Set' $item }
    else { Write-Audit 'NotSet' $item "current: $($svc.StartMode)" }
}

function Write-AuditSummary {
    Write-Step 'Audit summary'
    $set    = @($script:AuditItems | Where-Object { $_.State -eq 'Set' }).Count
    $notSet = @($script:AuditItems | Where-Object { $_.State -eq 'NotSet' }).Count
    $na     = @($script:AuditItems | Where-Object { $_.State -eq 'NA' }).Count
    $colour = if ($notSet -eq 0) { 'Green' } else { 'Yellow' }
    Write-Host "  Set: $set   Not set: $notSet   N/A: $na" -ForegroundColor $colour
    if ($script:Warnings.Count -gt 0) {
        Write-Host "  $($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
    }
    Write-Host '  Audit only: nothing was changed.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Run record for the optional -ResultPath file. Backups and restore commands
# are recorded where they are produced; nothing here changes the machine.
# ---------------------------------------------------------------------------
$script:Backups      = New-Object System.Collections.Generic.List[object]
$script:LgpoUsed     = $false
$script:LgpoTextFile = $null
$script:Fatal        = $null
$script:RunStarted   = Get-Date

function Add-BackupRecord([string]$Kind, [string]$Path, [string]$Restore) {
    $script:Backups.Add([pscustomobject]@{ Kind = $Kind; Path = $Path; Restore = $Restore })
}

function Get-RunParameters {
    # Effective values, defaults included; switches as true/false.
    # A [pscustomobject], not an [ordered] dictionary: a dictionary returned
    # from a function arrives wrapped in a PSObject, and Windows PowerShell
    # 5.1's ConvertTo-Json then fails with "Argument types do not match".
    [pscustomobject]@{
        Phase               = $Phase
        Audit               = [bool]$Audit
        Role                = $Role
        DefenderMode        = $DefenderMode
        KeepFirewall        = [bool]$KeepFirewall
        KeepServices        = [bool]$KeepServices
        KeepService         = @($KeepService)
        KeepAdapterBindings = [bool]$KeepAdapterBindings
        PinVersion          = $PinVersion
        KeepUpdateService   = [bool]$KeepUpdateService
        ForcePcieLinkSpeed  = [bool]$ForcePcieLinkSpeed
        StartDelay          = $StartDelay
        WatchoutPath        = $WatchoutPath
        ShowsPath           = $ShowsPath
    }
}

function Write-ResultFile([string]$Status) {
    # Only with -ResultPath. A failure here prints a line and is otherwise
    # ignored: the result file must never change the outcome of the run.
    if (-not $ResultPath) { return }
    try {
        $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath)
        $result = [ordered]@{
            schemaVersion = 2
            script        = 'WO6-Setup.ps1'
            phase         = $Phase
            mode          = $(if ($script:AuditMode) { 'Audit' } else { 'Apply' })
            status        = $Status
            fatal         = $script:Fatal
            startedAt     = $script:RunStarted.ToString('o')
            endedAt       = (Get-Date).ToString('o')
            computerName  = $env:COMPUTERNAME
            userName      = "$env:USERDOMAIN\$env:USERNAME"
            parameters    = Get-RunParameters
            warnings      = [string[]]$script:Warnings.ToArray()
            backups       = [object[]]$script:Backups.ToArray()
            audit         = [object[]]$script:AuditItems.ToArray()
            lgpo          = [pscustomobject]@{ used = $script:LgpoUsed; textFile = $script:LgpoTextFile }
            transcript    = $script:TranscriptPath
        }
        $json = ConvertTo-Json -InputObject $result -Depth 5
        # UTF-8 without BOM.
        [IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "  [i]    Result file: $out" -ForegroundColor DarkGray
    }
    catch { Write-Host "  [WARN] Result file not written: $($_.Exception.Message)" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------------
# Policy collector. Every policy is queued with Add-Policy and applied once
# by Invoke-PolicyApply. Re-adding the same Scope+Key+Name replaces the
# earlier entry, so overlapping sections (e.g. notifications defined both in
# the routine and in the guide) never produce duplicate or conflicting lines.
# ---------------------------------------------------------------------------
$script:Policies = New-Object System.Collections.Generic.List[object]
function Add-Policy {
    param(
        [ValidateSet('Computer', 'User')] [string]$Scope,
        [string]$Key,      # relative to HKLM / HKCU, e.g. Software\Policies\...
        [string]$Name,
        [object]$Value,    # int for DWORD, string for SZ
        [string]$Comment,
        [ValidateSet('DWORD', 'SZ')] [string]$Type = 'DWORD'
    )
    $dup = $script:Policies | Where-Object { $_.Scope -eq $Scope -and $_.Key -eq $Key -and $_.Name -eq $Name } | Select-Object -First 1
    if ($dup) { [void]$script:Policies.Remove($dup) }
    $script:Policies.Add([pscustomobject]@{ Scope = $Scope; Key = $Key; Name = $Name; Value = $Value; Comment = $Comment; Type = $Type })
}

function Set-RegDword {
    # Direct registry write, creating the key if needed. Used for non-policy
    # settings and as the LGPO fallback.
    param([string]$Path, [string]$Name, [int]$Value)
    if ($script:AuditMode) { Test-RegValue -Path $Path -Name $Name -Expected $Value; return }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-RegValue {
    # String or binary registry write (Set-ItemProperty, exactly as before);
    # in audit mode the value is checked instead. String values keep the type
    # they already have.
    param([string]$Path, [string]$Name, [object]$Value, [ValidateSet('String', 'Binary')] [string]$Type = 'String')
    if ($script:AuditMode) { Test-RegValue -Path $Path -Name $Name -Expected $Value; return }
    if ($Type -eq 'Binary') { Set-ItemProperty -Path $Path -Name $Name -Type Binary -Value $Value }
    else { Set-ItemProperty -Path $Path -Name $Name -Value $Value }
}

function ConvertTo-LgpoText {
    # Renders queued policies in LGPO.exe text format: comment / Scope / Key /
    # Value name / DWORD:<decimal> or SZ:<string>, Computer entries first,
    # then User, for a readable text file. Pure: no file, registry or LGPO.exe
    # access, so it can be unit-tested (Pester) on any machine.
    param([object[]]$Policies)
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in ($Policies | Sort-Object { $_.Scope -ne 'Computer' })) {
        [void]$sb.AppendLine("; $($p.Comment)")
        [void]$sb.AppendLine($p.Scope)
        [void]$sb.AppendLine($p.Key)
        [void]$sb.AppendLine($p.Name)
        # LGPO text format: DWORD:<decimal> or SZ:<string>
        [void]$sb.AppendLine("$($p.Type):$($p.Value)")
        [void]$sb.AppendLine()
    }
    return $sb.ToString()
}

function Test-QueuedPolicies {
    # Audit: each queued policy is compared with the value Windows reads:
    # HKLM for Computer policies, HKCU of the running account for User
    # policies. After an LGPO import and gpupdate both land there; User
    # policies reach other accounts at their next sign-in.
    Write-Step "Policies ($($script:Policies.Count) settings)"
    foreach ($p in ($script:Policies | Sort-Object { $_.Scope -ne 'Computer' })) {
        $root = if ($p.Scope -eq 'Computer') { 'HKLM:\' } else { 'HKCU:\' }
        Test-RegValue -Path ($root + $p.Key) -Name $p.Name -Expected $p.Value -Label $p.Comment
    }
}

function Invoke-PolicyApply {
    if ($script:Policies.Count -eq 0) { return }
    if ($script:AuditMode) { Test-QueuedPolicies; return }
    Write-Step "Applying $($script:Policies.Count) policy settings"
    $lgpo = Join-Path $ScriptDir 'LGPO.exe'

    if (Test-Path $lgpo) {
        # 1. Backup current Local GPO.
        $backup = Join-Path $ScriptDir "LGPO_Backup_$Stamp"
        New-Item -ItemType Directory -Path $backup | Out-Null
        & $lgpo /b $backup | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "LGPO backup failed (exit $LASTEXITCODE)." }
        Write-Ok "Local GPO backed up to $backup"
        # LGPO /b writes the backup into a {GUID} subfolder; /g needs that path.
        $guidDir = @(Get-ChildItem -Path $backup -Directory -ErrorAction SilentlyContinue) | Select-Object -First 1
        $restoreDir = if ($guidDir) { $guidDir.FullName } else { "$backup\{GUID}" }
        Add-BackupRecord -Kind 'LgpoBackup' -Path $backup -Restore "LGPO.exe /g `"$restoreDir`""

        # 2. Render LGPO text format (see ConvertTo-LgpoText).
        $txt = Join-Path $ScriptDir "lgpo_$Phase.txt"
        Set-Content -Path $txt -Value (ConvertTo-LgpoText -Policies $script:Policies) -Encoding ASCII
        $script:LgpoUsed     = $true
        $script:LgpoTextFile = $txt

        # 3. Import into the Local GPO.
        #    [Uncertain] LGPO /t is expected to merge with existing settings;
        #    the backup above covers you if it replaced anything.
        & $lgpo /t $txt | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "LGPO import failed (exit $LASTEXITCODE)." }
        Write-Ok "Imported via LGPO (visible in gpedit.msc). Text file kept at $txt"
    }
    else {
        Write-Warn "LGPO.exe not found: policies written directly to the registry (not shown in gpedit; User policies reach only '$env:USERNAME')."
        foreach ($p in $script:Policies) {
            $root = if ($p.Scope -eq 'Computer') { 'HKLM:\' } else { 'HKCU:\' }
            if ($p.Type -eq 'SZ') {
                $path = $root + $p.Key
                if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
                New-ItemProperty -Path $path -Name $p.Name -Value ([string]$p.Value) -PropertyType String -Force | Out-Null
            }
            else { Set-RegDword -Path ($root + $p.Key) -Name $p.Name -Value ([int]$p.Value) }
        }
        Write-Ok "Registry policy values written"
    }
    & gpupdate.exe /force | Out-Host
}

# ===========================================================================
# PHASE 1: PRE-UPDATE
# ===========================================================================
function Invoke-PreUpdate {
    Write-Step 'Driver search lockdown'

    # Equivalent of Device Installation Settings > "No". Stops Windows
    # fetching drivers when NEW hardware appears. Non-policy value.
    Set-RegDword -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name 'SearchOrderConfig' -Value 0
    Write-Ok 'SearchOrderConfig = 0'

    # SearchOrderConfig does NOT stop Windows Update itself from offering
    # driver packages; this policy does.
    Add-Policy -Scope Computer -Key 'Software\Policies\Microsoft\Windows\WindowsUpdate' `
        -Name 'ExcludeWUDriversInQualityUpdate' -Value 1 `
        -Comment 'Windows Update > Manage updates offered from WU > Do not include drivers with Windows Updates = Enabled'

    # Guide 7.3.2
    Add-Policy -Scope Computer -Key 'Software\Policies\Microsoft\Windows\DriverSearching' `
        -Name 'DontPromptForWindowsUpdate' -Value 1 `
        -Comment '7.3.2 Turn off Windows Update device driver search prompt = Enabled'

    Invoke-PolicyApply
}

# ===========================================================================
# PHASE 2: POST-INSTALL
# ===========================================================================
function Set-PowerConfig {
    Write-Step 'Power plan'

    # Fixed destination GUID for our clone so re-running never creates a
    # second plan (powercfg /duplicatescheme accepts a destination GUID).
    $ultimateSrc = 'e9a42b02-d5df-448d-aa00-03f14749eb61'   # Ultimate Performance (hidden template)
    $highSrc     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'   # High performance
    $planGuid    = '6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e56'   # our "WATCHOUT 6" clone (fixed GUID: re-runs reuse it)

    # Settings (sub-group, setting, value). Aliases where powercfg has them.
    #   SUB_SLEEP STANDBYIDLE / HIBERNATEIDLE  0 = never
    #   SUB_VIDEO VIDEOIDLE                    0 = never turn off display  (guide 10.5)
    #   SUB_DISK  DISKIDLE                     0 = never turn off disk     (guide 10.5)
    #   SUB_PCIEXPRESS ASPM                    0 = Link State Power Management off
    #   USB 2a737441-... / selective suspend 48e6b7a6-...  0 = Disabled (guide 10.5)
    #   SUB_PROCESSOR PROCTHROTTLEMIN / PROCTHROTTLEMAX       0 % / 100 %
    $settings = @(
        @('SUB_SLEEP', 'STANDBYIDLE', 0),
        @('SUB_SLEEP', 'HIBERNATEIDLE', 0),
        @('SUB_VIDEO', 'VIDEOIDLE', 0),
        @('SUB_DISK', 'DISKIDLE', 0),
        @('SUB_PCIEXPRESS', 'ASPM', 0),
        @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0),
        # Processor power management: minimum 0 %, maximum 100 %. The Ultimate
        # Performance template ships with a 100 % minimum (cores never clock
        # down); 0 % lets idle cores drop clocks while load still reaches 100 %.
        @('SUB_PROCESSOR', 'PROCTHROTTLEMIN', 0),
        @('SUB_PROCESSOR', 'PROCTHROTTLEMAX', 100)
    )

    if ($script:AuditMode) {
        $list = (& powercfg.exe /list) -join "`n"
        if ($list -notmatch $planGuid) {
            Write-Audit 'NotSet' "Power plan $planGuid exists" 'current: missing'
        }
        else {
            Write-Audit 'Set' "Power plan $planGuid exists"
            $active = (& powercfg.exe /getactivescheme) -join ' '
            if ($active -match $planGuid) { Write-Audit 'Set' 'Power plan is the active plan' }
            else { Write-Audit 'NotSet' 'Power plan is the active plan' "current: $active" }
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                foreach ($s in $settings) {
                    # The last two "0x........" values printed by powercfg /query
                    # are the current AC and DC indexes. [Uncertain] Relies on the
                    # layout of the output, not on its (localised) labels.
                    $out = @(& powercfg.exe /query $planGuid $s[0] $s[1] 2>$null)
                    $hex = @($out | ForEach-Object { if ($_ -match '0x([0-9a-fA-F]{8})\s*$') { [Convert]::ToInt64($Matches[1], 16) } })
                    $item = "Power setting $($s[0]) $($s[1]) = $($s[2]) (AC and DC)"
                    if ($hex.Count -lt 2) { Write-Audit 'NotSet' $item 'current: could not be read'; continue }
                    $ac = $hex[$hex.Count - 2]
                    $dc = $hex[$hex.Count - 1]
                    if ($ac -eq $s[2] -and $dc -eq $s[2]) { Write-Audit 'Set' $item }
                    else { Write-Audit 'NotSet' $item "current: AC $ac, DC $dc" }
                }
            }
            finally { $ErrorActionPreference = $prevEap }
        }
        # Guide chapter 4: "powercfg /hibernate off" sets HibernateEnabled = 0.
        Test-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled' -Expected 0 -Label 'Hibernation off'
        return
    }

    $list = (& powercfg.exe /list) -join "`n"
    if ($list -notmatch $planGuid) {
        & powercfg.exe /duplicatescheme $ultimateSrc $planGuid | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Ultimate template can be missing/hidden (e.g. Modern Standby
            # platforms): fall back to High performance.
            & powercfg.exe /duplicatescheme $highSrc $planGuid | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn 'Could not clone Ultimate or High performance (Modern Standby platform?). Tuning the current plan instead.'
                $planGuid = 'SCHEME_CURRENT'
            }
        }
        if ($planGuid -ne 'SCHEME_CURRENT') {
            & powercfg.exe /changename $planGuid 'WATCHOUT 6' 'Show server plan' | Out-Null
        }
    }

    # In Windows PowerShell 5.1, redirecting a native command's stderr while
    # $ErrorActionPreference = 'Stop' turns any stderr line into a terminating
    # error. Relax it locally and rely on $LASTEXITCODE instead.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($s in $settings) {
            foreach ($mode in '/setacvalueindex', '/setdcvalueindex') {
                & powercfg.exe $mode $planGuid $s[0] $s[1] $s[2] 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Warn "powercfg $mode $($s[0]) $($s[1]) not applied (setting hidden on this platform?)" }
            }
        }
    }
    finally { $ErrorActionPreference = $prevEap }

    & powercfg.exe /setactive $planGuid | Out-Null
    Write-Ok "Active plan set ($planGuid): sleep/display/disk never, ASPM off, USB selective suspend off, CPU min 0 % / max 100 %"

    # Guide chapter 4: hibernation off (also deletes hiberfil.sys).
    & powercfg.exe /hibernate off | Out-Null
    Write-Ok 'Hibernation disabled'

    # Modern Standby (S0) is not governed by the S1-S3 policies; show what
    # the firmware exposes so you can spot it.
    Write-Host '  Sleep states reported by firmware:' -ForegroundColor DarkGray
    & powercfg.exe /a | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
}

function Set-NicPowerConfig {
    Write-Step 'Network adapter power management'

    # Physical adapters only (skips Hyper-V, VPN, loopback, NDI virtual NICs).
    $nics = @(Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' })
    if ($nics.Count -eq 0) { Write-Warn 'No physical network adapters found.'; return }

    foreach ($nic in $nics) {
        # Device Manager > Power Management > "Allow the computer to turn off
        # this device to save power" = unchecked.
        if ($script:AuditMode) {
            $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
            $item = "$($nic.Name): power-off by OS disabled"
            if (-not $pm) { Write-Audit 'NA' $item 'not exposed by the driver' }
            elseif ("$($pm.AllowComputerToTurnOffDevice)" -eq 'Disabled') { Write-Audit 'Set' $item }
            else { Write-Audit 'NotSet' $item "current: $($pm.AllowComputerToTurnOffDevice)" }
        }
        else {
            try {
                Set-NetAdapterPowerManagement -Name $nic.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
                Write-Ok "$($nic.Name): power-off by OS disabled"
            }
            catch { Write-Warn "$($nic.Name): could not change power management ($($_.Exception.Message))" }
        }

        # EEE / Green Ethernet: names differ by vendor, so match by display
        # name or registry keyword, then pick whichever valid value means "off".
        $props = @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Energy.?Efficient|Green.?Ethernet|Power Saving Mode' -or $_.RegistryKeyword -match 'EEE' })

        if ($props.Count -eq 0) {
            if ($script:AuditMode) { Write-Audit 'NA' "$($nic.Name): EEE / Green Ethernet off" 'no such property exposed' }
            else { Write-Host "  [--]   $($nic.Name): no EEE/Green Ethernet property exposed" -ForegroundColor DarkGray }
        }
        foreach ($p in $props) {
            $off = $p.ValidDisplayValues | Where-Object { $_ -match '^(Disabled?|Off)$' } | Select-Object -First 1
            if (-not $off) {
                if ($script:AuditMode) { Write-Audit 'NA' "$($nic.Name): '$($p.DisplayName)' off" "no recognisable 'off' value ($($p.ValidDisplayValues -join ', ')); check by hand"; continue }
                Write-Warn "$($nic.Name): '$($p.DisplayName)' has no recognisable 'off' value ($($p.ValidDisplayValues -join ', ')). Set by hand."; continue
            }
            if ($p.DisplayValue -eq $off) {
                if ($script:AuditMode) { Write-Audit 'Set' "$($nic.Name): '$($p.DisplayName)' = $off"; continue }
                Write-Ok "$($nic.Name): '$($p.DisplayName)' already $off"; continue
            }
            if ($script:AuditMode) { Write-Audit 'NotSet' "$($nic.Name): '$($p.DisplayName)' = $off" "current: $($p.DisplayValue)"; continue }
            # NOTE: changing an advanced property briefly resets the link.
            Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $p.DisplayName -DisplayValue $off
            Write-Ok "$($nic.Name): '$($p.DisplayName)' -> $off"
        }
    }
}

function Set-NetworkLocation {
    # Guide 7.2 goal: no network discovery flyout, stable network location.
    Write-Step 'Network location (guide 7.2 equivalent)'

    # Force every non-domain profile to Private.
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -ne 'DomainAuthenticated' })

    # Presence of this key suppresses the "allow your PC to be discoverable"
    # flyout when a new network is detected. Non-policy, written directly.
    # [Uncertain] Long-standing (Vista-era) switch; confirm the flyout stays
    # hidden when you plug into a new switch.
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff'

    if ($script:AuditMode) {
        if ($profiles.Count -eq 0) { Write-Audit 'NA' 'Network category Private' 'no connected non-domain network' }
        foreach ($np in $profiles) {
            $item = "$($np.InterfaceAlias): network category Private"
            if ("$($np.NetworkCategory)" -eq 'Private') { Write-Audit 'Set' $item }
            else { Write-Audit 'NotSet' $item "current: $($np.NetworkCategory)" }
        }
        if (Test-Path $k) { Write-Audit 'Set' "New-network discovery flyout suppressed [$k]" }
        else { Write-Audit 'NotSet' "New-network discovery flyout suppressed [$k]" 'current: key missing' }
        return
    }

    foreach ($np in $profiles) {
        try {
            Set-NetConnectionProfile -InterfaceIndex $np.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Ok "$($np.InterfaceAlias): network category Private"
        }
        catch { Write-Warn "$($np.InterfaceAlias): could not set Private ($($_.Exception.Message))" }
    }

    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    Write-Ok 'New-network discovery flyout suppressed'
}

function Set-NotificationPreferences {
    # Non-policy, per-user toggles for the account running the script. The
    # notification POLICIES live in Add-GuidePolicies (guide 7.7) so they are
    # defined once.
    Write-Step "Per-user notification preferences (account: $env:USERNAME)"
    # Settings > System > Notifications master toggle = Off
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    # "Suggest ways to finish setting up my device" = Off (full-screen OOBE nag)
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    # ContentDeliveryManager: welcome experience, tips and suggestions
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    Set-RegDword $cdm 'SubscribedContent-310093Enabled' 0   # Windows welcome experience after updates
    Set-RegDword $cdm 'SubscribedContent-338389Enabled' 0   # Tips and suggestions
    Set-RegDword $cdm 'SoftLandingEnabled' 0
    Set-RegDword $cdm 'SystemPaneSuggestionsEnabled' 0
    Write-Ok 'Notification master toggle, OOBE nag, tips and welcome experience off'
    # Do Not Disturb is stored in an undocumented CloudStore blob and is not
    # reliably scriptable; with toasts disabled it is redundant.
}

function Add-GuidePolicies {
    # Dataton tweaking guide chapter 7, Win11-adapted. Section numbers refer
    # to the guide. Items marked IGNORED ON PRO are written for parity (so
    # gpedit mirrors the guide) but Windows 11 Pro does not enforce them.
    Write-Step "Dataton guide chapter 7 policies (role: $Role)"

    # ---------- 7.1 Firewall off, all profiles, notifications off ----------
    if ($KeepFirewall) {
        # WATCHOUT 6 does not create firewall rules itself: Set-WatchoutFirewallRules adds them.
        Write-Ok '7.1 Firewall policies skipped (-KeepFirewall); program rules are added in the WATCHOUT 6 step'
    }
    else {
        foreach ($fwProfile in 'DomainProfile', 'PrivateProfile', 'PublicProfile') {
            $k = "Software\Policies\Microsoft\WindowsFirewall\$fwProfile"
            Add-Policy Computer $k 'EnableFirewall'       0 "7.1 Firewall state ($fwProfile) = Off"
            Add-Policy Computer $k 'DisableNotifications' 1 "7.1 Display a notification ($fwProfile) = No"
        }
        # [Uncertain] gpedit's "Windows Defender Firewall with Advanced
        # Security" node may not display these; verify in wf.msc.
    }

    # ---------- 7.3 Computer > Administrative Templates > System ----------
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\DeviceInstall\Settings' 'DisableBalloonTips' 1 '7.3.1 Turn off "Found New Hardware" balloons = Enabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\DriverSearching' 'DontPromptForWindowsUpdate' 1 '7.3.2 Turn off Windows Update device driver search prompt = Enabled'
    Add-Policy Computer 'Software\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableStartupSound' 1 '7.3.3.1 Turn off Windows Startup sound = Enabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows NT\CurrentVersion\Winlogon' 'SyncForegroundPolicy' 0 '7.3.3.2 Always wait for the network at computer startup and logon = Disabled'
    $sleep = 'Software\Policies\Microsoft\Power\PowerSettings\abfc2519-3608-4c2a-94ea-171b0ed546ab'
    Add-Policy Computer $sleep 'ACSettingIndex' 0 '7.3.4.1 Allow standby states (S1-S3) when sleeping (plugged in) = Disabled'
    Add-Policy Computer $sleep 'DCSettingIndex' 0 '7.3.4.2 Allow standby states (S1-S3) when sleeping (on battery) = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WinRE' 'DisableSetup' 1 '7.3.5.1 Allow restore of system to default state = Disabled (legacy OEM recovery)'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows NT\SystemRestore' 'DisableSR' 1 '7.3.6.1 Turn off System Restore = Enabled'

    # ---------- 7.4 Computer > Administrative Templates > Windows Components ----------
    Add-Policy Computer 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\WAU' 'Disabled' 1 '7.4.1.1 Add features to Windows: Prevent the wizard from running = Enabled (obsolete on Win11)'
    Add-Policy Computer 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255 '7.4.2.1 Turn off Autoplay = Enabled (All drives)'
    Add-Policy Computer 'Software\Policies\Microsoft\Biometrics' 'Enabled' 0 '7.4.3.1 Allow the use of biometrics = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1 '7.4.4.1 Do not show Windows tips = Enabled (IGNORED ON PRO)'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1 '7.4.4.2 Turn off Microsoft consumer experiences = Enabled (IGNORED ON PRO)'
    Add-Policy Computer 'Software\Microsoft\Windows\CurrentVersion\Policies\Windows\Sidebar' 'TurnOffSidebar' 1 '7.4.5.1 Turn off desktop gadgets = Enabled (obsolete; Widgets handled below)'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0 '7.4.6.1 Allow Cortana = Disabled (Cortana retired)'
    Add-Policy Computer 'Software\Policies\Microsoft\WindowsStore' 'RemoveWindowsStore' 1 '7.4.7.1 Turn off the Store application = Enabled (IGNORED ON PRO, KB3135657)'
    # 7.4.8 Defender is handled by Set-DefenderConfig (needs Tamper Protection logic).
    Add-Policy Computer 'Software\Policies\Microsoft\PassportForWork' 'Enabled' 0 '7.4.9.1 Use Windows Hello for Business = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\WindowsMediaPlayer' 'DisableAutoUpdate' 1 '7.4.10.1 Windows Media Player: Prevent Automatic Updates = Enabled'
    Add-Policy Computer 'Software\Policies\Microsoft\WindowsMediaPlayer' 'GroupPrivacyAcceptance' 1 '7.4.10.2 Windows Media Player: Do Not Show First Use Dialog Boxes = Enabled'
    # 7.4.11 Windows Update freeze. Applied only here, after all updates are in.
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAUShutdownOption' 1 '7.4.11.1 Do not display "Install Updates and Shut Down" option = Enabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1 '7.4.11.2 Configure Automatic Updates = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsUpdate' 'DoNotConnectToWindowsUpdateInternetLocations' 1 '7.4.11.3 Do not connect to any WU Internet locations = Enabled (only effective with a WSUS server set)'
    # Keep the PreUpdate driver exclusion in place in case PreUpdate was skipped.
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1 'Do not include drivers with Windows Updates = Enabled'
    # Windows Security notifications (not in the 2018 guide; same intent as 7.7)
    Add-Policy Computer 'Software\Policies\Microsoft\Windows Defender Security Center\Notifications' 'DisableNotifications' 1 'Windows Security: Hide all notifications = Enabled'

    # ---------- Windows 11 additions (same intent: nothing that pops up or phones home) ----------
    Add-Policy Computer 'Software\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 'Win11: Widgets > Allow widgets = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB' 0 'Win11: Allow search highlights = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\Windows Search' 'ConnectedSearchUseWeb' 0 'Win11: Do not search the web or display web results in Search (inconsistently honoured)'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 'Win11: Turn off saving snapshots for Recall = Enabled (Copilot+ PCs only)'

    # ---------- 7.5 / 7.6 / 7.7 User > Administrative Templates ----------
    if ($Role -eq 'Display') {
        Add-Policy User 'Software\Microsoft\Windows\CurrentVersion\Policies\System' 'DisableLockWorkstation' 1 '7.5.1.1 Ctrl+Alt+Del: Remove Lock Computer = Enabled (display only)'
        Add-Policy User 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoLogoff' 1 '7.5.1.2 Ctrl+Alt+Del: Remove Logoff = Enabled (display only)'
        Add-Policy User 'Software\Policies\Microsoft\Windows\Explorer' 'DisableThumbsDBOnNetworkFolders' 1 '7.6.1.1 Turn off caching of thumbnails in hidden thumbs.db files = Enabled (display only)'
        Add-Policy User 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'DisableThumbnails' 1 '7.6.1.2 Turn off display of thumbnails, only display icons = Enabled (display only)'
    }
    # [Uncertain] value name from the ADMX as recalled; confirm it shows Enabled in gpedit.
    Add-Policy User 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoInplaceSharing' 1 '7.6.2.1 Prevent users from sharing files within their profile = Enabled'
    Add-Policy User 'Software\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1 '7.7.1 Remove Notifications and Action Center = Enabled'
    Add-Policy User 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'TaskbarNoNotification' 1 '7.7.2 Turn off all balloon notifications = Enabled'
    Add-Policy User 'Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' 'NoToastApplicationNotification' 1 '7.7.3.1 Turn off toast notifications = Enabled'
    Add-Policy User 'Software\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' 'NoTileApplicationNotification' 1 '7.7.3.2 Turn off tile notifications = Enabled'

    Write-Ok "Queued $($script:Policies.Count) policies so far"
}

function Set-UpdateFreeze {
    # "Configure Automatic Updates = Disabled" (guide 7.4.11) stops automatic
    # installs, but Windows still offers new feature releases (e.g. 26H2) in
    # Settings and still shows update notifications. Two policies close that:
    #   1. Pin the feature version: Windows Update > Manage updates offered
    #      from Windows Update > "Select the target Feature Update version".
    #      Quality (security) updates for the pinned version stay available
    #      for manual install; no newer feature release is offered.
    #   2. Silence notifications: Manage end user experience > "Display
    #      options for update notifications" = 2 (all off, incl. restart).
    Write-Step 'Windows Update freeze'

    # Pin to the version installed now unless -PinVersion says otherwise.
    # try/catch: under StrictMode a missing value would otherwise throw.
    $current = $null
    try { $current = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion -ErrorAction Stop).DisplayVersion } catch { }
    $pin = if ($PinVersion) { $PinVersion } else { $current }
    if (-not $pin) {
        Write-Warn 'Could not read the installed Windows version; feature version NOT pinned. Re-run with -PinVersion 25H2 (or your version).'
    }
    else {
        $wu = 'Software\Policies\Microsoft\Windows\WindowsUpdate'
        Add-Policy Computer $wu 'TargetReleaseVersion'     1            'Select the target Feature Update version = Enabled'
        Add-Policy Computer $wu 'ProductVersion'           'Windows 11' 'Target product: Windows 11' -Type SZ
        Add-Policy Computer $wu 'TargetReleaseVersionInfo' $pin         "Target feature version: $pin" -Type SZ
        Write-Ok "Feature version pinned to Windows 11 $pin (installed: $current)"
    }

    $wu = 'Software\Policies\Microsoft\Windows\WindowsUpdate'
    Add-Policy Computer $wu 'SetUpdateNotificationLevel' 1 'Display options for update notifications = Enabled'
    Add-Policy Computer $wu 'UpdateNotificationLevel'    2 'Notification level: 2 = turn off all notifications, including restart warnings'
    Write-Ok 'Update notifications off'

    if ($KeepUpdateService) {
        if ($script:AuditMode) { Write-Audit 'NA' 'Update services and tasks disabled' '-KeepUpdateService' }
        Write-Ok 'Windows Update services left running (-KeepUpdateService): manual updates still possible'
        return
    }

    # FULL DISABLE (default), the same steps as WinUtil's "Disable all
    # updates". These servers are never patched in place: a newer Windows is
    # installed from a fresh ISO instead. Consequences, by design:
    #   * no security or Defender definition updates, ever;
    #   * Settings > Windows Update and the Settings Activation page show
    #     errors such as 0x80070422 (check activation with "slmgr /xpr").

    # Automatic Updates policy option 1, as WinUtil sets it (alongside the
    # guide's NoAutoUpdate = 1 already queued in Add-GuidePolicies).
    Add-Policy Computer 'Software\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 1 'Configure Automatic Updates: AUOptions = 1 (WinUtil "Disable all updates")'

    # Delivery Optimization: no peer downloads (non-policy value, direct write).
    Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0

    # Services: Background Intelligent Transfer, Windows Update, Update
    # Orchestrator. Previous start types saved for rollback first.
    $names  = 'BITS', 'wuauserv', 'UsoSvc'
    # Update-related scheduled tasks (disabled further down).
    $taskPaths = '\Microsoft\Windows\InstallService\', '\Microsoft\Windows\UpdateOrchestrator\',
                 '\Microsoft\Windows\UpdateAssistant\', '\Microsoft\Windows\WaaSMedic\',
                 '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\WindowsUpdate\'

    if ($script:AuditMode) {
        foreach ($n in $names) { Test-ServiceStartType $n 'Update service' }
        Write-Audit 'NA' 'SoftwareDistribution cleared' 'one-off action, not a setting'
        $tasks = @(foreach ($tp in $taskPaths) { Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue })
        $on = @($tasks | Where-Object { "$($_.State)" -ne 'Disabled' })
        $item = "Update scheduled tasks disabled ($($tasks.Count) found)"
        if ($tasks.Count -eq 0) { Write-Audit 'NA' $item 'no tasks found' }
        elseif ($on.Count -eq 0) { Write-Audit 'Set' $item }
        else { Write-Audit 'NotSet' $item "still enabled: $(($on | ForEach-Object { $_.TaskName }) -join ', '); Windows protects some of them" }
        return
    }
    $backup = Join-Path $ScriptDir "UpdateServices_Backup_$Stamp.csv"
    Get-CimInstance Win32_Service | Where-Object { $names -contains $_.Name } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; StartType = $(if ($_.StartMode -eq 'Auto') { 'Automatic' } else { $_.StartMode }) }
    } | Export-Csv -Path $backup -NoTypeInformation
    Add-BackupRecord -Kind 'UpdateServicesCsv' -Path $backup -Restore "Import-Csv '$backup' | ForEach-Object { Set-Service `$_.Name -StartupType `$_.StartType }"
    foreach ($n in $names) {
        try {
            Stop-Service -Name $n -Force -ErrorAction SilentlyContinue
            Set-Service  -Name $n -StartupType Disabled -ErrorAction Stop
        }
        catch { Write-Warn "${n}: could not disable ($($_.Exception.Message))" }
    }

    # Downloaded update files (services are stopped now, so nothing is locked).
    Remove-Item -Path "$env:SystemRoot\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok 'SoftwareDistribution cleared'

    # Update-related scheduled tasks. Some are protected by Windows and stay
    # enabled; with the three services disabled they cannot do anything.
    $tasks = @(foreach ($tp in $taskPaths) { Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue })
    foreach ($t in $tasks) { $t | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null }
    $stillOn = @($tasks | ForEach-Object { Get-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue } |
                 Where-Object { $_.State -ne 'Disabled' })
    Write-Ok "Update tasks: $($tasks.Count - $stillOn.Count) of $($tasks.Count) disabled$(if ($stillOn) { ' (the rest are protected by Windows)' })"

    # Read back. Windows' Update Medic service (WaaSMedicSvc, protected) can
    # restore wuauserv later: check again after the reboot.
    $left = @(Get-CimInstance Win32_Service | Where-Object { $names -contains $_.Name -and $_.StartMode -ne 'Disabled' })
    if ($left) { Write-Warn "Still not disabled: $(($left | ForEach-Object Name) -join ', ')" }
    else { Write-Ok 'BITS, wuauserv, UsoSvc disabled' }
    Write-Host "  [i]    Restore: Import-Csv '$backup' | ForEach-Object { Set-Service `$_.Name -StartupType `$_.StartType }" -ForegroundColor DarkGray
}

function Set-PerformanceRegistry {
    # Dataton guide chapter 12 (WATCHOUT 6 set). Non-policy values, written directly.
    Write-Step 'Performance registry values (guide ch. 12)'

    # 12.1 DirectShow thread priority = "highest", HEX F9 as the guide states.
    # WATCHOUT 6 is a 32-bit application, and 32-bit programs on 64-bit
    # Windows read HKLM\SOFTWARE through WOW6432Node, so both views are set.
    # [Uncertain] Whether current DirectShow builds still read this value;
    # it is applied for guide parity and is harmless if ignored.
    foreach ($ds in 'HKLM:\SOFTWARE\Microsoft\DirectShow', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\DirectShow') {
        Set-RegDword $ds 'ThreadPriority' 0xF9
    }
    Write-Ok 'DirectShow ThreadPriority = 0xF9 (64- and 32-bit views)'

    # 12.1 MMCSS CPU reserve for background tasks. Guide: 5. Windows is
    # reported to treat values under 10 as 10, so 10 is written.
    Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
    Write-Ok 'SystemResponsiveness = 10'

    # 12.2 GPU timeout detection: slow multi-output / sync-card mode changes
    # can exceed the 2 s default and end in a TDR bluescreen.
    $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    Set-RegDword $gd 'TdrDelay'    15   # seconds (default 2)
    Set-RegDword $gd 'TdrDdiDelay' 60   # seconds (default 5)
    Write-Ok 'TdrDelay = 15 s, TdrDdiDelay = 60 s'

    # 12.2 ForcePcieLinkSpeed: opt-in only. Read by AMD GPU drivers; the guide
    # itself warns some AMD drivers crash at startup with it (fix: safe mode,
    # delete the value). Written to every display adapter instance (0000, 0001...).
    if ($ForcePcieLinkSpeed) {
        $class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        # Only the numbered instance keys; the "Properties" subkey is access-denied.
        $inst = @(Get-ChildItem $class -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })
        foreach ($k in $inst) { Set-RegDword $k.PSPath 'ForcePcieLinkSpeed' 3 }
        Write-Ok "ForcePcieLinkSpeed = 3 on $($inst.Count) display adapter instance(s)"
    }
    elseif ($script:AuditMode) { Write-Audit 'NA' 'ForcePcieLinkSpeed = 3' '-ForcePcieLinkSpeed not used' }

    # 12.3 Hide the logon/welcome screen. This key belongs to the Windows
    # Embedded/IoT logon feature. [Uncertain] Likely no effect on Pro;
    # written for guide parity, harmless otherwise.
    Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows Embedded\EmbeddedLogon' 'HideAutoLogonUI' 1
    Write-Ok 'HideAutoLogonUI = 1 (parity; Embedded/IoT feature)'

    # 12.3 Desktop scaling off (100 %, 96 DPI): scaling misaligns WATCHOUT 6's
    # Remote Access view. Per-user, account running the script; takes effect
    # at next sign-in. Still check Settings > Display > Scale = 100 % on each output.
    Set-RegDword 'HKCU:\Control Panel\Desktop' 'Win8DpiScaling' 1
    Set-RegDword 'HKCU:\Control Panel\Desktop' 'LogPixels'      96
    Write-Ok "Win8DpiScaling = 1, LogPixels = 96 (account: $env:USERNAME)"

    # 12.3 Production PC only: hex 28 (decimal 40) = short fixed quantums,
    # equal foreground/background time, so WATCHMAKER keeps its CPU share
    # when it loses focus.
    if ($Role -eq 'Production') {
        Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 40
        Write-Ok 'Win32PrioritySeparation = 0x28 (production role)'
    }
    elseif ($script:AuditMode) { Write-Audit 'NA' 'Win32PrioritySeparation = 40 (0x28)' 'Display role' }
}

function Set-WindowsSettings {
    # Dataton guide chapter 10 settings that can be scripted reliably.
    Write-Step "Windows settings (guide ch. 10; per-user parts: $env:USERNAME)"
    $sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # 10.8 UAC "Never notify" = these two values. EnableLUA stays 1: setting it
    # to 0 disables UAC entirely, which breaks modern apps such as Settings parts.
    Set-RegDword $sys 'ConsentPromptBehaviorAdmin' 0
    Set-RegDword $sys 'PromptOnSecureDesktop'      0
    Write-Ok 'UAC: Never notify'

    # 10.4 Remote Assistance off.
    Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0
    Write-Ok 'Remote Assistance connections off'

    # 10.3 Visual effects = "Adjust for best performance".
    # VisualFXSetting = 2 only selects that option button in the dialog; the
    # effects themselves are stored in the values below, which is what the
    # dialog writes when you press Apply. All per-user, read at sign-in, so
    # they take full effect after the reboot that ends PostInstall.
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2

    $desk = 'HKCU:\Control Panel\Desktop'
    # Bit field holding most effects (menu/tooltip fades and slides, combo-box
    # and list-box slide, cursor shadow, window shadows, control animations).
    # 90 12 03 80 10 00 00 00 is the value commonly reported for "best
    # performance" on Windows 10/11. [Uncertain] Not documented by Microsoft;
    # verify in the dialog after the reboot (every box should be unticked).
    Set-RegValue -Path $desk -Name 'UserPreferencesMask' -Type Binary -Value ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))
    Set-RegValue -Path $desk -Name 'DragFullWindows' -Value '0'      # "Show window contents while dragging" off
    Set-RegValue -Path $desk -Name 'FontSmoothing'   -Value '0'      # "Smooth edges of screen fonts" off (part of best performance)
    Set-RegValue -Path "$desk\WindowMetrics" -Name 'MinAnimate' -Value '0'   # "Animate windows when minimizing and maximizing" off

    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegDword $adv 'TaskbarAnimations'   0   # "Animations in the taskbar" off
    Set-RegDword $adv 'ListviewAlphaSelect' 0   # "Show translucent selection rectangle" off
    Set-RegDword $adv 'ListviewShadow'      0   # "Use drop shadows for icon labels on the desktop" off
    Set-RegDword $adv 'IconsOnly'           1   # "Show thumbnails instead of icons" off

    $dwm = 'HKCU:\Software\Microsoft\Windows\DWM'
    Set-RegDword $dwm 'EnableAeroPeek'            0   # "Enable Peek" off
    Set-RegDword $dwm 'AlwaysHibernateThumbnails' 0   # "Save taskbar thumbnail previews" off

    # Windows 11 Settings > Accessibility > Visual effects > Transparency
    # effects (not in the old dialog, same intent).
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
    Write-Ok 'Visual effects: best performance (all effects off, transparency off; full effect after sign-in)'

    # 10.7 Sound scheme "No Sounds": the scheme name plus an empty sound for
    # every event (setting only the name would leave the old sounds assigned).
    if ($script:AuditMode) {
        $scheme = $null
        $sp = Get-ItemProperty -Path 'HKCU:\AppEvents\Schemes' -ErrorAction SilentlyContinue
        if ($sp -and $sp.PSObject.Properties['(default)']) { $scheme = $sp.'(default)' }
        $withSound = @(Get-ChildItem 'HKCU:\AppEvents\Schemes\Apps' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -eq '.Current' -and [string]$_.GetValue('') -ne '' })
        $item = 'Sound scheme: No Sounds (.None, no sound assigned to any event)'
        if ($scheme -eq '.None' -and $withSound.Count -eq 0) { Write-Audit 'Set' $item }
        else { Write-Audit 'NotSet' $item "current: scheme '$scheme', $($withSound.Count) event(s) with a sound" }
    }
    else {
        try {
            Set-ItemProperty -Path 'HKCU:\AppEvents\Schemes' -Name '(Default)' -Value '.None'
            Get-ChildItem 'HKCU:\AppEvents\Schemes\Apps' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -eq '.Current' } |
                ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name '(Default)' -Value '' }
            Write-Ok 'Sound scheme: No Sounds'
        }
        catch { Write-Warn "Sound scheme not changed: $($_.Exception.Message)" }
    }

    # 10.9 Automatic disk optimisation schedule off. The guide's replacement
    # (13.2, retrim at logon) is not applied by this script; NTFS still sends
    # TRIM to SSDs as files are deleted. Run "defrag C: /L" by hand in
    # maintenance windows if you want a full retrim.
    if ($script:AuditMode) {
        $t = Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction SilentlyContinue
        $item = 'Scheduled disk optimisation off (\Microsoft\Windows\Defrag\ScheduledDefrag)'
        if (-not $t) { Write-Audit 'NA' $item 'task not present' }
        elseif ("$($t.State)" -eq 'Disabled') { Write-Audit 'Set' $item }
        else { Write-Audit 'NotSet' $item "current: $($t.State)" }
    }
    else {
        try {
            Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null
            Write-Ok 'Scheduled disk optimisation off'
        }
        catch { Write-Warn "Could not disable the ScheduledDefrag task: $($_.Exception.Message)" }
    }

    # 10.12 USB notifications off ("Notify me if there are issues connecting
    # to USB devices"). [Uncertain] Value name per Windows 10/11 builds; check
    # Settings > Bluetooth & devices > USB after the reboot.
    Set-RegDword 'HKCU:\Software\Microsoft\Shell\USB' 'NotifyOnUsbErrors' 0
    Write-Ok 'USB error notifications off'

    # 10.13 Taskbar badges off. ("Show contacts on the taskbar" no longer exists.)
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarBadges' 0
    Write-Ok 'Taskbar badges off'

    # 10.15 Indexing: handled by disabling the Windows Search service (ch. 11).
}

function Set-AdapterBindings {
    # Guide 10.10: on every physical adapter, unbind everything except IPv4.
    Write-Step 'Network adapter bindings (guide 10.10)'
    if ($KeepAdapterBindings) {
        if ($script:AuditMode) { Write-Audit 'NA' 'IPv4-only adapter bindings (guide 10.10)' '-KeepAdapterBindings' }
        Write-Ok 'Skipped (-KeepAdapterBindings)'; return
    }

    # Microsoft component IDs only; vendor bindings (e.g. Dante, NDI, teaming)
    # are left alone because their purpose is unknown to the script.
    $unbind = [ordered]@{
        'ms_tcpip6' = 'Internet Protocol Version 6'
        'ms_msclient' = 'Client for Microsoft Networks (accessing shares)'
        'ms_server' = 'File and Printer Sharing (offering shares)'
        'ms_pacer' = 'QoS Packet Scheduler'
        'ms_lltdio' = 'Link-Layer Topology Discovery Mapper I/O Driver'
        'ms_rspndr' = 'Link-Layer Topology Discovery Responder'
        'ms_lldp' = 'Microsoft LLDP Protocol Driver'
        'ms_implat' = 'Microsoft Network Adapter Multiplexor Protocol'
    }
    $nics = @(Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' })
    if ($script:AuditMode) {
        foreach ($nic in $nics) {
            $v4 = Get-NetAdapterBinding -Name $nic.Name -ComponentID 'ms_tcpip' -ErrorAction SilentlyContinue
            $item = "$($nic.Name): IPv4 (ms_tcpip) bound"
            if ($v4 -and $v4.Enabled) { Write-Audit 'Set' $item } else { Write-Audit 'NotSet' $item 'current: not bound' }
            foreach ($id in $unbind.Keys) {
                $b = Get-NetAdapterBinding -Name $nic.Name -ComponentID $id -ErrorAction SilentlyContinue
                if (-not $b) { continue }   # component not on this adapter: nothing to unbind
                $item = "$($nic.Name): $($unbind[$id]) ($id) unbound"
                if (-not $b.Enabled) { Write-Audit 'Set' $item } else { Write-Audit 'NotSet' $item 'current: bound' }
            }
        }
        return
    }
    foreach ($nic in $nics) {
        # Make sure IPv4 itself is bound before removing the rest.
        Enable-NetAdapterBinding -Name $nic.Name -ComponentID 'ms_tcpip' -Confirm:$false -ErrorAction SilentlyContinue
        $done = @()
        foreach ($id in $unbind.Keys) {
            $b = Get-NetAdapterBinding -Name $nic.Name -ComponentID $id -ErrorAction SilentlyContinue
            if ($b -and $b.Enabled) {
                # Each change briefly resets the link: never run during a show.
                Disable-NetAdapterBinding -Name $nic.Name -ComponentID $id -Confirm:$false -ErrorAction SilentlyContinue
                $done += $id
            }
        }
        Write-Ok "$($nic.Name): IPv4 only ($(if ($done) { 'unbound ' + ($done -join ', ') } else { 'already' }))"
        if ($done) { Add-BackupRecord -Kind 'AdapterBindings' -Path '' -Restore "Enable-NetAdapterBinding -Name `"$($nic.Name)`" -AllBindings" }
    }
    Write-Host '  [i]    Undo per adapter: Enable-NetAdapterBinding -Name "<adapter>" -AllBindings' -ForegroundColor DarkGray
}

function Set-GuideServices {
    # Guide chapter 11 list, mapped to Windows 11 service names. Services not
    # present on this machine are skipped. Previous start types are saved first.
    Write-Step 'Services (guide ch. 11)'
    if ($KeepServices) {
        if ($script:AuditMode) { Write-Audit 'NA' 'Guide ch. 11 services disabled' '-KeepServices' }
        Write-Ok 'Skipped (-KeepServices)'; return
    }

    $list = [ordered]@{
        'bthserv' = 'Bluetooth Support'; 'BTAGService' = 'Bluetooth Audio Gateway'; 'BthAvctpSvc' = 'AVCTP (Bluetooth)'
        'lfsvc' = 'Geolocation'
        'vmicguestinterface' = 'Hyper-V Guest Service Interface'; 'vmicheartbeat' = 'Hyper-V Heartbeat'
        'vmickvpexchange' = 'Hyper-V Data Exchange'; 'vmicrdv' = 'Hyper-V Remote Desktop Virtualization'
        'vmicshutdown' = 'Hyper-V Guest Shutdown'; 'vmictimesync' = 'Hyper-V Time Synchronization'
        'vmicvmsession' = 'Hyper-V PowerShell Direct'; 'vmicvss' = 'Hyper-V Volume Shadow Copy Requestor'
        'irmon' = 'Infrared Monitor'
        'wlidsvc' = 'Microsoft Account Sign-in Assistant'
        'NvTelemetryContainer' = 'NVIDIA Telemetry Container (older drivers)'
        'PhoneSvc' = 'Phone Service'
        'Spooler' = 'Print Spooler'; 'PrintNotify' = 'Printer Extensions and Notifications'
        'RemoteRegistry' = 'Remote Registry'; 'RemoteAccess' = 'Routing and Remote Access'
        'RasAuto' = 'Remote Access Auto Connection Manager'; 'SessionEnv' = 'Remote Desktop Configuration'
        'TermService' = 'Remote Desktop Services'; 'UmRdpService' = 'Remote Desktop Services UserMode Port Redirector'
        'RetailDemo' = 'Retail Demo Service'
        'TapiSrv' = 'Telephony'
        'WalletService' = 'WalletService'
        'SDRSVC' = 'Windows Backup'
        'WbioSrvc' = 'Windows Biometric Service'
        'WerSvc' = 'Windows Error Reporting Service'
        'wisvc' = 'Windows Insider Service'
        'WMPNetworkSvc' = 'Windows Media Player Network Sharing Service'
        'icssvc' = 'Windows Mobile Hotspot Service'
        'WpnService' = 'Windows Push Notifications System Service'
        'WinRM' = 'Windows Remote Management'
        'WSearch' = 'Windows Search (also covers guide 10.15 indexing)'
        'InstallService' = 'Microsoft Store Install Service'
        'XblAuthManager' = 'Xbox Live Auth Manager'; 'XblGameSave' = 'Xbox Live Game Save'
        'XboxGipSvc' = 'Xbox Accessory Management'; 'XboxNetApiSvc' = 'Xbox Live Networking'
    }
    # Deliberately NOT on the list:
    #   TabletInputService  - on Windows 11, disabling it can break typing in
    #                         Start, search and Settings fields.
    #   WdNisSvc            - Defender Network Inspection: protected; handled
    #                         by the Defender policies instead.
    #   wuauserv            - Windows Update: handled with BITS and UsoSvc
    #                         in Set-UpdateFreeze (-KeepUpdateService skips it).
    #   Intel HDCP / HECI   - vendor service names vary: see the checklist.
    #   CodeMeter / licence - never touched: the WATCHOUT key needs its runtime.

    # Backup of current start types (Auto/Manual/Disabled) for rollback.
    $backup = Join-Path $ScriptDir "Services_Backup_$Stamp.csv"
    $present = @(Get-CimInstance Win32_Service | Where-Object { $list.Contains($_.Name) })
    if ($script:AuditMode) {
        foreach ($svc in $present) {
            $item = "Service $($svc.Name) = Disabled ($($list[$svc.Name]))"
            if ($KeepService -contains $svc.Name) { Write-Audit 'NA' $item '-KeepService' }
            elseif ($svc.StartMode -eq 'Disabled') { Write-Audit 'Set' $item }
            else { Write-Audit 'NotSet' $item "current: $($svc.StartMode)" }
        }
        Write-Audit 'NA' "$($list.Count - $present.Count) other listed service(s)" 'not present on this machine'
        return
    }
    $present | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; StartType = $(if ($_.StartMode -eq 'Auto') { 'Automatic' } else { $_.StartMode }) }
    } | Export-Csv -Path $backup -NoTypeInformation
    Add-BackupRecord -Kind 'ServicesCsv' -Path $backup -Restore "Import-Csv '$backup' | ForEach-Object { Set-Service `$_.Name -StartupType `$_.StartType }"
    Write-Ok "Current start types saved to $backup"

    foreach ($svc in $present) {
        if ($KeepService -contains $svc.Name) { Write-Ok "$($svc.Name): kept (-KeepService)"; continue }
        if ($svc.StartMode -eq 'Disabled') { Write-Ok "$($svc.Name): already disabled"; continue }
        try {
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction Stop
            Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            Write-Ok "$($svc.Name): disabled ($($list[$svc.Name]))"
        }
        catch { Write-Warn "$($svc.Name): could not disable ($($_.Exception.Message))" }
    }
    Write-Host "  [i]    Restore: Import-Csv '$backup' | ForEach-Object { Set-Service `$_.Name -StartupType `$_.StartType }" -ForegroundColor DarkGray
}

function Get-WatchoutInstallPath {
    # Returns the folder that contains WATCHPOINT.exe or WATCHMAKER.exe.
    if ($script:InstallPathCache) { return $script:InstallPathCache }
    # .NET calls instead of Join-Path/Test-Path: Join-Path throws on a drive
    # letter that does not exist (e.g. no D: on this machine), which would
    # abort the whole run under $ErrorActionPreference = 'Stop'.
    $isWo = { param($p)
        [bool]$p -and ([IO.File]::Exists([IO.Path]::Combine($p, 'WATCHPOINT.exe')) -or
                       [IO.File]::Exists([IO.Path]::Combine($p, 'WATCHMAKER.exe'))) }

    $candidates = @()
    if ($WatchoutPath) { $candidates += $WatchoutPath.TrimEnd('\') }
    # Installer's Uninstall entry (WATCHOUT 6 is 32-bit: check both hives).
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $candidates += @(Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'WATCHOUT' -and
                       $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation } |
        ForEach-Object { $_.InstallLocation.TrimEnd('\') })
    # Default (User Guide: C:\WATCHOUT 6) and the tweaking guide's D: suggestion.
    $candidates += 'C:\WATCHOUT 6', 'D:\WATCHOUT 6', 'D:\WATCHOUT'

    foreach ($c in $candidates) {
        if (& $isWo $c) { $script:InstallPathCache = $c; return $c }
    }
    return $null
}
$script:InstallPathCache = $null

function Get-WatchoutExes([string]$install) {
    # Full paths of the WATCHOUT 6 programs present in this install.
    @('WATCHPOINT.exe', 'WATCHMAKER.exe', 'ImageServer\ImageServer.exe') |
        ForEach-Object { Join-Path $install $_ } |
        Where-Object { Test-Path $_ }
}

function Test-WatchpointTask([string]$Execute, [string]$Arguments, [string]$WorkingDirectory, [string]$User) {
    # Audit of the guide 13.1 task that Set-WatchoutApp registers.
    $t = Get-ScheduledTask -TaskPath '\WATCHOUT\' -TaskName 'WATCHPOINT auto-start' -ErrorAction SilentlyContinue
    if (-not $t) { Write-Audit 'NotSet' 'Task \WATCHOUT\WATCHPOINT auto-start exists' 'current: missing'; return }
    Write-Audit 'Set' 'Task \WATCHOUT\WATCHPOINT auto-start exists'
    $a = @($t.Actions)[0]
    $checks = @(
        @('Program',              "$($a.Execute)",                      $Execute),
        @('Arguments',            "$($a.Arguments)",                    $Arguments),
        @('Working directory',    "$($a.WorkingDirectory)",             $WorkingDirectory),
        @('Run level',            "$($t.Principal.RunLevel)",           'Highest'),
        @('Execution time limit', "$($t.Settings.ExecutionTimeLimit)",  'PT0S'),
        @('Priority',             "$($t.Settings.Priority)",            '4')
    )
    foreach ($c in $checks) {
        $item = "WATCHPOINT task: $($c[0]) = '$($c[2])'"
        if ($c[1] -eq $c[2]) { Write-Audit 'Set' $item } else { Write-Audit 'NotSet' $item "current: '$($c[1])'" }
    }
    # Registered for DOMAIN\user; Task Scheduler may report either form.
    $uid = "$($t.Principal.UserId)"
    $item = "WATCHPOINT task: runs as $User"
    if ($uid -eq $User -or $uid -eq ($User -split '\\')[-1]) { Write-Audit 'Set' $item } else { Write-Audit 'NotSet' $item "current: '$uid'" }
    $logon = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
    if ($logon.Count -gt 0) { Write-Audit 'Set' 'WATCHPOINT task: starts at logon' }
    else { Write-Audit 'NotSet' 'WATCHPOINT task: starts at logon' 'current: no logon trigger' }
}

function Set-WatchoutApp {
    # WATCHOUT 6 specifics: firewall program rules (-KeepFirewall) and the
    # WATCHPOINT logon task (guide 13.1, display role).
    Write-Step 'WATCHOUT 6 (firewall rules, auto-start)'
    $install = Get-WatchoutInstallPath
    if (-not $install) {
        Write-Warn 'WATCHOUT 6 install folder not found (no WATCHPOINT.exe / WATCHMAKER.exe). Re-run with -WatchoutPath "<folder>".'
        return
    }
    Write-Ok "Install folder: $install"
    $exes = @(Get-WatchoutExes $install)

    if ($KeepFirewall) {
        # Inbound allow per program, all profiles, any protocol/port: WATCHOUT 6
        # uses fixed ports (3039 display control, 3040 production control,
        # 3041 VNC) plus dynamic ones (file server, NDI, Dynamic Image Server),
        # so program rules are the only complete option. Existing rules from an
        # earlier run are replaced, so re-runs do not stack duplicates.
        if ($script:AuditMode) {
            foreach ($exe in $exes) {
                $name = 'WATCHOUT 6 - ' + [IO.Path]::GetFileNameWithoutExtension($exe)
                $rule = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
                $item = "Firewall rule '$name' (inbound allow, $exe)"
                if ($rule.Count -gt 0 -and "$($rule[0].Enabled)" -eq 'True' -and "$($rule[0].Action)" -eq 'Allow') { Write-Audit 'Set' $item }
                else { Write-Audit 'NotSet' $item 'current: missing or different' }
            }
        }
        else {
            Get-NetFirewallRule -DisplayName 'WATCHOUT 6 - *' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
            foreach ($exe in $exes) {
                $name = 'WATCHOUT 6 - ' + [IO.Path]::GetFileNameWithoutExtension($exe)
                New-NetFirewallRule -DisplayName $name -Direction Inbound -Program $exe -Action Allow -Profile Any | Out-Null
                Write-Ok "Firewall rule: $name"
            }
        }
    }

    if ($Role -ne 'Display') {
        if ($script:AuditMode) { Write-Audit 'NA' 'WATCHPOINT auto-start task (guide 13.1)' 'Production role' }
        Write-Ok 'Production role: no WATCHPOINT auto-start task'; return
    }

    $wp = Join-Path $install 'WATCHPOINT.exe'
    if (-not (Test-Path $wp)) { Write-Warn "WATCHPOINT.exe not found in $install; auto-start task not created."; return }

    # WATCHPOINT options: -Delay <s> and -ShowsPath "<folder>" (User Guide, Command Line Options).
    $argList = @()
    if ($StartDelay -gt 0) { $argList += "-Delay $StartDelay" }
    if ($ShowsPath) { $argList += "-ShowsPath `"$ShowsPath`"" }
    $actionArgs = @{ Execute = $wp; WorkingDirectory = $install }
    if ($argList) { $actionArgs.Argument = $argList -join ' ' }
    $action = New-ScheduledTaskAction @actionArgs

    # Runs in the show user's desktop session at logon, elevated (guide 13.1:
    # "Run with highest privileges", needed for remote software upgrades).
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    # ExecutionTimeLimit 0: the default (72 h) would terminate WATCHPOINT
    # after three days of uptime. Priority 4: the default task priority (7)
    # starts the program at below-normal priority.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 4 `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
    if ($script:AuditMode) {
        $expectedArgs = if ($argList) { $argList -join ' ' } else { '' }
        Test-WatchpointTask -Execute $wp -Arguments $expectedArgs -WorkingDirectory $install -User $user
    }
    else {
        Register-ScheduledTask -TaskPath '\WATCHOUT\' -TaskName 'WATCHPOINT auto-start' -Action $action `
            -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-Ok "Task \WATCHOUT\WATCHPOINT auto-start: at logon of $user, highest privileges, no time limit$(if ($argList) { ', args: ' + ($argList -join ' ') })"
    }

    # A Startup-folder shortcut as well would start WATCHPOINT twice.
    $startup = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                 "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp")
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in $startup) {
        Get-ChildItem $dir -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
            if ($shell.CreateShortcut($_.FullName).TargetPath -match 'WATCHPOINT') {
                Write-Warn "Startup shortcut also launches WATCHPOINT: $($_.FullName). Delete it to avoid a double start."
            }
        }
    }
}

function Add-DefenderExclusions {
    # Shared by Off and Exclusions modes. In Off mode these are a fallback in
    # case real-time protection is re-enabled (e.g. Tamper Protection on).
    $install = Get-WatchoutInstallPath
    if (-not $install) {
        Write-Warn 'WATCHOUT 6 install folder not found; exclusions not added. Re-run with -WatchoutPath "<folder>".'
        return
    }
    # WATCHPOINT keeps transferred shows and media in "Shows" inside the
    # install folder unless -ShowsPath moves it.
    $shows = if ($ShowsPath) { $ShowsPath } else { Join-Path $install 'Shows' }
    $exes  = @(Get-WatchoutExes $install)

    if ($script:AuditMode) {
        $pref = Get-MpPreference
        foreach ($x in @($install, $shows)) {
            if (@($pref.ExclusionPath) -contains $x) { Write-Audit 'Set' "Defender exclusion path $x" }
            else { Write-Audit 'NotSet' "Defender exclusion path $x" 'current: missing' }
        }
        foreach ($e in $exes) {
            if (@($pref.ExclusionProcess) -contains $e) { Write-Audit 'Set' "Defender exclusion process $e" }
            else { Write-Audit 'NotSet' "Defender exclusion process $e" 'current: missing' }
        }
        if ($pref.ScanScheduleDay -eq 8) { Write-Audit 'Set' 'Defender scheduled scans off (ScanScheduleDay = 8)' }
        else { Write-Audit 'NotSet' 'Defender scheduled scans off (ScanScheduleDay = 8)' "current: $($pref.ScanScheduleDay)" }
        return
    }

    try {
        Add-MpPreference -ExclusionPath @($install, $shows)        # binaries, shows, media
        if ($exes) { Add-MpPreference -ExclusionProcess $exes }    # files opened by WATCHOUT, anywhere
        Set-MpPreference -ScanScheduleDay 8                        # 8 = Never
    }
    catch { Write-Warn "Defender preference change failed: $($_.Exception.Message)"; return }

    $pref = Get-MpPreference
    if (($pref.ExclusionPath -contains $install) -and ($pref.ExclusionPath -contains $shows)) {
        Write-Ok "Excluded: $install ; $shows ; $($exes.Count) WATCHOUT program(s) ; scheduled scans off"
    }
    else { Write-Warn 'Exclusions not confirmed on read-back. Check Windows Security > Virus & threat protection > Exclusions.' }
}

function Set-DefenderConfig {
    Write-Step "Microsoft Defender (mode: $DefenderMode)"
    if ($DefenderMode -eq 'Skip') {
        if ($script:AuditMode) { Write-Audit 'NA' 'Defender settings' '-DefenderMode Skip' }
        Write-Ok 'Skipped by request'; return
    }

    # Fails if the Defender service was disabled/removed (debloat or third-party AV).
    try { $status = Get-MpComputerStatus -ErrorAction Stop }
    catch { Write-Warn "Defender is not running or not available ($($_.Exception.Message)). Skipping Defender configuration."; return }
    $tamper = $status.IsTamperProtected

    Add-DefenderExclusions
    if ($DefenderMode -eq 'Exclusions') { return }

    # ---- Off mode: guide 7.4.8 ----
    if ($tamper) {
        if ($script:AuditMode) { Write-Audit 'NotSet' 'Real-time protection off (guide 7.4.8)' 'Tamper Protection is on: the policies would not be written'; return }
        # Tamper Protection makes Defender ignore these policies. Writing them
        # anyway would make gpedit look correct while nothing is enforced.
        Write-Warn 'Tamper Protection is ON: real-time protection policies NOT written. Turn it off in Windows Security > Virus & threat protection > Manage settings, then re-run -Phase PostInstall.'
        return
    }
    $rtp = 'Software\Policies\Microsoft\Windows Defender\Real-Time Protection'
    # DisableAntiSpyware is ignored on client Windows since Defender platform
    # 4.18.2007.8 (Aug 2020); written for guide parity only.
    Add-Policy Computer 'Software\Policies\Microsoft\Windows Defender' 'DisableAntiSpyware' 1 '7.4.8.1 Turn off Microsoft Defender Antivirus = Enabled (ignored on client Windows; parity only)'
    Add-Policy Computer $rtp 'DisableScanOnRealtimeEnable' 1 '7.4.8.2 Turn on process scanning whenever real-time protection is enabled = Disabled'
    Add-Policy Computer $rtp 'DisableBehaviorMonitoring'   1 '7.4.8.2 Turn on behavior monitoring = Disabled'
    Add-Policy Computer $rtp 'DisableRealtimeMonitoring'   1 '7.4.8.2 Turn off real-time protection = Enabled'
    Add-Policy Computer $rtp 'DisableOnAccessProtection'   1 '7.4.8.2 Monitor file and program activity on your computer = Disabled'
    Add-Policy Computer 'Software\Policies\Microsoft\Windows Defender\Scan' 'ScheduleDay' 8 'Scan: Specify the day of the week to run a scheduled scan = Never'
    Write-Ok 'Real-time protection policies queued (enforced after policy refresh / reboot)'

    if ($script:AuditMode) {
        # Effective state, not only the policies (checked with the other
        # policies at the end): Defender itself must report these off.
        foreach ($f in 'RealTimeProtectionEnabled', 'BehaviorMonitorEnabled', 'OnAccessProtectionEnabled') {
            $item = "Defender $f = False (effective)"
            if ($status.$f -eq $false) { Write-Audit 'Set' $item }
            else { Write-Audit 'NotSet' $item "current: $($status.$f)" }
        }
    }
}

function Invoke-PostInstall {
    # Order: network changes first (they briefly reset links), then settings,
    # policies queued, WATCHOUT 6 tasks, Defender, and one policy import last.
    Set-PowerConfig
    Set-NicPowerConfig
    Set-AdapterBindings
    Set-NetworkLocation
    Set-NotificationPreferences
    Set-WindowsSettings
    Add-GuidePolicies
    Set-UpdateFreeze
    Set-PerformanceRegistry
    Set-GuideServices
    Set-WatchoutApp
    Set-DefenderConfig
    Invoke-PolicyApply
}

# ===========================================================================
# MAIN
# ===========================================================================
try {
    switch ($Phase) {
        'PreUpdate'   { Invoke-PreUpdate }
        'PostInstall' { Invoke-PostInstall }
    }
    if ($script:AuditMode) { Write-AuditSummary }
    else {
        Write-Step 'Summary'
        if ($script:Warnings.Count -eq 0) { Write-Ok 'Completed with no warnings. Reboot now.' }
        else {
            Write-Host "  Completed with $($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
            $script:Warnings | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
            Write-Host '  Reboot after resolving them.' -ForegroundColor Yellow
        }
        if ($Phase -eq 'PostInstall') {
            Write-Host '  Manual (see checklist): guide 7.2 "User cannot change location" in secpol.msc, startup apps,' -ForegroundColor DarkGray
            Write-Host '  Scale = 100 % on every output, Wake-on-LAN, vendor services (Intel HDCP/HECI).' -ForegroundColor DarkGray
            Write-Host '  Windows Update is disabled for good: check activation with "slmgr /xpr", not the Settings page.' -ForegroundColor DarkGray
        }
    }
}
catch {
    # Recorded for the result file, then re-thrown: the run fails exactly as before.
    $script:Fatal = $_.Exception.Message
    throw
}
finally {
    Write-ResultFile -Status $(if ($script:Fatal) { 'Failed' } else { 'Completed' })
    Stop-Transcript | Out-Null
}
