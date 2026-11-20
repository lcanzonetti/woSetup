# Architecture — WATCHOUT Server Setup Wizard

Status: implemented as described, except where marked (Oct 2026). Section 4
was rewritten for the "check and do" redesign (Oct 2026).
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

> **As built in version 0.1:** two projects instead of four. `WOSetup.Core`
> (as below, plus `Engine/WizardSession` holding every state change) and
> `WOSetup.App` (WPF app; also holds what was planned as `WOSetup.Windows`:
> `Services/` for the PowerShell runner, run folders, paths, dialogs, support
> bundle; and the embedded scripts + `Engine/Invoke-WOEngine.ps1`). The flow
> JSON is embedded in Core. A separate Windows project can be split out when
> the native checks (M3) arrive.

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

Redesign (owner, Oct 2026): the wizard starts on a machine where Windows is
already installed (BIOS, RAID arrays and Windows Setup are done before it;
the old checklist sections "Before you start" and "Install Windows" are
gone). It **performs** what can be automated, after a confirmation, and
waits for the operator on the rest. Every step that can be checked is
checked, so the wizard also works on machines prepared earlier, by hand.

### 4.1 Step kinds (one class per kind, as AGENTS.md asks)

| Kind | Class | What the operator sees | Completes when |
| --- | --- | --- | --- |
| **Automated** | `AutomatedStep` | What the wizard will do, **Do it** / **Run PreUpdate** / **Restart now** | The action finished and its read-back (the step's check) agrees. Warnings → `DoneWithWarnings`, never silently `Done`. |
| **Manual** | `ManualStep` | Instructions, **Open** buttons (e.g. `ncpa.cpl`), **Mark done** | The operator marks it done. If the step has a check, it runs first; a "not done" answer needs an explicit "mark done anyway", recorded in the note. |
| **Check** | `CheckStep` | **Check now** | The check returns Done (or Not applicable). |

### 4.2 Fields (`Flow/FlowModels.cs`)

```text
StepDefinition
  Id            "WO7-07.4"   stable key in state.json
  Title, Details
  Check         read-only test telling whether the step is already done:
                  an id in Engine/WO-Checks.ps1 ("bitlocker-off", "tamper-off"...),
                  a native check ("lgpo", "display-scale"), or
                  "audit:PreUpdate" | "audit:PostInstall" | "audit:Both" (the scripts' -Audit)
  Action        automated steps only:
                  { type: script,  phase: PreUpdate|PostInstall }
                  { type: command, name: bitlocker-off|media-disk-init|indexing-off|static-ip|wol-enable|
                                         recovery-install|recovery-capture|recovery-export }
                  { type: restart } | { type: finish }
  After         "only needed when step X is performed now" (restart after PostInstall,
                read its warnings, review options). If X is found already done by a
                check, this step becomes Not applicable ("Not needed: ...").
  Roles, NeedsInternet, MustBeOffline, Confirm, Uncertain, OptionsStep, AutoDone,
  Informational (a check that is done once it ran: the audit before PostInstall)
```

### 4.3 Flow catalogue as data

`tools/flowgen/generate_flows.py` is the source of the step lists. It writes
`src/WOSetup.Core/Flows/wo7.flow.json`, `wo6.flow.json` (embedded) and
`docs/WIZARD_FLOW.md`. `FlowValidator` (unit-tested) checks: unique ids,
section order, automated steps have an action and only they do, check steps
have a check, valid audit phases and command names, `after` targets exist,
exactly one PreUpdate and one PostInstall run, PreUpdate before PostInstall.

### 4.4 Step status lifecycle

```text
NotStarted ─► InProgress ─► Done | DoneWithWarnings | Failed | Interrupted
     │                └──► AwaitingReboot ─► (boot time moved) Done
     ├──► Done (found by the check)     ── check says Done
     ├──► NotDone                        ── check says the goal is missing
     ├──► Skipped (reason)  /  NotApplicable (reason, role, check or "not needed")
```

How a check result changes a step (`WizardSession.ApplyCheck`):

| Check says | Step becomes |
| --- | --- |
| Done | Done, flagged "found by the check", unless already final |
| Not done | NotDone, also when it was Done before (the machine no longer matches) |
| Not applicable | NotApplicable with the reason, unless already final |
| Can't check | unchanged; the detail is shown |

Skipped / NotApplicable set by the operator, role-based NotApplicable, and
running or rebooting steps are never changed by a check.

### 4.5 Check this machine, Fix what's missing

- **Check this machine** (also "Start and check" on the start screen): runs
  every check of the role's steps (`CheckPlan`: native checks, one
  WO-Checks.ps1 session for the rest, then the PreUpdate and PostInstall
  audits), applies the results, then the `after` rules, and shows a summary:
  found done / not done / can't tell / open steps without a check. Nothing is
  changed on the machine.
