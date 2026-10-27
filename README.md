# WATCHOUT Server Setup Wizard

GUI wizard (one portable Windows .exe) that guides and automates the
preparation of Dataton WATCHOUT 6 / WATCHOUT 7 display servers and production
PCs on Windows 11 Pro 64-bit 25H2, following the build checklists step by step.

Status: **version 0.2 – "check and do" redesign, not yet tested on Windows.**

## Using it

1. Copy `WOSetupWizard.exe` to the USB stick (put `LGPO.exe` next to it if
   this build does not bundle it, see below).
2. On a machine where Windows 11 is installed and you are signed in with the
   show account, start the exe. It asks for administrator rights.
3. Choose the profile (WATCHOUT 7 / WATCHOUT 6; the wizard suggests one if it
   finds WATCHOUT installed) and the role (Display / Production).
   - **Start and check this machine**: for a machine prepared earlier (also
     by hand). Every read-only check runs, steps found done are marked done,
     and the wizard jumps to what is missing.
   - **Start**: for a fresh machine; you can run **Check this machine** at
     any time later.
4. **Fix what's missing** walks every open step in checklist order:
   - automatic steps (PreUpdate, PostInstall, BitLocker off, media drive,
     indexing off, static IPs, Wake on Magic Packet): the wizard shows what
     will change, asks for confirmation (a typed word where it reduces
     security or writes to a disk) and does it, then checks the result;
   - manual steps (Windows Update, drivers, WinUtil, NVIDIA Control Panel,
     WATCHOUT install, Tamper Protection…): you do it, press **Done – check
     it**, and the wizard runs the step's check where one exists;
   - restarts: **Restart now**, then start the exe again from the stick.
   Each step can also be handled on its own from the left rail
   (**Do it**, **Check now**, **Mark done**, **Skip…**, **Not applicable…**).
5. **Manual steps done…** ticks, in one list, the steps that cannot be
   checked from Windows but were done earlier.

State and logs are kept on the machine in `%ProgramData%\WOSetupWizard`
(`state.json`, `logs\<computer>\wizard.log`, one folder per script, check or
action run with its output, result file and backups). **Support bundle** zips
them. A `state.json` from version 0.1 is not continued (different step list):
the wizard offers to start a new build and keeps the old file.

### What this version does

| Works | Not yet |
| --- | --- |
| Both checklists from "First boot" on, in order, with status, notes and reasons | Restore buttons for the backups |
| A check for every step Windows can tell (WO-Checks.ps1, the scripts' `-Audit`, display scale, LGPO) | Build report (HTML) |
| Check this machine / Fix what's missing / bulk-confirm manual steps | Options profiles for twin servers |
| PreUpdate and PostInstall runs with live output, warnings and backups | WinUtil tweaks built in (WinUtil stays manual) |
| BitLocker off, media drive GPT/NTFS, indexing off, static IPs, Wake on Magic Packet | |
| Plain-language confirmation before every change; typed word for risky ones | |
| Options page for every script parameter, with the exact command line | |
| Restart steps confirmed by Windows' start time; support bundle; Start over | |

## Building

Requires the .NET 10 SDK (Windows, Linux or macOS; the exe runs on Windows only).

```bash
dotnet test tests/WOSetup.Core.Tests                         # unit tests
dotnet publish src/WOSetup.App -p:PublishProfile=win-x64       # -> publish/WOSetupWizard.exe
```

- **First build needs internet:** `dotnet` downloads the packages (xUnit,
  CommunityToolkit.Mvvm) from nuget.org; `nuget.config` in the repo root names
  that source. `NU1100 Unable to resolve ...` means nuget.org could not be
  reached: check the connection or proxy, then run `dotnet nuget locals all --clear`
  and build again.
- **LGPO.exe:** put Microsoft's `LGPO.exe` in `third_party/LGPO/` before
  publishing to bundle it (it is never committed; see that folder's README).
- **Step lists:** defined in `tools/flowgen/generate_flows.py`. After editing
  it, run `python3 tools/flowgen/generate_flows.py` and commit the JSON files
  and `docs/WIZARD_FLOW.md` it writes.
- **CI** (`.github/workflows/ci.yml`, Windows runner): unit tests, PowerShell
  parse-check and Pester under Windows PowerShell 5.1, and the published exe as
  a build artifact.

## Repository

| Path | What |
| --- | --- |
| `docs/checklists/` | Field-tested build checklists (WO6, WO7): the order of the wizard |
| `scripts/` | `WO6-Setup.ps1`, `WO7-Setup.ps1`: what the automation does (embedded in the exe) |
| `src/WOSetup.Core/` | Step model, state file, options, confirmation text, result parsing (unit-tested) |
| `src/WOSetup.App/` | The WPF wizard; `Engine/Invoke-WOEngine.ps1` runs the scripts, `Engine/WO-Checks.ps1` holds the read-only checks, `Engine/WO-Actions.ps1` the wizard's own actions |
| `tests/` | xUnit tests for the core, Pester tests for the scripts |
| `tools/flowgen/` | Source of the step lists; writes the flow JSON and `docs/WIZARD_FLOW.md` |
| `docs/` | `PROJECT_CONTEXT.md` (why), `ARCHITECTURE.md`, `WIZARD_FLOW.md`, `MILESTONES.md`, `OPEN_QUESTIONS.md` |
| `AGENTS.md` | Instructions for coding agents |
