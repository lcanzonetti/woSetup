# Milestones

Status: **proposal for owner review** (Oct 2026).
Each milestone ends with a build the owner can run on a Windows 11 Pro 25H2
test VM. "Verified" means verified on that VM (or on real hardware where
stated), not inferred from code. Untested items are listed in each PR.

Cross-references: `docs/ARCHITECTURE.md` (A §n), `docs/WIZARD_FLOW.md` (step
ids), `docs/OPEN_QUESTIONS.md` (OQ n).

## Test environments

| Name | What | Used for |
| --- | --- | --- |
| **CI** | GitHub Actions `windows-latest` (Windows PowerShell 5.1 available) | Build, unit tests, script parse-check, Pester, wrapper tests |
| **VM-EN** | Windows 11 Pro 25H2 (MicroWin build, English), Hyper-V, checkpoint after Setup and after PreUpdate | Every milestone's acceptance |
| **VM-IT** | Same, Italian display language | Check language independence (M3) |
| **HW-WO7** | ThinkStation P8, AMD RAIDXpert2 NVMe RAID, NVIDIA | M5 end-to-end |
| **HW-WO6** | WO6 machine (MegaRAID or plain NVMe), Quadro Sync II if available | M5 end-to-end |

A VM cannot verify GPU, RAID, Quadro Sync, NIC EEE or Wake-on-LAN behaviour;
those stay "not verified" until HW runs.

---

## M1 — Skeleton, state, resume

**Goal:** a wizard that shows both flows, remembers where it is and comes back
by itself after a reboot. No engine runs yet.

Decided: .NET 10 LTS (OQ 1), single exe with profile choice (OQ 6). Blocked by: **OQ 23** (portable vs local copy for resume).

Scope:
- Solution layout (A §3); `app.manifest` (A §9); single-file publish profile.
- `FlowLoader` + `FlowValidator`; `wo7.flow.json` and `wo6.flow.json` with
  **every** step from WIZARD_FLOW (manual-only behaviour for now: automated and
  check steps show their command and are "not available in this build").
- Shell UI: left rail by checklist section, right pane per step kind,
  status icons, profile + role selection (W-00.1).
- `WizardState` + `JsonStateStore` with atomic write and `.bak` fallback (A §5).
- `SelfInstaller` (copy to `%ProgramData%\WOSetupWizard\bin`, folder ACL),
  `ResumeTaskManager` (`\WOSetupWizard\Resume`), single-instance mutex (A §7).
- `RebootManager`: pending reboot record, "Reboot now", confirmation via
  `LastBootUpTime` (A §7.3).
- `wizard.log` (A §8). Finish removes the resume task.
- CI: build, xUnit, parse-check of `scripts/*.ps1` with
  `[System.Management.Automation.Language.Parser]::ParseFile` under `powershell.exe`.

Acceptance (VM-EN):
1. Started from a USB stick (FAT32 or NTFS), elevated prompt once, wizard
   installs itself and shows WO7 or WO6 flow.
2. Mark several manual steps done, reboot from the wizard → after logon the
   wizard reopens **without a UAC prompt** at the same step, reboot confirmed.
3. "Reboot later" + manual restart → also confirmed. No restart → step stays
   "Awaiting reboot".
4. Kill power (VM hard reset) during a state write loop → state loads (or
   falls back to `.bak` with a warning).
5. Standard user cannot write into `%ProgramData%\WOSetupWizard\bin`.
6. Finish → task gone (`Get-ScheduledTask -TaskPath '\WOSetupWizard\'` empty).

Tests: state round-trip and migration; atomic write; navigator gating;
flow validator (ids unique, section order equals checklist, every check id
known); task XML generation (Windows test).

---

## M2 — PreUpdate / PostInstall runners with live log

**Goal:** the two engine phases run from the wizard, with live output, parsed
warnings, run folders and backups recorded.

Decided: scripts as-is + result file S2 (OQ 2), LGPO.exe bundled (OQ 3). Needs **S2** merged first (or the text parser alone until then).

Scope:
- Embedded scripts (linked from `scripts/`, SHA-256 at build) + `Invoke-WOEngine.ps1` wrapper (A §6.3).
- `EngineWorkspace` (run folder, script + LGPO.exe copies, `params.json`),
  `PowerShellRunner` (async streams, UTF-8, cancel → kill tree with confirmation).
- `EngineOutputParser` + warnings panel + `result.json`; summary/count
  mismatch → "could not be fully interpreted" (A §6.4).
- `BackupCatalog`: LGPO backup folders, services CSVs, restore hints,
  **baseline** flag; restore always uses the baseline (decided, OQ 15).
- Bundled LGPO.exe: build-time check (git-ignored `third_party/LGPO/`, CI download with pinned SHA-256), runtime extraction + signature check (A §6.5).
- Audit runs (`-Audit`, S4) before each engine run and after the PostInstall reboot; Set / Not Set list in the UI (A §6.4a).
- Pre-flight checks (A §10) as pre-checks of WO7-03.2 / WO7-09.3 / WO6-03.2 / WO6-08.4.
- PostInstall confirmation summary from **default** options
  (`ConfirmationSummaryBuilder`; options UI comes in M4).