- Open manual steps without a check (WinUtil, NVIDIA Control Panel...) can be
  ticked in one list ("Manual steps done…") when the operator knows they were
  done earlier.
- **Fix what's missing** walks the open steps in checklist order: automatic
  steps → "Do it / Skip for now / Stop", then the action's own confirmation
  (section 4.6); manual steps → instructions, Open buttons, "Done – check it";
  check steps → checked, with "Check again" on failure; restart steps →
  "Restart now" (the walk resumes after the restart with the same button).

### 4.6 Confirmations ("show before changing")

Every automatic step shows a plain-language summary first
(`ConfirmationSummaryBuilder` for the scripts, `ActionSummaryBuilder` for the
actions). A typed word is required where the step reduces security or writes
to a disk:

| Step | Typed word |
| --- | --- |
| PostInstall when it turns the firewall or Defender off, or disables Windows Update | `APPLY` |
| BitLocker off | `DECRYPT` |
| Media drive initialise + format | `DISK <n>` (the disk number) |
| Static IP | `APPLY` |
| Indexing off, Wake on Magic Packet, PreUpdate | plain confirmation |
| Install the recovery boot (boot configuration, recovery partition) | `BOOT` |
| Capture the factory image (restarts into WinPE, replaces the fallback image) | `CAPTURE` |
| Restore in the WinPE recovery menu (formats C: and D:) | `RESTORE` (also `CAPTURE` for a capture started there) |
| Copy the factory image off the machine | plain confirmation |
| `tools/recovery/New-RecoveryUsb.ps1` (erases a USB stick; technician PC) | `USB <n>` (the disk number) |

The media-drive action only accepts a disk without any partition table
(RAW) that is not the boot/system disk and not USB; the script checks this
again just before writing (AGENTS.md rule 7). `diskpart clean` is never run.

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
- No secrets, ever (no passwords; auto-logon is not checked, owner
  decision OQ 25).

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

**Implemented (S2, OQ 2):** both scripts take an optional
`-ResultPath <file>` and write a JSON summary when the run ends, whether it
completed or failed. The wizard uses it as the primary source; the text
parser above stays for the live log and as a cross-check (a mismatch is
shown as a warning). Format (UTF-8 without BOM; example from an apply run):

```json
{
  "schemaVersion": 2,
  "script": "WO6-Setup.ps1",
  "phase": "PostInstall",
  "mode": "Apply",
  "status": "Completed",
  "fatal": null,
  "startedAt": "2026-10-27T10:02:11.5330000+01:00",
  "endedAt": "2026-10-27T10:04:52.1020000+01:00",
  "computerName": "WO-DISP-01",
  "userName": "WO-DISP-01\\show",
  "parameters": { "Phase": "PostInstall", "Role": "Display", "DefenderMode": "Off",
                  "KeepFirewall": false, "KeepServices": false,
                  "KeepService": ["TermService", "SessionEnv", "UmRdpService"],
                  "KeepAdapterBindings": false,
                  "KeepUpdateService": false, "ForcePcieLinkSpeed": false,
                  "StartDelay": 8, "WatchoutPath": null, "ShowsPath": null },
  "warnings": ["Tamper Protection is ON: ..."],
  "backups": [
    { "Kind": "ServicesCsv", "Path": "...\\Services_Backup_20261027_100211.csv",
      "Restore": "Import-Csv '...' | ForEach-Object { Set-Service $_.Name -StartupType $_.StartType }" },
    { "Kind": "AdapterBindings", "Path": "", "Restore": "Enable-NetAdapterBinding -Name \"Ethernet\" -AllBindings" },
    { "Kind": "UpdateServicesCsv", "Path": "...", "Restore": "..." },
    { "Kind": "LgpoBackup", "Path": "...\\LGPO_Backup_20261027_100211",
      "Restore": "LGPO.exe /g \"...\\LGPO_Backup_20261027_100211\\{GUID}\"" }
  ],
  "lgpo": { "used": true, "textFile": "...\\lgpo_PostInstall.txt" },
  "transcript": "...\\WO6-Setup_PostInstall_20261027_100211.log"
}
```

