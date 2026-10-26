#requires -RunAsAdministrator
<#
.SYNOPSIS
    WATCHOUT 7 display-server setup automation for Windows 11 Pro (24H2/25H2).
    Combines the routine-specific automation (driver lockdown, power, NIC,
    notifications, Defender) with the full Group Policy set from chapter 7 of
    the Dataton "WATCHOUT Windows 10 Enterprise Tweaking Guide" (doc. 3749,
    rev 1.3), adapted for Windows 11.

.DESCRIPTION
    TWO PHASES, matching the install routine:

      -Phase PreUpdate      Run right after Windows is installed, BEFORE
                            Windows Update and BEFORE installing drivers.
                              * SearchOrderConfig = 0  (no driver download on new hardware)
                              * "Do not include drivers with Windows Updates" policy
                              * Driver-search prompt off
                            Windows Update is deliberately left ON here: the
                            routine installs all updates next.

      -Phase PostInstall    Run AFTER every update and driver is installed,
                            after the debloat and after the WATCHOUT install.
                              * Power plan (Ultimate Performance clone), no sleep,
                                no hibernation, no disk/display timeout,
                                USB selective suspend off, PCIe ASPM off
                              * Physical NICs: OS power-off and EEE/Green Ethernet off
                              * Network location: all non-domain networks set to
                                Private, "new network" discovery flyout suppressed
                              * Notifications: toasts off (policy + per-user),
                                Windows Security notifications off, OOBE nags off
                              * Dataton guide chapter 7 GPOs, Win11-adapted
                                (firewall, logon, standby, recovery, AutoPlay,
                                biometrics, cloud content, search, Store, Hello,
                                Media Player, Windows Update freeze, Ctrl+Alt+Del,
                                Explorer, sharing, Start/taskbar notifications)
                                plus Win11 additions (Widgets, search highlights,
                                web search, Recall)
                              * Guide ch. 10 settings: UAC never notify, visual effects,
                                Remote Assistance off, no sounds, defrag schedule off,
                                taskbar badges off, USB notifications off
                              * Guide 10.15 indexing off: Windows Search service
                                disabled (CSV backup)
                              * Defender: -DefenderMode Off (default), Exclusions or Skip

    WINDOWS UPDATE AFTER POSTINSTALL (default: fully disabled)
      These servers are never patched in place; a newer Windows is installed
      from a fresh ISO instead. PostInstall therefore:
        * "Configure Automatic Updates = Disabled" (guide 7.4.11), AUOptions 1
        * pins the feature version and turns update notifications off
        * WinUtil "Disable all updates" steps: BITS, wuauserv and UsoSvc
          disabled (CSV backup), Delivery Optimization off,
          SoftwareDistribution cleared, update scheduled tasks disabled.
      -KeepUpdateService skips the service/task part, so manual updates stay
      possible. With the default, the Settings Windows Update and Activation
      pages show errors (e.g. 0x80070422); use "slmgr /xpr" for activation.

    REGISTRY (guide chapter 12)
      TdrDelay 15 / TdrDdiDelay 60, SystemResponsiveness 10,
      Win8DpiScaling 1 / LogPixels 96 (100 % scaling, per-user), and for
      -Role Production Win32PrioritySeparation 0x28.

    HOW POLICIES ARE WRITTEN
      All policy-type settings are queued, de-duplicated (last definition of a
      Scope+Key+Name wins) and imported in one go with LGPO.exe /t when
      LGPO.exe sits next to the script. That writes them into the Local GPO
      (Registry.pol): they show as "Configured" in gpedit.msc, survive policy
      refreshes, and the GroupPolicy folder can be copied to other servers.
      The existing Local GPO is backed up first (LGPO /b); roll back with:
          LGPO.exe /g "<backup folder>\{GUID}"
      Without LGPO.exe the script writes the same values directly to the
      registry: functionally equivalent for Computer policies, invisible in
      gpedit, and User policies then reach ONLY the account running the script.

    PER-USER SETTINGS
      * User-scope policies (via LGPO) apply to EVERY local account, including
        administrators. -Role Production omits the display-only ones
        (Ctrl+Alt+Del, Explorer thumbnails), as the guide specifies.
      * Non-policy HKCU preferences (notifications, sounds, visual effects,
        DPI, badges, USB notifications) are written to the account that RUNS
        the script: run it elevated FROM THE SHOW (auto-logon) ACCOUNT.

    MANUAL STEPS THE SCRIPT CANNOT DO
      * Tamper Protection OFF (required for -DefenderMode Off). Blocked from
        scripting by Microsoft by design; the script checks and reports.
      * Guide 7.2 "Network List Manager Policies > User cannot change location":
        a security-template setting, not a Registry.pol policy. Set it in
        secpol.msc if you need it; the script already forces Private and
        suppresses the discovery flyout, which is the guide's stated goal.

    IDEMPOTENT
      Safe to re-run: fixed power-plan GUID, registry/LGPO writes overwrite,
      Defender exclusions are additive.

    LOG
      Full transcript saved next to the script as WO7-Setup_<phase>_<timestamp>.log

