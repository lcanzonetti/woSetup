# AGENTS.md — WATCHOUT Server Setup Wizard

Instructions for coding agents (Codex and others) working in this repository.
Read this file first, then `docs/PROJECT_CONTEXT.md` before changing anything.

## What this project is

A standalone Windows **.exe with a GUI wizard** that guides a media-server
operator through preparing a **Dataton WATCHOUT 6 or WATCHOUT 7 display server
(or production PC)** on **Windows 11 Pro 64-bit 25H2**, end to end:
pre-install checks → Windows install hints → driver lockdown → updates and
drivers → debloat → WATCHOUT install → OS hardening → verification → imaging.

The wizard **automates what can be scripted** and **guides, then verifies,
what cannot** (BIOS, RAID arrays, Windows Setup, Tamper Protection, NVIDIA
Control Panel, etc.).

The procedure already exists and is field-tested as:

| Source of truth | Path |
| --- | --- |
| WATCHOUT 7 procedure (checklist) | `docs/checklists/WATCHOUT7-Server-Build-Checklist.md` |
| WATCHOUT 6 procedure (checklist) | `docs/checklists/WATCHOUT6-Server-Build-Checklist.md` |
| WATCHOUT 7 automation | `scripts/WO7-Setup.ps1` (`-Phase PreUpdate` / `-Phase PostInstall`) |
| WATCHOUT 6 automation | `scripts/WO6-Setup.ps1` (`-Phase PreUpdate` / `-Phase PostInstall`) |
| Why things are the way they are | `docs/PROJECT_CONTEXT.md` |

**The checklists define the order of the wizard. The scripts define what the
automation does.** Do not invent new tweaks; if you think one is missing, add
it to `docs/OPEN_QUESTIONS.md` instead of implementing it.

## Target environment (hard constraints)

- Windows 11 Pro 64-bit, 24H2/25H2 (MicroWin builds made with Chris Titus WinUtil).
- Runs **elevated** (requireAdministrator manifest).
- **Windows PowerShell 5.1** is what exists on the target. Any PowerShell the
  app runs must be 5.1-compatible (no `??`, no ternary, no `ForEach-Object -Parallel`,
  no PS7-only cmdlets). The existing scripts are written for 5.1.
- Machines are often **offline**. No feature may require internet except
  explicitly optional ones (e.g. downloading a tool), and the app must say so.
- Machines go through **several reboots** during the procedure. The wizard
  must **persist its state** and reopen on the right step when the operator
  starts it again from the USB stick (no auto-start; decided Oct 2026).
- Hardware seen so far: AMD RAIDXpert2 NVMe RAID (Lenovo ThinkStation P8),
  Broadcom MegaRAID, NVIDIA RTX/Quadro GPUs with Quadro Sync II, Pixelhue P20
  switcher downstream. Do not assume any of it is present; detect.

## Architecture (proposed — confirm with the owner before locking in)

- **C# / .NET 10 (LTS), WPF, single-file self-contained** `win-x64` exe
  (decided Oct 2026: .NET 8 ends support on 10 Nov 2026). Preferred over
  PowerShell-compiled-to-exe (PS2EXE), which antivirus engines often flag.
- **Wizard UI**: left rail = steps from the checklist; right pane = what to do,
  "Run" for automated steps, "Verify" for checks, "Mark done" for manual steps.