- `status`: `Completed` (finished; look at `warnings`) or `Failed` (the
  script threw; `fatal` has the message and the script still exits with the
  same error as before).
- `backups[].Kind`: `LgpoBackup`, `UpdateServicesCsv`, `ServicesCsv` (WO6),
  `SearchServiceCsv` (WO7), `AdapterBindings` (WO6, restore command only).
- `parameters` lists every option with its effective value, defaults included.
- Writing the file can never change the run: if it fails, a
  `[WARN] Result file not written` line is printed and the run continues.
- The wrapper (§6.3) passes `ResultPath` in `params.json` like any option.
- **Schema 2** (with the audit mode): adds `mode` (`Apply` | `Audit`) and
  `audit[]`, one entry per audit line: `{ "Section", "Item", "State"
  (Set | NotSet | NA), "Detail" }`. `parameters` also lists `Audit`.

### 6.4a Audit mode (implemented, OQ 10)

Both scripts have a read-only `-Audit` switch, valid with either phase and
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
- Policies: each queued policy is compared with the value Windows reads,
  HKLM for Computer policies and the running account's HKCU for User
  policies (where LGPO + gpupdate put them). Other accounts get User
  policies at their next sign-in and are not checked.
- One-off actions that are not a lasting setting (emptying
  `SoftwareDistribution`) are reported as `[N/A] (one-off action)`.
- An audit writes nothing: no LGPO backup, no `gpupdate`, no CSV backups.
  It writes only its own transcript (`<script>_<Phase>_Audit_<stamp>.log`)
  and, if asked, the `-ResultPath` file.
- The `[OK]` lines of a real run are not printed in audit mode; warnings are.
  The run ends with an "Audit summary" (counts of Set / Not set / N/A)
  instead of "Completed with N warning(s)".

How audit and apply share one definition of each value:

- `Set-RegDword` and the new `Set-RegValue` (string/binary values) compare
  instead of writing when `-Audit` is set, so every registry value the
  scripts write is audited from the same line of code.
- `Invoke-PolicyApply` compares the queued policies (`Test-QueuedPolicies`)
  instead of importing them; policies are queued by the same functions.
- Functions that change other things (power plan, adapters, network
  category, services, scheduled tasks, firewall rules, Defender
  preferences, sound scheme) have a short audit branch that reads the same
  local lists (`$settings`, `$names`, `$taskPaths`, `$unbind`, `$list`) the
  apply code uses.

Known limits, flagged **[Uncertain]** until run on a VM: power settings are
read from `powercfg /query` output by position (the last two `0x` values =
current AC/DC), not by its localised labels; update scheduled tasks that
Windows protects stay "enabled", so that line can stay `[NOT SET]` after a
correct run (its detail says so).

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
      UpdateServices_Backup_<stamp>.csv, Services_Backup_<stamp>.csv (WO6),
      SearchService_Backup_<stamp>.csv (WO7)
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

- `src/WOSetup.App/Engine/WO-Checks.ps1` (Windows PowerShell 5.1): one
  script block per check id, each returning Done / NotDone / NotApplicable /
  CantCheck with a detail. Every check is wrapped in try/catch: an error is
  CantCheck, never Done. The wizard runs all needed ids in one PowerShell
  session (`-Ids a,b,c`, one string because `-File` does not bind arrays).
- The script settings themselves (policies, registry, services) are checked
  by the scripts' own `-Audit`, not duplicated in WO-Checks.ps1.
