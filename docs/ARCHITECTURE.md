# Architecture — WATCHOUT Server Setup Wizard

Status: **proposal for owner review** (Oct 2026). Nothing here is implemented.
Decisions that still need the owner are marked **(decision needed → OQ n)**,
which points to the matching item in `docs/OPEN_QUESTIONS.md`.
Behaviour the docs or scripts flag as **[Uncertain]** stays flagged here.

Sources of truth (unchanged by this document):

| What | Where |
| --- | --- |
| Step order | `docs/checklists/WATCHOUT7-Server-Build-Checklist.md`, `docs/checklists/WATCHOUT6-Server-Build-Checklist.md` |
| What the automation does | `scripts/WO7-Setup.ps1`, `scripts/WO6-Setup.ps1` |
| Why | `docs/PROJECT_CONTEXT.md` |
| Step-by-step wizard flow | `docs/WIZARD_FLOW.md` |

---

## 1. Design principles (from AGENTS.md, restated as design rules)

1. **The checklists define the flow; the scripts define the changes.** The
   wizard adds no Windows tweak of its own. The only things it writes to the
   machine outside the scripts are its own files (`%ProgramData%\WOSetupWizard`:
   state, logs, run folders) and the commands the checklists spell out
   (`pnputil /add-driver …`, `manage-bde -off C:`), each behind a confirmation.
2. **Read back, never assume.** Every automated step ends with a parsed result
   (OK / warnings / fatal) and, where possible, an independent read-only check.
3. **Offline first.** Nothing needs internet except steps the checklist already
   does online (Windows Update, WinUtil), and those are labelled as such.
4. **State survives reboots and power loss.** Atomic writes; the operator
   restarts the exe from the USB stick and it reopens on the current step.
5. **The .ps1 scripts are the engine for now.** They run unmodified under
   Windows PowerShell 5.1. A thin wrapper handles argument passing and output
   encoding (§6). Porting to C# comes later, one function at a time, with
   parity tests.

---

## 2. Technology