.PARAMETER Phase
    PreUpdate or PostInstall (see above).

.PARAMETER Role
    Display (default)  Applies everything, including the guide's "only on
                       display server" user policies.
    Production         Omits Ctrl+Alt+Del and Explorer thumbnail policies.

.PARAMETER DefenderMode
    Off (default)  Guide 7.4.8: real-time protection disabled by policy,
                   scheduled scans off. Requires Tamper Protection OFF first;
                   if it is still on, the policies are not written and a
                   warning tells you why. Exclusions are ALWAYS added as well,
                   as a fallback in case real-time protection comes back on.
    Exclusions     Defender stays on; WATCHOUT folders and processes excluded,
                   scheduled scans off.
    Skip           Defender untouched.

.PARAMETER KeepFirewall
    Skip guide 7.1 (firewall off). WATCHOUT 7 creates and self-heals its own
    Windows Defender Firewall rules, so leaving it on is a valid choice.

.PARAMETER PinVersion
    Feature version to pin Windows Update to (e.g. 25H2). Default: the
    version installed now (DisplayVersion).

.PARAMETER KeepUpdateService
    Do NOT disable BITS / Windows Update / Update Orchestrator and their
    tasks. Use it on a machine you still want to patch in place.

.PARAMETER WatchoutPath
    WATCHOUT install folder. Auto-detected from the Uninstall registry if omitted.

.PARAMETER WorkingDirectory
    WATCHOUT working directory (cached assets/shows). Dataton default: a ".wo"
    folder next to the installation.

.PARAMETER ResultPath
    Optional. File to write a JSON summary of the run to (phase, effective
    options, status, warnings, backups with restore commands, LGPO use,
    transcript path). Used by the setup wizard instead of parsing the console
    text. Writing it never changes what the run does.

.EXAMPLE
    .\WO7-Setup.ps1 -Phase PreUpdate
.EXAMPLE
    .\WO7-Setup.ps1 -Phase PostInstall
.EXAMPLE
    .\WO7-Setup.ps1 -Phase PostInstall -Role Production -DefenderMode Exclusions -KeepFirewall
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

    [string]$PinVersion,

    [switch]$KeepUpdateService,

    [string]$WatchoutPath,
    [string]$WorkingDirectory,

    [string]$ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
$Stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:TranscriptPath = Join-Path $ScriptDir "WO7-Setup_${Phase}_$Stamp.log"
Start-Transcript -Path $script:TranscriptPath | Out-Null

# Warnings are collected so the final summary shows what needs attention.
$script:Warnings = New-Object System.Collections.Generic.List[string]
function Write-Step([string]$msg) { Write-Host "`n=== $msg" -ForegroundColor Cyan }
function Write-Ok  ([string]$msg) { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow; $script:Warnings.Add($msg) }

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
    [ordered]@{
        Phase             = $Phase
        Role              = $Role
        DefenderMode      = $DefenderMode
        KeepFirewall      = [bool]$KeepFirewall
        PinVersion        = $PinVersion
        KeepUpdateService = [bool]$KeepUpdateService
        WatchoutPath      = $WatchoutPath
        WorkingDirectory  = $WorkingDirectory
    }
}