- Native C# checks: `lgpo` (LGPO.exe bundled or next to the exe) and
  `display-scale` (per-monitor DPI via `GetDpiForMonitor`; the app is
  per-monitor DPI aware, so 96 DPI = 100 %).
- Language independence: BitLocker via `Win32_EncryptableVolume`
  (`GetConversionStatus`, `ProtectionStatus`), power plan by GUID
  (`…0e57` = WATCHOUT 7, `…0e56` = WATCHOUT 6), drivers by `.inf` original
  names from `pnputil /enum-drivers`, services by name.
- Some steps cannot be told from Windows (whether Windows Update has more
  to install, WinUtil, NVIDIA Control Panel): their check is CantCheck or
  absent, and the operator confirms.
- `[Uncertain]` checks are listed in OPEN_QUESTIONS 25.

### 11.1 Wizard actions (`Engine/WO-Actions.ps1`)

The checklist steps the owner chose to automate (Oct 2026) besides the two
setup scripts: `bitlocker-off`, `media-disk-init`, `indexing-off`,
`static-ip`, `wol-enable`, plus two read-only queries for the input dialogs
(`list-disks`, `list-adapters`). Each prints the scripts' `[OK]`/`[WARN]`
lines, reads back what it changed, and writes `{ Status, Warnings, Data }`.
After an action the wizard also runs the step's check, so a BitLocker
decryption still in progress shows as "not done" with its percentage.

Factory recovery (owner, Nov 2026; OPEN_QUESTIONS 29): `recovery-install`,
`recovery-capture`, `recovery-export` and the query `list-recovery-usb`.
The wizard extracts `recovery/partition/WO-Recovery.ps1` (embedded as
`engine/WO-Recovery.ps1`) next to `WO-Actions.ps1`; the actions copy it to
the recovery partition and dot-source its image-set helpers, so Windows and
WinPE share one definition of an image set. See §14.

---

## 12. Testing

| Layer | Tooling | Runs where |
| --- | --- | --- |
| Step engine, navigator, state round-trip/migration, atomic write, option → splat mapping, confirmation text, output parser (real captured transcripts as fixtures), flow validator | xUnit | Any OS, CI |
| Wrapper (`-KeepService` array, switches, paths with spaces, UTF-8, exit codes) with a dummy script; task XML generation; runner streaming | xUnit, Windows | GitHub Actions `windows-latest` (has Windows PowerShell 5.1) |
| Parse-check of every `.ps1` | `[System.Management.Automation.Language.Parser]::ParseFile` in `powershell.exe` | CI |
| Pure script functions (`Get-WatchoutInstallPath`, `Add-Policy` de-duplication, LGPO text rendering, audit comparison) | Pester 5. Functions are loaded from the script's AST (`FunctionDefinitionAst`) so the test does not run the script's top level (`Start-Transcript`, mandatory `-Phase`). LGPO text rendering is `ConvertTo-LgpoText` since S2. Tests: `tests/pester/ScriptFunctions.Tests.ps1` (both scripts). | CI |
| Real changes | Windows 11 Pro 25H2 VM with snapshots (Hyper-V), then real hardware (ThinkStation P8 / MegaRAID box) | Manual, recorded per milestone. **Nothing is claimed to work without this.** |

---

## 13. What the app deliberately does not do

- Run `diskpart`, touch RAID arrays or RAID drivers, or format any disk
  other than an empty (RAW) non-system disk the operator picked and
  confirmed by typing its number. **Exception (owner, Nov 2026):** the
  factory recovery (§14) writes to the hidden `WO_RECOVERY` partition and
  the boot configuration (typed `BOOT`, BCD backed up first), and its WinPE
  side formats C: and D: on a restore (typed `RESTORE`). The wizard itself
  never formats C: or D: and never creates or resizes partitions (the
  recovery partition is made in Windows Setup).
- Change WATCHOUT/Dataton services or CodeMeter.
- Change BIOS, NVIDIA Control Panel, Tamper Protection, display scale,
  auto-logon (guides, plus checks where one exists). Install Windows
  updates, drivers, the NVIDIA driver or WATCHOUT (manual, decided Oct
  2026). No checks for auto-logon, the WATCHOUT 7 install, CodeMeter or
  RAID drivers/apps (owner decision, OQ 25).