| Item | Proposal | Note |
| --- | --- | --- |
| Language / UI | C#, WPF, MVVM | As in AGENTS.md. |
| Runtime | **.NET 10 (LTS)**, `net10.0-windows`, self-contained single-file `win-x64` | **Decided (OQ 1)**; AGENTS.md updated. .NET 8 and .NET 9 reach end of support on **10 Nov 2026**; .NET 10 is LTS until Nov 2028 ([Microsoft .NET blog, 29 Jun 2026](https://devblogs.microsoft.com/dotnet/dotnet-8-9-end-of-support/)). A self-contained .NET 8 exe keeps running after that date but gets no more security fixes. |
| MVVM helpers | `CommunityToolkit.Mvvm` (MIT) | Only third-party runtime dependency proposed. |
| JSON | `System.Text.Json` (in-box) | State, flow definitions, engine params. |
| WMI / CIM | `System.Management` (Microsoft package) | Read-only checks (BIOS, volumes, services). |
| Tests | xUnit (C#), Pester 5 (PowerShell, CI only) | §12. |

Not used: PS2EXE (AV false positives), WebView2 (keep the UI dependency-free;
Edge is kept by the WinUtil selection, but the wizard should not rely on it),
any telemetry or auto-update package.

---

## 3. Solution structure

```
WOSetupWizard.sln
│
├─ src/
│  ├─ WOSetup.Core/            net10.0 (no Windows APIs → unit-testable anywhere)
│  │   Flow/        FlowDefinition, SectionDefinition, StepDefinition (+ 3 subclasses),
│  │                FlowLoader, FlowValidator
│  │   Engine/      WizardEngine, StepNavigator, IStepExecutor<T>,
│  │                AutomatedStepExecutor, ManualStepExecutor, CheckStepExecutor
│  │   Checks/      ICheck, CheckResult, CheckRegistry, ExpectedValue
│  │   Options/     Wo7Options, Wo6Options, OptionsValidator, ScriptArgumentBuilder,
│  │                ConfirmationSummaryBuilder
│  │   Scripts/     EngineOutputParser, EngineEvent, RunResult
│  │   State/       WizardState, StepState, RunRecord, BackupRecord, MachineInfo,
│  │                IStateStore, JsonStateStore, StateMigrator
│  │   Backups/     BackupCatalog, RestoreAction
│  │   Report/      ReportModel, ReportBuilder (M5)
│  │
│  ├─ WOSetup.Windows/         net10.0-windows (everything that touches the OS)
│  │   PowerShell/  PowerShellRunner, EngineWorkspace, PowerShellLocator
│  │   Reboot/      RebootManager, PendingRebootProbe, BootTimeProvider
│  │   Identity/    SessionIdentity (elevated user vs interactive desktop user)
│  │   Checks/      PowerShellJsonCheck, RegistryValueCheck, MonitorDpiCheck, …
│  │   Tools/       LgpoLocator (find + Authenticode-verify LGPO.exe), ToolLauncher
│  │
│  ├─ WOSetup.Assets/          embedded resources only
│  │   engine/      WO7-Setup.ps1, WO6-Setup.ps1  ← linked from /scripts (no copies)
│  │                Invoke-WOEngine.ps1           ← wrapper, §6.3
│  │   flows/       wo7.flow.json, wo6.flow.json  ← step catalogue, §4.3
│  │   text/        Strings.resx (English; Italian later)
│  │
│  └─ WOSetup.App/             net10.0-windows, WPF exe
│      app.manifest, App.xaml, Views/, ViewModels/ (ShellViewModel, StepRailViewModel,
│      AutomatedStepViewModel, ManualStepViewModel, CheckStepViewModel, LogViewModel,
│      OptionsViewModel, BackupsViewModel, ConfirmDialogViewModel, ReportViewModel)
│
├─ tests/
│  ├─ WOSetup.Core.Tests/      xUnit, runs on any OS
│  ├─ WOSetup.Windows.Tests/   xUnit, Windows runner only (wrapper, runner, task XML)
│  └─ pester/                  *.Tests.ps1 for the scripts
│
└─ scripts/                    unchanged; embedded at build time
```

The scripts are embedded with an MSBuild link
(`<EmbeddedResource Include="..\..\scripts\*.ps1" LogicalName="engine/%(Filename)%(Extension)" />`),
so `scripts/` stays the single copy. The SHA-256 of each embedded script is
computed at build time and written into every run record and the report, so a
build report always says exactly which script version ran.

**No business logic in code-behind.** Views bind to view models; view models
call `WizardEngine`; `WizardEngine` uses interfaces implemented in
`WOSetup.Windows`, so the step engine and state can be unit-tested without
Windows.

---

## 4. Step model

### 4.1 Step kinds (one class per kind, as AGENTS.md asks)

| Kind | Class | What the operator sees | Completes when |
| --- | --- | --- | --- |
| **Automated** | `AutomatedStepDefinition` | Summary, options preview, exact command line, **Run** | The run finished (exit 0) **and** the result was reviewed. Warnings → status `DoneWithWarnings`, never silently `Done`. |
| **Manual** | `ManualStepDefinition` | Instructions, optional **Open** button (e.g. `sysdm.cpl`, `ms-settings:display`), optional linked checks, **Mark done** | Operator marks it done. If linked checks fail, marking done asks for a reason, which goes into the state and the report. |
| **Check** | `CheckStepDefinition` | The command shown in the checklist, expected value, **Verify** | The check returns `Pass`. `Warn`/`Fail` keep the step open; the operator may **accept** with a typed reason. |

A manual step can carry checks (e.g. *Tamper Protection Off* → check
`IsTamperProtected = False`). An automated step can carry pre-checks (gate)
and post-checks (read-back).

### 4.2 Common fields

```text
StepDefinition
  Id                 "WO7-09.3"        stable; used as the key in state.json
  Section            "9. PostInstall"  checklist section, for the left rail
  ChecklistRef       line text it implements (for traceability)
  Title, Body        English, from Strings.resx
  Profiles           [WO7] | [WO6]
  Roles              [Display, Production] (default both)
  AppliesWhen        optional hardware/option condition, e.g. "AmdRaidPresent", "DefenderMode == Off"
  PreChecks[]        check ids that must pass (or be accepted) before Run / Mark done
  PostChecks[]       check ids run after
  Confirm            null | ConfirmationSpec   (destructive / security-reducing → explicit confirm)
  Reboot             None | Required | IfPending
  Network            Any | MustBeOffline | NeedsInternet   (shown as a badge)
  Uncertain[]        "[Uncertain] …" notes shown next to the step
  Proposed           true for checks not in the checklist (owner approval pending, see WIZARD_FLOW)
```

```text
AutomatedStepDefinition : StepDefinition
  Action   = EnginePhase { Script: WO7|WO6, Phase: PreUpdate|PostInstall }
           | ChecklistCommand { Template: "pnputil /add-driver {folder}\*.inf /subdirs /install",
                                Inputs: [FolderPicker] }
           | ChecklistCommand { Template: "manage-bde -off C:" }
ManualStepDefinition : StepDefinition
  OpenTargets[]   e.g. "sysdm.cpl", "ms-settings:windowsupdate", "netplwiz"
  TickList[]      for WinUtil: the exact tick list from the checklist
  Captures[]      values the operator types that feed options or the report
                  (e.g. working directory path, tested NVIDIA version, BIOS RAID mode)
CheckStepDefinition : StepDefinition
  CheckId         implemented in code (CheckRegistry)
  DisplayCommand  exact command from the checklist, shown to the operator
  Expectation     e.g. "all False", "= WATCHOUT 7", "three matches"
```

### 4.3 Flow catalogue as data

The step list lives in `flows/wo7.flow.json` and `flows/wo6.flow.json`
(embedded), not in C#. Reasons: the checklists change more often than the
code, the owner can review a diff of the flow, and a unit test can assert
the flow matches the checklist section order. Check **implementations** live
in C# (`CheckRegistry`), referenced by id.

```json
{
  "id": "WO7-05.1",
  "section": "5. Disks",
  "kind": "check",
  "title": "Device encryption is off",
  "checkId": "bitlocker.c.decrypted",
  "displayCommand": "manage-bde -status C:",
  "expectation": "Fully Decrypted",
  "onFail": { "offerStep": "WO7-05.1a" }
}
```

`FlowValidator` (unit-tested) checks: unique ids; every `checkId` exists;
sections in checklist order; no automated step without a confirmation if it
is in the "security-reducing" list; every reboot point is followed by a step
that confirms the reboot happened.

### 4.4 Step status lifecycle

```text
NotStarted ─► InProgress ─► Done
                │      ├──► DoneWithWarnings   (warnings listed, kept in report)
                │      ├──► Failed             (exit ≠ 0 or [FATAL]; may re-run)
                │      ├──► Interrupted        (operator cancelled / power loss during run)
                │      └──► AwaitingReboot ─► (after boot-time check) Done
                ├──► Skipped         (operator, typed reason required)
                └──► NotApplicable   (profile/role/hardware; reason recorded)
```

`StepNavigator` rules:

- The "current step" is the first step not in a final state.
- The operator may **look** at any step, but **Run** on an automated step is
  enabled only if every earlier step is final (Done / DoneWithWarnings /
  Skipped / NotApplicable). This is how "order matters" is enforced
  (PreUpdate before any driver; PostInstall after updates, drivers, WinUtil,
  WATCHOUT).
- An `InProgress` automated step found at startup (power loss / crash) becomes
  `Interrupted`; the UI says the scripts are safe to re-run with the same
  options.

### 4.5 Confirmations ("show before changing")

`ConfirmationSummaryBuilder` turns the current options into plain sentences
before every security-reducing or destructive action, e.g. for WO6 PostInstall
with defaults:

> - Windows Firewall will be turned **off** on all profiles (guide 7.1).
> - Microsoft Defender real-time protection will be turned **off** by policy
>   (Tamper Protection is currently: Off).
> - Windows Update will be **disabled for good**: BITS, wuauserv and UsoSvc
>   disabled, update tasks disabled, SoftwareDistribution emptied.
> - The guide chapter 11 services present on this machine (the script's list
>   has 41) will be **disabled** (list…). Kept: none.
> - On every physical network adapter everything except IPv4 will be
>   **unbound**; file shares and IPv6 stop working on those adapters.
> - Network adapters will briefly lose link. Do not run during a show.
> - Switching an option later does **not** undo what this run applies.

The operator ticks "I have read this" and types the confirmation word
(`APPLY`). For `manage-bde -off C:` the summary states what device
encryption protects against and that decryption runs in the background.
Disk-writing commands (`diskpart clean`, initialising the RAID0) are
**never executed** by the wizard (AGENTS.md rule 7); they stay manual
instructions.

---

## 5. State file

Location: `%ProgramData%\WOSetupWizard\state.json` (AGENTS.md).

### 5.1 Write rules

- Written after every state change, atomically: write `state.json.tmp`,
  flush to disk (`FileStream.Flush(true)`), then `File.Replace` to
  `state.json` keeping `state.json.bak`. A reboot or power cut can never
  leave a half-written file.
- On load: if `state.json` fails to parse, fall back to `state.json.bak` and
  warn.
- `schemaVersion` + `StateMigrator` for later changes.
- No secrets, ever (no passwords; auto-logon is checked by reading
  `AutoAdminLogon`/`DefaultUserName` only).

### 5.2 Schema (version 1)

```json
{
  "schemaVersion": 1,
  "wizard": { "version": "0.1.0", "flowId": "wo7", "flowChecklistDate": "2026-10-14" },
  "machine": {
    "computerNameAtStart": "WO-DISP-01",
    "logFolderName": "WO-DISP-01",
    "model": "ThinkStation P8 30HH",
    "biosVersion": "S0AKT1A",
    "biosReleaseDate": "2026-05-02",
    "biosRaidModeNote": "RAID (typed by operator)",
    "osCaption": "Microsoft Windows 11 Pro",
    "osDisplayVersion": "25H2",
    "osBuild": "26200.xxxx",
    "showAccount": { "name": "show", "sid": "S-1-5-21-…-1001" }
  },
  "profile": "WO7",
  "role": "Display",
  "options": {
    "DefenderMode": "Off",
    "KeepFirewall": false,
    "KeepUpdateService": false,
    "PinVersion": null,
    "WatchoutPath": null,
    "WorkingDirectory": "E:\\WO7-Work"
  },
  "optionsLockedAfter": "WO7-09.3",
  "captures": {
    "nvidiaTestedVersion": "xxx.xx",
    "watchoutVersion": "7.8.4",
    "winutilVersionOrDate": "typed by operator"
  },
  "steps": {
    "WO7-03.2": {
      "status": "Done",
      "startedAt": "2026-10-20T09:12:03+02:00",
      "completedAt": "2026-10-20T09:12:40+02:00",
      "attempts": 1,
      "runIds": ["20261020_091203_PreUpdate"],
      "warnings": [],
      "operatorNote": null,
      "evidence": ["checks/WO7-03.2_post_20261020_091241.json"]
    },
    "WO7-04.2": { "status": "NotApplicable", "reason": "No AMD RAID controller detected; operator confirmed" }
  },
  "runs": [
    {
      "runId": "20261020_091203_PreUpdate",
      "script": "WO7-Setup.ps1",
      "scriptSha256": "…",
      "phase": "PreUpdate",
      "arguments": { "Phase": "PreUpdate" },
      "commandLineShown": ".\\WO7-Setup.ps1 -Phase PreUpdate",
      "folder": "logs\\WO-DISP-01\\runs\\20261020_091203_PreUpdate",
      "lgpo": { "used": true, "source": "bundled", "sha256": "…", "signer": "Microsoft Corporation" },
      "exitCode": 0,
      "fatal": null,
      "warningCount": 0,
      "summaryWarningCount": 0,
      "transcript": "WO7-Setup_PreUpdate_20261020_091203.log",
      "startedAt": "…", "endedAt": "…"
    }
  ],
  "backups": [
    {
      "kind": "LgpoBackup",
      "path": "logs\\WO-DISP-01\\runs\\20261020_091203_PreUpdate\\LGPO_Backup_20261020_091203",
      "runId": "20261020_091203_PreUpdate",
      "isBaseline": true,
      "restoreCommand": "LGPO.exe /g \"<path>\\{GUID}\""
    },
    {
      "kind": "UpdateServicesCsv",
      "path": "…\\UpdateServices_Backup_20261022_150112.csv",
      "runId": "20261022_150112_PostInstall",
      "isBaseline": true,
      "restoreCommand": "Import-Csv '<path>' | ForEach-Object { Set-Service $_.Name -StartupType $_.StartType }"
    }
  ],
  "pendingReboot": {
    "stepId": "WO7-09.5",
    "reason": "PostInstall completed",
    "requestedAt": "2026-10-22T15:20:00+02:00",
    "lastBootAtRequest": "2026-10-22T08:01:55+02:00"
  },
  "finishedAt": null
}
```

Notes:

- `isBaseline`: the **first** backup of each kind. A re-run of PostInstall
  backs up the *already modified* state (e.g. services already `Disabled`),
  so restoring the latest CSV would restore "Disabled". **Restore actions
  always use the baseline** (decided, OQ 15). Later backups are kept in their
  run folders and the support bundle, but are not offered for restore.
- `optionsLockedAfter`: once that step has run, the options page shows a
  banner: *changing an option and re-running does not undo what the earlier
  run applied* (PROJECT_CONTEXT §5 "Re-running"). Options stay editable, but
  the confirmation summary then lists what will **not** be reverted.
- Paths are stored relative to `%ProgramData%\WOSetupWizard` so the folder
  can be copied with the support bundle.

---

## 6. Running the PowerShell engine under Windows PowerShell 5.1

### 6.1 Constraints found in the scripts

| Fact (from the scripts) | Consequence for the wizard |
| --- | --- |
| `#requires -RunAsAdministrator`; elevated. | The wizard itself is elevated (manifest, §9), child inherits the token. |
| Transcript, `lgpo_<phase>.txt`, `LGPO_Backup_*`, `Services_Backup_*.csv`, `UpdateServices_Backup_*.csv` are written to **`$PSScriptRoot`**. LGPO.exe is looked up in **`$PSScriptRoot`**. | Each run gets its own folder; script + LGPO.exe are copied there. Everything a run produces lands in one place, which is also where backups are kept for good. |
| HKCU values and the WO6 `WATCHPOINT auto-start` task use **the account running the script** (`$env:USERNAME`). | The elevated token's user must be the interactive (show) user. Checked before every engine run (§10). |
| Status is printed with `Write-Host` and fixed prefixes: `=== `, `  [OK]   `, `  [WARN] `, `  [--]   `, `  [i]    `, and a final "Completed with N warning(s):" list. | Output is parsed line-by-line (§6.4). |
| Exit code is 0 when the script finishes, even with warnings; an uncaught `throw` (e.g. "LGPO import failed") ends the script. | Warnings come from parsing, not from the exit code; a throw is caught by the wrapper → exit 2. |
| WO6 `-KeepService` is `[string[]]`. With `powershell.exe -File …`, `-KeepService TermService,SessionEnv` is passed as **one string** `"TermService,SessionEnv"`, so `$KeepService -contains 'TermService'` is false and RDP services would be disabled. | Do **not** pass options on the command line. The wrapper reads a JSON file and **splats** (§6.3). Covered by a test in M2. |
| Paths such as `C:\WATCHOUT 6` contain spaces. | Same: JSON + splatting avoids quoting bugs. |
| PS 5.1 only (no `??`, no ternary). | Wrapper written for 5.1, parse-checked in CI. |

### 6.2 Invocation

```text
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
    -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass
    -File "<runFolder>\Invoke-WOEngine.ps1"
    -Script "<runFolder>\WO7-Setup.ps1"
    -ParamsJson "<runFolder>\params.json"
```

- Full path to the **64-bit** Windows PowerShell 5.1 (the app is x64, so no
  SysWOW64 redirection). Never `pwsh.exe`.
- `-ExecutionPolicy Bypass` is overridden by a `MachinePolicy`/`UserPolicy`
  execution policy set by GPO; the pre-flight check reads
  `Get-ExecutionPolicy -List` and blocks with an explanation if one is set.
- `ProcessStartInfo`: `UseShellExecute=false`, redirected stdout/stderr,
  `StandardOutputEncoding = UTF-8`, `CreateNoWindow=true`, working directory =
  run folder.
- Streams are read asynchronously line-by-line and pushed to the UI and to
  `stdout.log` / `stderr.log` as they arrive (live log).
- **No timeout.** `gpupdate /force` and service changes can take minutes.
  **Cancel** asks for confirmation, then kills the process tree; the step
  becomes `Interrupted` and the UI says a re-run with the same options is safe.

### 6.3 Wrapper `Invoke-WOEngine.ps1` (sketch, 5.1-compatible)

Plumbing only, no tweaks. It exists for three reasons: correct binding of
arrays/switches/paths, UTF-8 output, and a clear exit code.

```powershell
# Sketch for review — not final code.
param(
    [Parameter(Mandatory)] [string]$Script,
    [Parameter(Mandatory)] [string]$ParamsJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Child output is read as UTF-8 by the wizard. Without this, PS 5.1 writes
# redirected output in the OEM code page and accented text (e.g. Italian
# Windows error messages) arrives garbled.
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Build a splat table from JSON: bool -> [switch], array -> [string[]].
# Splatting binds arrays correctly; "-File ... -KeepService a,b" would not.
$splat = @{}
foreach ($p in (Get-Content -Raw -LiteralPath $ParamsJson | ConvertFrom-Json).PSObject.Properties) {
    $v = $p.Value
    if ($v -is [bool])         { $splat[$p.Name] = [switch]$v }
    elseif ($v -is [object[]]) { $splat[$p.Name] = [string[]]$v }
    elseif ($null -ne $v)      { $splat[$p.Name] = $v }
}

try   { & $Script @splat; exit 0 }
catch { Write-Host "[FATAL] $($_.Exception.Message)"; exit 2 }
```

Exit codes the wizard understands: `0` finished (look at warnings), `2` the
script threw (`[FATAL]` line has the reason), anything else = PowerShell
could not start (shown with stderr).

**To verify on Windows in M2** (not assumed): that `Write-Host` output from a
child script reaches redirected stdout in this setup, that the encoding
switch takes effect for it, and that `Start-Transcript` inside the script
still records everything when invoked through the wrapper.

### 6.4 Output parser

`EngineOutputParser` (pure, unit-tested on captured real transcripts):

| Line pattern | Event | UI |
| --- | --- | --- |
| `=== <title>` | `StepHeader` | New group in the live log |
| `  [OK]   <msg>` | `Ok` | Green |
| `  [WARN] <msg>` | `Warning` | Yellow, also collected in the warnings panel |
| `  [--]   <msg>` | `NotPresent` | Grey (e.g. "no EEE property exposed") |
| `  [i]    Restore: <cmd>` / `Undo per adapter: <cmd>` | `RestoreHint` | Stored as a `BackupRecord`/`RestoreAction` |
| `[OK] Local GPO backed up to <path>` | `Backup(LgpoBackup)` | Stored as a `BackupRecord` |
| `Completed with N warning(s):` + `   - <msg>` | `Summary` | Compared with the count of `[WARN]` lines |
| `Completed with no warnings.` | `Summary(0)` | |
| `[FATAL] <msg>` | `Fatal` | Red; step `Failed` |
| anything else | `Text` | Plain (e.g. `gpupdate`, `powercfg /a` output) |

"Never pretend": if the summary count and the parsed `[WARN]` count differ,
or the summary line is missing while the exit code is 0, the step becomes
`DoneWithWarnings` with "Output could not be fully interpreted — read the
transcript". After the run, `BackupCatalog` also scans the run folder for
`LGPO_Backup_*`, `*_Backup_*.csv` so a backup is recorded even if a line was
missed.

**Decided (OQ 2):** the scripts get an optional `-ResultPath <file>`
parameter (script change S2) and write a JSON result at the end. When it is
present the wizard uses it as the primary source; the text parser above stays
as the live-log view and as a cross-check (a mismatch is shown as a warning).

### 6.4a Audit mode (decided OQ 10, script change S4)

Both scripts get a read-only `-Audit` switch, valid with either phase and
with the same options as a real run:

```text
.\WO7-Setup.ps1 -Phase PostInstall -Audit [same options] [-ResultPath <file>]
```

For every item the phase would apply (registry value, Local GPO policy,
service start type, scheduled task, power setting, adapter property/binding,
firewall rule, Defender setting) it prints one line and records it in the
result file:

| Line | Meaning |
| --- | --- |
| `  [SET]     <item>` | Current value already equals what the script applies with these options. |
| `  [NOT SET] <item> (current: <value>)` | Different or missing; a real run would change it. |
| `  [N/A]     <item> (<reason>)` | Not applied with these options or on this hardware, e.g. `-KeepFirewall`, `-Role Production`, no AMD GPU. *(Decided, OQ 24.)* |

Rules:

- **Effective state, not just the registry** ("never pretend"): e.g.
  Defender Off is `[SET]` only if the policy is present **and**
  `Get-MpComputerStatus` shows real-time protection off; with Tamper
  Protection on it is `[NOT SET] (Tamper Protection on)`.
- User-scope policies: read from the Local GPO (`LGPO.exe /parse` of the User
  `Registry.pol`) and from the running account's HKCU.
- One-off actions that are not a lasting setting (empty
  `SoftwareDistribution`, `gpupdate`) are reported as `[N/A] (action)`.
- An audit writes nothing: no transcript side effects beyond its own log,
  no LGPO backup, no `gpupdate`.

To keep audit and apply from drifting apart, S4 restructures each script
section so the desired value is defined once and used by both. Behaviour of
a normal run must not change: verified by comparing the end state of a VM
checkpoint before/after S4 (MILESTONES).

The wizard runs the audit before PreUpdate/PostInstall (the confirmation
summary lists only the `[NOT SET]` items as "will change") and again after
the PostInstall reboot as the final verification.

### 6.5 LGPO.exe

**Decided (OQ 3): LGPO.exe is bundled** as an embedded resource, so the
wizard is one exe. The licence terms ("Microsoft Security Compliance Toolkit –
Standalone Use Terms.pdf" in the LGPO download) are still unread and stay
**[Uncertain]**; the owner has chosen to bundle for his own use.

- **Not committed to git.** The build takes it from `third_party/LGPO/LGPO.exe`
  (git-ignored). Locally the owner puts it there; CI downloads `LGPO.zip`
  from Microsoft's download page and checks a pinned SHA-256. The build fails
  if the file is missing or the hash or Microsoft signature does not match.
- At runtime it is extracted into each run folder next to the script (the
  scripts look in `$PSScriptRoot`) and its signature/SHA-256 is checked again
  (W-00.2). If that check fails the wizard stops before any engine run.
- The script fallback without LGPO.exe stays possible only as an explicit
  override, with the limits spelled out (*policies written directly to the
  registry, not visible in gpedit, User-scope policies reach only the current
  account*).

---

## 7. Resume after reboot

**Decided (OQ 23, option C): portable, no auto-start.** The exe runs from the
USB stick and is never copied to the machine; no scheduled task is created.

### 7.1 How the operator continues after a reboot

- Before every reboot point the wizard says: *"After the restart, sign in and
  start WOSetupWizard.exe from the USB stick again."*
- On start, the exe reads `%ProgramData%\WOSetupWizard\state.json` (state
  and logs always live on the machine, never on the stick) and opens on the
  current step. Any copy of the exe resumes, so the stick's drive letter and
  which stick it is do not matter.
- The exe asks for elevation (UAC) at each start, as the manifest requires.
  After WO6 PostInstall sets UAC to "Never notify" there is no prompt any more.
- Version check: a newer exe migrates an older `state.json` (`StateMigrator`);
  an older exe refuses a `state.json` with a newer `schemaVersion` and says
  which version to use.
- A named mutex (`Global\WOSetupWizard`) stops two windows opening if the
  exe is started twice.

### 7.2 What this removes from the earlier design

No `SelfInstaller`, no `\WOSetupWizard\Resume` task, no
`%ProgramData%\WOSetupWizard\bin` folder and no folder-ACL hardening (that
was only needed because an elevated task would have run a file from disk).
Finish only marks the build complete and produces the report.

This deviates from the original AGENTS.md wording ("resume at the next
logon"); AGENTS.md has been updated to match.

### 7.3 Confirming a reboot really happened

Before a reboot point the wizard stores `pendingReboot` with the current
`Win32_OperatingSystem.LastBootUpTime`. It offers **Reboot now**
(`shutdown.exe /r /t 10 /c "WATCHOUT setup wizard: rebooting"`) or **I will
reboot later**. On the next start:

- `LastBootUpTime` newer than stored → reboot confirmed, step `Done`, advance.
- Not newer → "The machine has not restarted yet" (the step stays
  `AwaitingReboot`).

Read-only pending-reboot probe (shown as a hint, used for Windows Update and
driver installers): `HKLM\…\Component Based Servicing\RebootPending`,
`HKLM\…\WindowsUpdate\Auto Update\RebootRequired`,
`HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations`.

### 7.4 WATCHPOINT and the wizard after a reboot (WO6)

Because the wizard does not start by itself, it cannot cover WATCHPOINT: after
the WO6 PostInstall reboot the operator first watches WATCHPOINT start full
screen on its own (WO6-10.1), then starts the wizard from the stick. (This
replaces the OQ 17 "start minimised" plan.)

---

## 8. Logging

```
%ProgramData%\WOSetupWizard\
  state.json, state.json.bak
  logs\<COMPUTERNAME at first run>\
    wizard.log                         app log, one line per event, local time + UTC offset
    runs\<yyyyMMdd_HHmmss>_<Phase>\    one folder per engine run
      Invoke-WOEngine.ps1, WO7-Setup.ps1 (copies, SHA-256 in state), LGPO.exe (copy)
      params.json                      exact arguments
      stdout.log, stderr.log           as captured by the wizard
      result.json                      parsed events, counts, exit code
      WO7-Setup_<Phase>_<stamp>.log    script transcript (written by the script)
      lgpo_<Phase>.txt                 LGPO text file (written by the script)
      LGPO_Backup_<stamp>\             Local GPO backup (written by the script)
      UpdateServices_Backup_<stamp>.csv, Services_Backup_<stamp>.csv (WO6)
    checks\<StepId>_<stamp>.json       evidence: command shown, raw output, result
    commands\<StepId>_<stamp>.log      pnputil / manage-bde output
```

- The folder name is fixed at first run, so renaming the computer later does
  not split the logs.
- **Export support bundle**: a zip of `state.json` + the machine log folder
  (without `LGPO.exe` copies) + a read-only system snapshot (`Win32_OperatingSystem`,
  `Win32_BIOS`, `Win32_VideoController`, `pnputil /enum-drivers`,
  `powercfg /list`, `Get-MpComputerStatus`, `Get-NetAdapter`, `Get-Service`),
  saved where the operator chooses (normally the USB stick). Nothing is sent
  anywhere.
- No telemetry, no update check, no network calls by the app (AGENTS.md rule 5).

---

## 9. Elevation manifest (`app.manifest`)

```xml
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="WOSetupWizard.app"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <!-- Always elevated: every step either changes the machine or reads
             protected state (Defender, BitLocker, services). -->
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <!-- Windows 10 / 11 -->
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <!-- Per-monitor DPI awareness: needed so the "Scale 100 % on every
           output" check can read each monitor's real DPI. -->
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
</assembly>
```

Publishing (`WOSetup.App.csproj`): `PublishSingleFile=true`,
`SelfContained=true`, `RuntimeIdentifier=win-x64`,
`IncludeNativeLibrariesForSelfExtract=true` (WPF native libraries extracted
to the user's temp folder at first start), `EnableCompressionInSingleFile=true`,
`PublishTrimmed=false` (WPF does not support trimming). Expect an exe in the
tens of MB **[Uncertain exact size until the first build]**.

---

## 10. Pre-flight checks before any engine run

Run at first launch and again right before PreUpdate and PostInstall:

| Check | How (read-only) | On failure |
| --- | --- | --- |
| Elevated | `WindowsPrincipal.IsInRole(Administrators)` | Cannot happen with the manifest; abort if it does. |
| Show account = elevated user | Elevated token SID vs the user owning the interactive session (`WTSQuerySessionInformation` on the active console session) | **Block**: HKCU settings and the WO6 WATCHPOINT task would go to the wrong account. |
| Windows PowerShell 5.1 present | `powershell.exe -Command $PSVersionTable.PSVersion` | Block. |
| Execution policy not forced by GPO | `Get-ExecutionPolicy -List` (MachinePolicy/UserPolicy = Undefined) | Block with explanation. |
| OS | `Win32_OperatingSystem` caption/build, `DisplayVersion` | Warn if not Windows 11 Pro 24H2/25H2. |
| LGPO.exe (bundled) | §6.5: signature + SHA-256 of the extracted copy | Block. |
| Network state (PreUpdate only) | `Get-NetAdapter -Physical` status | Warn if a physical adapter is Up (checklist: cable unplugged). |
| Tamper Protection (PostInstall, DefenderMode Off) | `Get-MpComputerStatus` `IsTamperProtected` | Block until off, or the operator accepts that the script will skip the real-time policies (it warns too). |

These checks are part of the step model (pre-checks), not a separate system.
Checks not written in the checklists are marked **proposed** in
`docs/WIZARD_FLOW.md` and need owner approval.

---

## 11. Check implementation strategy

- First version: most checks run the checklist's own command (or the
  closest **language-independent** equivalent) through the same
  `PowerShellRunner`, ending in `| ConvertTo-Json`, and evaluate the JSON in
  C#. The operator always sees the checklist command.
- Language independence matters: `manage-bde` and `powercfg` print localised
  text (an Italian Windows prints Italian status strings). So:
  - BitLocker: evaluate `Get-BitLockerVolume -MountPoint C:`
    (`VolumeStatus`, `ProtectionStatus`), show `manage-bde -status C:`.
  - Power plan: match the plan **GUID** in `powercfg /getactivescheme`
    (`6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e57` = WATCHOUT 7,
    `6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e56` = WATCHOUT 6), not the name.
  - `pnputil /enum-drivers`: match the `.inf` original file names, which are
    not localised.
- Later, checks can be ported to native C# (WMI, registry) without changing
  the flow file, because steps reference checks by id.

---

## 12. Testing

| Layer | Tooling | Runs where |
| --- | --- | --- |
| Step engine, navigator, state round-trip/migration, atomic write, option → splat mapping, confirmation text, output parser (real captured transcripts as fixtures), flow validator | xUnit | Any OS, CI |
| Wrapper (`-KeepService` array, switches, paths with spaces, UTF-8, exit codes) with a dummy script; task XML generation; runner streaming | xUnit, Windows | GitHub Actions `windows-latest` (has Windows PowerShell 5.1) |
| Parse-check of every `.ps1` | `[System.Management.Automation.Language.Parser]::ParseFile` in `powershell.exe` | CI |
| Pure script functions (`Get-WatchoutInstallPath`, `Add-Policy` de-duplication, LGPO text rendering, audit comparison) | Pester 5. Functions are loaded from the script's AST (`FunctionDefinitionAst`) so the test does not run the script's top level (`Start-Transcript`, mandatory `-Phase`). LGPO text rendering is inline in `Invoke-PolicyApply` today; testing it alone needs a small refactor (OQ 2, explained there). | CI |
| Real changes | Windows 11 Pro 25H2 VM with snapshots (Hyper-V), then real hardware (ThinkStation P8 / MegaRAID box) | Manual, recorded per milestone. **Nothing is claimed to work without this.** |

---

## 13. What the app deliberately does not do

- Run `diskpart`, initialise/format disks, touch RAID arrays or RAID drivers.
- Change WATCHOUT/Dataton services or CodeMeter.
- Change BIOS, NVIDIA Control Panel, Tamper Protection, display scale,
  netplwiz auto-logon (guides + checks only).
- Re-implement WinUtil tweaks. For now WinUtil is run by the operator
  (online launch or a local offline copy, OQ 4); the owner may later move a
  chosen subset of WinUtil tweaks into the scripts.
- Contact the network, except where the operator explicitly starts an
  online step (Windows Update in Settings, the optional online WinUtil launch).