Acceptance (VM-EN, both profiles, from checkpoints):
1. PreUpdate: wizard output equals the transcript of the same script run by
   hand; read-back values present; no unexpected warnings.
2. PostInstall with defaults: same equivalence; warnings in the panel match
   the script's "Completed with N warning(s)" list.
3. Tamper Protection left **on** → the script's warning appears as a warning,
   the step is `DoneWithWarnings`, never `Done`.
4. Run without LGPO.exe (explicit confirmation) → fallback warning shown.
5. Re-run PostInstall with the same options → succeeds; a second set of
   backups is recorded, the first stays marked baseline.
6. Wrapper: `-KeepService TermService,SessionEnv,UmRdpService` reaches the
   WO6 script as three names (services kept); path with spaces
   (`C:\WATCHOUT 6`) binds correctly; `Write-Host` output and accented text
   arrive in the live log; a forced throw gives exit 2 and a `[FATAL]` line.
7. Cancel during PostInstall → `Interrupted`, re-run works.

Tests: parser against captured transcripts of real runs (fixtures checked in,
machine names scrubbed); argument builder; wrapper tests on CI with a dummy
script (arrays, switches, spaces, UTF-8, exit codes); Pester tests for
`Get-WatchoutInstallPath` (both scripts) and `Add-Policy` de-duplication,
loading functions from the AST (A §12).

---

## M3 — Manual and check steps

**Goal:** every manual step has its instructions and Open buttons; every check
in WIZARD_FLOW works and stores evidence.

Decided: all † checks approved (OQ 16); WO7 registry checks moved to §10
(OQ 13, checklist updated). Also decided: WO7 §8 settings automated via script change S1
(OQ 14); WinUtil online or offline copy (OQ 4, OQ 20). The WO7 §8 checks are
written against S1's values, so S1 should land before M3 ends.

Scope:
- `CheckRegistry` with all checklist checks and the approved † checks;
  evidence files (`checks\<StepId>_<stamp>.json`) with command shown, raw
  output, evaluation.
- Checklist commands as automated steps: `pnputil /add-driver …` (folder
  picker, exit 3010 → reboot offer), `manage-bde -off C:` (🔒, progress polling).
- Open buttons (`ms-settings:` URIs, `.cpl`, `netplwiz`, `diskmgmt.msc`, …).
- Windows Update loop and driver steps with pending-reboot probe.
- WinUtil step: online launch button and offline-copy picker (SHA-256 recorded).
- Hardware applicability: AMD RAID / MegaRAID detection → `NotApplicable`
  with operator confirmation (never silently skipped).
- Accept-with-reason for failed checks; reasons go into state.
- Display-scale check (PerMonitorV2 + `GetDpiForMonitor`).

Acceptance:
1. VM-EN: every check run once in a passing and once in a failing state
   (e.g. BitLocker on/off, power plan before/after PostInstall, Tamper on/off).
2. VM-IT: BitLocker, power plan, pnputil and Defender checks give the same
   result as on VM-EN.
3. `manage-bde -off C:` only runs after typed confirmation; progress shown
   to 100 %.
4. No check writes anything (reviewed: every check implementation is a read).

Tests: check evaluation logic with recorded outputs (EN and IT samples);
applicability rules.

---

## M4 — Options UI mapped to script parameters

**Goal:** all script parameters editable, validated, previewed, saved per
machine and reusable on twin servers; restore actions available.

Blocked by: **OQ 7** (options profiles). Decided: restore always from baseline (OQ 15).

Scope:
- `Wo7Options` / `Wo6Options`, 1:1 with the scripts:

  | Parameter | WO7 | WO6 | UI | Validation |
  | --- | --- | --- | --- | --- |
  | `-Role` | ✓ | ✓ | Display / Production | — |
  | `-DefenderMode` | ✓ | ✓ | Off / Exclusions / Skip | Off → Tamper pre-check |
  | `-KeepFirewall` | ✓ | ✓ | switch | — |
  | `-PinVersion` | ✓ | ✓ | text, default = installed `DisplayVersion` shown | pattern like `25H2` |
  | `-KeepUpdateService` | ✓ | ✓ | switch | — |
  | `-WatchoutPath` | ✓ | ✓ | folder, pre-filled from detection | WO6: contains `WATCHPOINT.exe` or `WATCHMAKER.exe` |
  | `-WorkingDirectory` | ✓ | | folder (captured in WO7-07.2) | warn if missing (script: exclusion added anyway) |
  | `-ShowsPath` | | ✓ | folder | warn if missing **[Uncertain how WATCHPOINT handles a missing folder]** |
  | `-StartDelay` | | ✓ | number, default 8 | 0–600 (script `ValidateRange`) |
  | `-KeepServices` | | ✓ | switch | disables the list below |
  | `-KeepService` | | ✓ | checklist of the script's chapter-11 services + preset "Keep Remote Desktop" (`TermService, SessionEnv, UmRdpService`, as in the checklist) | names must be on the script's list or exist on the machine |
  | `-KeepAdapterBindings` | | ✓ | switch | — |
  | `-ForcePcieLinkSpeed` | | ✓ | switch, with the guide's warning (AMD GPU only; boot crashes) | warn if no AMD GPU |