- Re-implement WinUtil tweaks. For now WinUtil is run by the operator
  (online launch or a local offline copy, OQ 4); the owner may later move a
  chosen subset of WinUtil tweaks into the scripts.
- Contact the network, except where the operator explicitly starts an
  online step (Windows Update in Settings, the optional online WinUtil launch).

---

## 14. Factory recovery (owner, Nov 2026; OPEN_QUESTIONS 29)

A factory reset returns the machine to the end of the build: Windows and
WATCHOUT freshly installed and tweaked. Shows and assets are not kept.

| Part | Where | Runs on |
| --- | --- | --- |
| Partition `WO_RECOVERY` (type Recovery, no letter, 45 GB suggested, larger is fine) | made with DiskPart in Windows Setup (PROJECT_CONTEXT §2a) | Windows Setup |
| WinPE build (WinPE-WMI, -NetFX, -Scripting, -PowerShell, -StorageWMI, -DismCmdlets, RAID drivers, `startnet.cmd`, `X:\WORecovery\Start-WORecovery.ps1`) | `tools/recovery/Build-WinPE.ps1` -> `WOSetupRecovery\` next to the wizard exe | technician PC with the ADK |
| Recovery menu: capture / restore / last result / bcdboot / cmd | `recovery/partition/WO-Recovery.ps1` | WinPE |
| Install the recovery boot, capture request, copy off | `Engine/WO-Actions.ps1` | the show machine (wizard) |
| Checks `recovery-partition`, `recovery-boot`, `factory-image` | `Engine/WO-Checks.ps1` (reads the partition through `\\?\Volume{...}\`, no letter) | the show machine (wizard) |
| Recovery USB stick (FAT32 WinPE + NTFS images) | `tools/recovery/New-RecoveryUsb.ps1` | technician PC |

**On the recovery partition:** `WO_RECOVERY.tag`, `WO-Recovery.ps1`,
`WORecovery\boot.wim` + `boot.sdi`, `target.json` (GPT partition GUIDs of C:
and D:, labels, D: cluster size, WATCHOUT folder, working directory, boot
entry GUIDs, recovery key), `pending.json` (a capture requested by the
wizard), `Images\factory_C.wim` + `factory_D.wim` + `factory.json` (and
`factory_prev_*`, the fallback), `Logs\<stamp>_<action>.log`,
`Logs\last-result.json`, DISM logs.

**Boot:** a RAM-disk WinPE `osloader` entry on its own ramdisk device object
(not `{ramdiskoptions}`), not in the boot menu. Ways in (decision 29a):
desktop file `Factory recovery.cmd` (`bcdedit /bootsequence`), a key at
power-on (`{bootmgr} customactions` + `custom:54000001`), automatic after
failed starts (`{default} recoverysequence`), and the USB stick. The key and
the failover are **[Uncertain]**: the key format comes from Microsoft's old
"hardware recovery button" page and community reports.

**Capture:** the wizard checks BitLocker, the content of D: (WATCHOUT folder
and an empty working directory only) and the room, writes `pending.json`,
sets the next start to the recovery and restarts. WinPE removes the request
first (no capture loop after a crash), counts down 15 s (any key: menu),
captures C: then D: to `new_*` with `/Compress:max /CheckIntegrity /Verify`,
and only then rotates `new` -> `factory` -> `factory_prev` (decision 29b: one
file per image). Room: estimate = previous image + 15 % or 60 % of the used
space **[Uncertain ratio]**; when short, the older fallback is deleted first;
when still short, the capture refuses.

**Restore:** C: and D: are found by partition GUID (by hand, with sizes and
labels shown, if a disk was replaced), quick-formatted with their labels
and cluster sizes (the partition GUID stays, so the boot entry stays valid),
both images applied with `/CheckIntegrity /Verify`, the D: root
"not content indexed" attribute set again, `C:\Windows` checked.

**Not verified anywhere yet:** every DISM, format, partition and BCD step;
WinPE with Secure Boot after the PCA 2011 expiry; the key and the failover;
whether WATCHOUT 7 runs from a restored C: + D: pair (MILESTONES "R").