- **Automation**: keep `WO6-Setup.ps1` / `WO7-Setup.ps1` as the engine at
  first (embedded resources, written to a working folder, run with
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...`), streaming
  stdout/stderr into the UI and the log. Port to native C# later, one function
  at a time, with behaviour parity.
- **State**: JSON in `%ProgramData%\WOSetupWizard\state.json` (profile WO6/WO7,
  role, options, completed steps, timestamps, backups produced).
- **Resume after reboot**: portable, nothing installed. The exe runs from the
  USB stick; after each reboot the operator starts it again and it reopens on
  the current step from `state.json`. No scheduled task, no local copy of the
  exe (decided Oct 2026, OPEN_QUESTIONS 23).
- **Logs**: one folder per machine under `%ProgramData%\WOSetupWizard\logs\`,
  including each script transcript, plus an "export support bundle" button.
- **Options** map 1:1 to script parameters (`-Role`, `-DefenderMode`,
  `-KeepFirewall`, `-KeepUpdateService`, `-PinVersion`, WO7 `-WorkingDirectory`,
  WO6 `-ShowsPath`, `-StartDelay`, `-KeepServices`, `-KeepService`,
  `-KeepAdapterBindings`, `-ForcePcieLinkSpeed`, `-WatchoutPath`).

## Non-negotiable behaviour

1. **Order matters.** Respect the checklist order. In particular:
   PreUpdate runs **offline, before** the network cable is plugged in and
   before any driver; PostInstall runs **after** all updates, drivers,
   WinUtil debloat and the WATCHOUT install.
2. **Never pretend.** If something did not apply (Tamper Protection still on,
   service protected, value rejected), show it as a warning. Read back and
   verify instead of assuming success. Same philosophy as the scripts.
3. **Show before changing.** Before any destructive or security-reducing step
   (firewall off, Defender off, Windows Update fully disabled, services
   disabled, bindings removed) show a plain-language summary and require an
   explicit confirmation.
4. **Backups and rollback.** Keep the LGPO backup, service CSV backups and
   update-service CSV backup produced by the scripts; expose "restore" actions
   where the scripts print restore commands.
5. **No silent network access.** No telemetry, no auto-update of the app.
6. **Idempotent.** Every automated step must be safe to run again with the
   same options. Switching an option later does not undo earlier changes;
   the UI must say so (see PROJECT_CONTEXT "Re-running").
7. **Do not touch** WATCHOUT/Dataton services, the CodeMeter licence runtime,
   or RAID drivers. Never run `diskpart clean` or anything that writes to disks
   without the owner typing an explicit confirmation.

## Things the app must guide but cannot automate

BIOS settings and RAID array creation (system volume FIRST), Windows Setup
(RAID drivers loaded before touching disks; AMD order rcbottom → rcraid →
rccfg), Tamper Protection OFF (Microsoft blocks scripting), WinUtil run
(tweak list in the checklists), NVIDIA Control Panel, `netplwiz` auto-logon,
display scale per output, Wake-on-LAN in BIOS, soak test, disk imaging.
For each: show instructions, then run an automated **check** where one exists
(e.g. `manage-bde -status C:`, `Get-MpComputerStatus`, `powercfg /getactivescheme`,
`pnputil /enum-drivers`, `Get-ScheduledTask -TaskPath '\WATCHOUT\'`).

## Code conventions

- C#: nullable enabled, async for long operations, MVVM, no business logic in
  code-behind. One class per step type (Automated / Manual / Check).
- PowerShell: 5.1-compatible, `Set-StrictMode -Version Latest`,
  `$ErrorActionPreference = 'Stop'`, comments explaining **why** for every
  tweak (guide section number when it comes from the Dataton guide).
- Keep `[Uncertain]` markers from the scripts/docs when porting: they flag
  behaviour not confirmed on real hardware.
- Every user-visible string in English (UI may be localised to Italian later).

## Testing

- Unit-test the C# step engine and state persistence.
- PowerShell: at minimum parse-check all scripts
  (`[System.Management.Automation.Language.Parser]::ParseFile`) in CI;
  Pester tests for pure functions (e.g. install-path detection, policy queue
  de-duplication, LGPO text rendering).
- Real changes can only be verified on a Windows 11 test machine or VM;
  never claim a tweak works without that. Note untested items in the PR.

## When unsure

Ask the owner (freelance media-server operator, WATCHOUT 6/7 specialist)
rather than guessing. Put open items in `docs/OPEN_QUESTIONS.md`.