- Help text per option from the scripts' `.PARAMETER` blocks and the
  checklist "Use when" column.
- Live preview of the equivalent command line (as the operator would type it
  in an elevated prompt) and of the confirmation summary.
- Options locked banner after the first PostInstall (A §5.2 note).
- Export/import an options profile (JSON, no machine state, no secrets) for
  twin servers; import warns on paths that do not exist here.
- Backups & tools page: restore Local GPO (`LGPO.exe /g "<backup>\{GUID}"`),
  restore services and update services from CSV (the script's printed
  commands), re-enable bindings (`Enable-NetAdapterBinding -Name <adapter>
  -AllBindings`); each with 🔒 confirmation, always from the baseline
  backup, result logged.

Acceptance (VM-EN):
1. Table-driven test: every option combination produces the expected
   `params.json` and preview line.
2. WO6 with `-Role Production -KeepAdapterBindings -KeepService TermService,SessionEnv,UmRdpService`
   behaves as the same command typed by hand (no WATCHPOINT task, bindings
   untouched, RDP services kept).
3. Each restore action run on a VM checkpoint and its effect read back.

---

## M5 — Report and packaging

**Goal:** a per-machine build report for the client file, a support bundle,
and a releasable exe.

Decided: unsigned, individual (OQ 5); HTML report (OQ 8). No blockers.

Scope:
- `ReportBuilder` → one self-contained HTML file (no external files, no
  scripts), printable to PDF: machine info, profile/role/options, each step
  with status, operator notes and accepted failures, all warnings, all
  `[Uncertain]` items touched, backups with restore commands, script SHA-256s,
  captured versions (WATCHOUT, NVIDIA, WinUtil date, BIOS), timestamps.
- Support bundle (A §8).
- Release build: version stamping, single-file publish (LGPO.exe embedded),
  SHA-256 file next to the exe; **unsigned** (OQ 5).
- Operator README (how to prepare the USB stick, where LGPO.exe comes from,
  what the wizard never does).

Acceptance:
1. End-to-end WO7 build on **HW-WO7** and WO6 build on **HW-WO6** following
   the wizard only (checklist used as a cross-check), including all reboots.
2. Report reviewed by the owner against the paper checklist.
3. Exe starts on a clean VM-EN from a USB stick with Defender on; any
   SmartScreen or Defender prompt recorded in the release notes.

---

## Script work (separate PRs, not wizard code)

| Id | Change | Source of decision | Verification |
| --- | --- | --- | --- |
| **S1** | `WO7-Setup.ps1`: add `Set-WindowsSettings` from `WO6-Setup.ps1` to PostInstall (UAC never notify, Remote Assistance off, visual effects best performance incl. `UserPreferencesMask` **[Uncertain]**, No Sounds, defrag schedule off, USB notifications off **[Uncertain]**, taskbar badges off). Then update the WO7 checklist: §8 items move to the §9 "applied by PostInstall" text. | OQ 14 | Parse-check + Pester; VM-EN run, values read back after reboot; same open items as WO6 (OQ 10) |
| **S2** | Result file: optional `-ResultPath <file>` in both scripts (JSON: phase, options, warnings, backups, restore commands, audit items). `ConvertTo-LgpoText` refactor only if approved (OQ 2). | OQ 2 | Pester; normal-run transcript unchanged |
| **S4** | Audit mode: `-Audit` switch in both scripts, read-only, `[SET]` / `[NOT SET]` (/ `[N/A]`, OQ 24) for every item the phase applies; desired values defined once, shared by apply and audit (A §6.4a). Do after S1 so WO7 includes the new settings. | OQ 10 | Pester for comparisons; VM-EN: audit on a fresh checkpoint = mostly Not Set, after PostInstall + reboot = all Set; end state of a normal run identical before/after S4 |
| S3 | (Later) chosen WinUtil tweaks folded into the scripts; owner provides the list | OQ 4 | VM-EN, per tweak |

## After M5 (not scheduled)

- **M6 Diagnostics** (OQ 9, deferred by the owner): soak-test recorder (nvidia-smi + logman), read-only.
- **M7 Native port**: one script function at a time into C#, each with a
  parity test (same registry/policy/service end state on a VM checkpoint).
  Suggested order: read-only parts first (install-path detection), then
  `Add-Policy` + LGPO text rendering, then power plan; Defender and services last.
- Italian UI.