function Write-ResultFile([string]$Status) {
    # Only with -ResultPath. A failure here prints a line and is otherwise
    # ignored: the result file must never change the outcome of the run.
    if (-not $ResultPath) { return }
    try {
        $out = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultPath)
        $result = [ordered]@{
            schemaVersion = 1
            script        = 'WO7-Setup.ps1'
            phase         = $Phase
            status        = $Status
            fatal         = $script:Fatal
            startedAt     = $script:RunStarted.ToString('o')
            endedAt       = (Get-Date).ToString('o')
            computerName  = $env:COMPUTERNAME
            userName      = "$env:USERDOMAIN\$env:USERNAME"
            parameters    = Get-RunParameters
            warnings      = @($script:Warnings)
            backups       = @($script:Backups)
            lgpo          = [ordered]@{ used = $script:LgpoUsed; textFile = $script:LgpoTextFile }
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
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
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

function Invoke-PolicyApply {
    if ($script:Policies.Count -eq 0) { return }
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
    $planGuid    = '6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e57'   # our "WATCHOUT 7" clone

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
            & powercfg.exe /changename $planGuid 'WATCHOUT 7' 'Show server plan' | Out-Null
        }
    }

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
        try {
            Set-NetAdapterPowerManagement -Name $nic.Name -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
            Write-Ok "$($nic.Name): power-off by OS disabled"
        }
        catch { Write-Warn "$($nic.Name): could not change power management ($($_.Exception.Message))" }

        # EEE / Green Ethernet: names differ by vendor, so match by display
        # name or registry keyword, then pick whichever valid value means "off".
        $props = @(Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'Energy.?Efficient|Green.?Ethernet|Power Saving Mode' -or $_.RegistryKeyword -match 'EEE' })

        if ($props.Count -eq 0) { Write-Host "  [--]   $($nic.Name): no EEE/Green Ethernet property exposed" -ForegroundColor DarkGray }
        foreach ($p in $props) {
            $off = $p.ValidDisplayValues | Where-Object { $_ -match '^(Disabled?|Off)$' } | Select-Object -First 1
            if (-not $off) { Write-Warn "$($nic.Name): '$($p.DisplayName)' has no recognisable 'off' value ($($p.ValidDisplayValues -join ', ')). Set by hand."; continue }
            if ($p.DisplayValue -eq $off) { Write-Ok "$($nic.Name): '$($p.DisplayName)' already $off"; continue }
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
    foreach ($np in $profiles) {
        try {
            Set-NetConnectionProfile -InterfaceIndex $np.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            Write-Ok "$($np.InterfaceAlias): network category Private"
        }
        catch { Write-Warn "$($np.InterfaceAlias): could not set Private ($($_.Exception.Message))" }
    }

    # Presence of this key suppresses the "allow your PC to be discoverable"
    # flyout when a new network is detected. Non-policy, written directly.
    # [Uncertain] Long-standing (Vista-era) switch; confirm the flyout stays
    # hidden when you plug into a new switch.
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff'
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
        Write-Ok '7.1 Firewall policies skipped (-KeepFirewall); WATCHOUT manages its own rules'
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
    $taskPaths = '\Microsoft\Windows\InstallService\', '\Microsoft\Windows\UpdateOrchestrator\',
                 '\Microsoft\Windows\UpdateAssistant\', '\Microsoft\Windows\WaaSMedic\',
                 '\Microsoft\Windows\WindowsUpdate\', '\Microsoft\WindowsUpdate\'
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
    # Dataton guide chapter 12, adapted. Non-policy values, written directly.
    Write-Step 'Performance registry values (guide ch. 12)'

    # 12.2 GPU timeout detection: slow display-mode changes on multi-output
    # or sync-card systems can exceed the 2 s default and trigger a TDR/BSOD.
    $gd = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
    Set-RegDword $gd 'TdrDelay'    15   # seconds (default 2)
    Set-RegDword $gd 'TdrDdiDelay' 60   # seconds (default 5)
    Write-Ok 'TdrDelay = 15 s, TdrDdiDelay = 60 s'

    # 12.1 MMCSS: CPU share reserved for background tasks. The guide says 5;
    # Windows is reported to treat values under 10 as 10, so 10 is written.
    Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
    Write-Ok 'SystemResponsiveness = 10'

    # 12.3 Desktop scaling off (100 %, 96 DPI), same values as WO6-Setup.ps1
    # (owner's decision, Oct 2026). Per-user, account running the script;
    # takes effect at next sign-in. [Uncertain] On Windows 11 each display
    # keeps its own scale setting; these values set the system DPI only.
    # Still check Settings > Display > Scale = 100 % on each output.
    Set-RegDword 'HKCU:\Control Panel\Desktop' 'Win8DpiScaling' 1
    Set-RegDword 'HKCU:\Control Panel\Desktop' 'LogPixels'      96
    Write-Ok "Win8DpiScaling = 1, LogPixels = 96 (account: $env:USERNAME)"

    # 12.3 Production PC only: hex 28 (decimal 40) = short fixed quantums,
    # equal foreground/background time, so the Producer keeps its CPU share
    # when it loses focus. Display servers keep the Windows default.
    if ($Role -eq 'Production') {
        Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 40
        Write-Ok 'Win32PrioritySeparation = 0x28 (production role)'
    }
    # Not applied (outdated for WATCHOUT 7 / NVIDIA / Windows 11 Pro):
    # DirectShow ThreadPriority, ForcePcieLinkSpeed, HideAutoLogonUI.
}

function Set-WindowsSettings {
    # Dataton guide chapter 10 settings that can be scripted reliably.
    # Copied unchanged from WO6-Setup.ps1 (owner's decision, Oct 2026), so
    # both scripts apply the same chapter 10 values.
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
    Set-ItemProperty -Path $desk -Name 'UserPreferencesMask' -Type Binary -Value ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00))
    Set-ItemProperty -Path $desk -Name 'DragFullWindows' -Value '0'      # "Show window contents while dragging" off
    Set-ItemProperty -Path $desk -Name 'FontSmoothing'   -Value '0'      # "Smooth edges of screen fonts" off (part of best performance)
    Set-ItemProperty -Path "$desk\WindowMetrics" -Name 'MinAnimate' -Value '0'   # "Animate windows when minimizing and maximizing" off

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
    try {
        Set-ItemProperty -Path 'HKCU:\AppEvents\Schemes' -Name '(Default)' -Value '.None'
        Get-ChildItem 'HKCU:\AppEvents\Schemes\Apps' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -eq '.Current' } |
            ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name '(Default)' -Value '' }
        Write-Ok 'Sound scheme: No Sounds'
    }
    catch { Write-Warn "Sound scheme not changed: $($_.Exception.Message)" }

    # 10.9 Automatic disk optimisation schedule off. The guide's replacement
    # (13.2, retrim at logon) is not applied by this script; NTFS still sends
    # TRIM to SSDs as files are deleted. Run "defrag C: /L" by hand in
    # maintenance windows if you want a full retrim.
    try {
        Disable-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -ErrorAction Stop | Out-Null
        Write-Ok 'Scheduled disk optimisation off'
    }
    catch { Write-Warn "Could not disable the ScheduledDefrag task: $($_.Exception.Message)" }

    # 10.12 USB notifications off ("Notify me if there are issues connecting
    # to USB devices"). [Uncertain] Value name per Windows 10/11 builds; check
    # Settings > Bluetooth & devices > USB after the reboot.
    Set-RegDword 'HKCU:\Software\Microsoft\Shell\USB' 'NotifyOnUsbErrors' 0
    Write-Ok 'USB error notifications off'

    # 10.13 Taskbar badges off. ("Show contacts on the taskbar" no longer exists.)
    Set-RegDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarBadges' 0
    Write-Ok 'Taskbar badges off'

    # 10.15 Indexing: Set-SearchIndexing (Windows Search service disabled).
}

function Set-SearchIndexing {
    # Guide 10.15 (indexing off on every drive), done the WATCHOUT 6 way:
    # disabling the Windows Search service (WSearch) stops indexing on all
    # drives at once. Start menu and Explorer search still work, without an
    # index (slower). Only WSearch is touched here; the rest of the guide's
    # chapter 11 service list is deliberately not applied on WATCHOUT 7.
    # [Uncertain] WATCHOUT 7 is not known to depend on Windows Search;
    # confirm on a test machine.
    Write-Step 'Indexing off (guide 10.15: Windows Search service)'
    $svc = Get-CimInstance Win32_Service -Filter "Name='WSearch'" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Host '  [--]   WSearch service not present (removed by debloat?)' -ForegroundColor DarkGray
        return
    }

    # Previous start type saved for rollback first (same CSV format as the
    # update-services backup, so the same restore line works).
    $backup = Join-Path $ScriptDir "SearchService_Backup_$Stamp.csv"
    [pscustomobject]@{ Name = $svc.Name; StartType = $(if ($svc.StartMode -eq 'Auto') { 'Automatic' } else { $svc.StartMode }) } |
        Export-Csv -Path $backup -NoTypeInformation
    Add-BackupRecord -Kind 'SearchServiceCsv' -Path $backup -Restore "Import-Csv '$backup' | ForEach-Object { Set-Service `$_.Name -StartupType `$_.StartType }"

    if ($svc.StartMode -eq 'Disabled') {
        Write-Ok 'WSearch already disabled'
    }
    else {
        try {
            Set-Service -Name 'WSearch' -StartupType Disabled -ErrorAction Stop
            Stop-Service -Name 'WSearch' -Force -ErrorAction SilentlyContinue
        }
        catch { Write-Warn "WSearch: could not disable ($($_.Exception.Message))"; return }

        # Read back instead of trusting the call.
        $after = Get-CimInstance Win32_Service -Filter "Name='WSearch'"
        if ($after.StartMode -eq 'Disabled') { Write-Ok 'WSearch (Windows Search) disabled: no indexing on any drive' }
        else { Write-Warn "WSearch is still '$($after.StartMode)' after the change." }
    }
    Write-Host "  [i]    Restore: Import-Csv '$backup' | ForEach-Object { Set-Service `$_.Name -StartupType `$_.StartType }" -ForegroundColor DarkGray
}

function Get-WatchoutInstallPath {
    if ($WatchoutPath) { return $WatchoutPath }
    # Look up the installer's Uninstall entry (64- and 32-bit hives).
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
             'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $entry = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'WATCHOUT' -and
                       $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation } |
        Select-Object -First 1
    if ($entry) { return $entry.InstallLocation.TrimEnd('\') }
    return $null
}

function Add-DefenderExclusions {
    # Shared by Off and Exclusions modes. In Off mode these are a fallback in
    # case real-time protection is re-enabled (e.g. Tamper Protection on).
    $install = Get-WatchoutInstallPath
    if (-not $install -or -not (Test-Path $install)) {
        Write-Warn 'WATCHOUT install folder not found; exclusions not added. Re-run with -WatchoutPath "<folder>".'
        return
    }
    # Dataton default working directory: ".wo" folder next to the installation.
    $work = if ($WorkingDirectory) { $WorkingDirectory } else { Join-Path $install '.wo' }
    if (-not (Test-Path $work)) { Write-Warn "Working directory '$work' does not exist yet (created on first WATCHOUT start). Exclusion added anyway." }

    try {
        Add-MpPreference -ExclusionPath @($install, $work)     # asset cache, shows, binaries
        Add-MpPreference -ExclusionProcess "$install\*"        # anything WATCHOUT processes open
        Set-MpPreference -ScanScheduleDay 8                    # 8 = Never
    }
    catch { Write-Warn "Defender preference change failed: $($_.Exception.Message)"; return }

    # Read back instead of trusting the calls.
    $pref = Get-MpPreference
    if (($pref.ExclusionPath -contains $install) -and ($pref.ExclusionPath -contains $work)) {
        Write-Ok "Excluded: $install ; $work ; processes under $install ; scheduled scans off"
    }
    else { Write-Warn 'Exclusions not confirmed on read-back. Check Windows Security > Virus & threat protection > Exclusions.' }
}

function Set-DefenderConfig {
    Write-Step "Microsoft Defender (mode: $DefenderMode)"
    if ($DefenderMode -eq 'Skip') { Write-Ok 'Skipped by request'; return }

    # Fails if the Defender service was disabled/removed (debloat or third-party AV).
    try { $status = Get-MpComputerStatus -ErrorAction Stop }
    catch { Write-Warn "Defender is not running or not available ($($_.Exception.Message)). Skipping Defender configuration."; return }
    $tamper = $status.IsTamperProtected

    Add-DefenderExclusions
    if ($DefenderMode -eq 'Exclusions') { return }

    # ---- Off mode: guide 7.4.8 ----
    if ($tamper) {
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
}

function Invoke-PostInstall {
    Set-PowerConfig
    Set-NicPowerConfig
    Set-NetworkLocation
    Set-NotificationPreferences
    Set-WindowsSettings
    Add-GuidePolicies
    Set-UpdateFreeze
    Set-PerformanceRegistry
    Set-SearchIndexing
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
    Write-Step 'Summary'
    if ($script:Warnings.Count -eq 0) { Write-Ok 'Completed with no warnings. Reboot now.' }
    else {
        Write-Host "  Completed with $($script:Warnings.Count) warning(s):" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
        Write-Host '  Reboot after resolving them.' -ForegroundColor Yellow
    }
    if ($Phase -eq 'PostInstall') {
        Write-Host '  Manual: guide 7.2 "User cannot change location" (secpol.msc > Network List Manager Policies), if wanted.' -ForegroundColor DarkGray
        Write-Host '  After the reboot: Performance Options shows "Adjust for best performance"; Scale = 100 % on every output.' -ForegroundColor DarkGray
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
