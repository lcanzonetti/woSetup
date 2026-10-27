# WATCHOUT Server Setup Wizard

GUI wizard (one portable Windows .exe) that guides and automates the
preparation of Dataton WATCHOUT 6 / WATCHOUT 7 display servers and production
PCs on Windows 11 Pro 64-bit 25H2, following the build checklists step by step.

Status: **version 0.1 – first working skeleton, not yet tested on Windows.**

## Using it

1. Copy `WOSetupWizard.exe` to the USB stick (put `LGPO.exe` next to it if
   this build does not bundle it, see below).
2. On the machine, start the exe. It asks for administrator rights.
3. Choose the profile (WATCHOUT 7 / WATCHOUT 6) and the role (Display /
   Production). The left rail shows every checklist step in order.
4. Work down the steps: **Mark done** for manual steps, **Run** for the
   setup scripts, **Run audit** / **Audit first** for the read-only check.
5. After every restart, start the exe again from the stick: it opens on the
   step where you left off. Nothing is installed and nothing starts by itself.

State and logs are kept on the machine in `%ProgramData%\WOSetupWizard`
(`state.json`, `logs\<computer>\wizard.log`, one folder per script run with the
script's transcript, result file and backups). **Support bundle** zips them.

### What this version does

| Works | Not yet (shows the command to run by hand) |
| --- | --- |
| Every step of both checklists, in order, with status, notes and reasons | Automatic checks (BitLocker, Defender, pnputil, …) |
| PreUpdate and PostInstall runs with live output, warnings and backups | `pnputil` NIC driver install, `manage-bde -off` |
| Audit mode (Set / Not set / N/A list), before and after PostInstall | Restore buttons for the backups |
| Plain-language confirmation before running; typed `APPLY` for PostInstall | Build report (HTML) |
| Options page for every script parameter, with the exact command line | Options profiles for twin servers |
| Restart steps confirmed by Windows' start time | WinUtil launch button |
| Support bundle, logs folder, Start over | Pre-flight checks (show account, execution policy) |

## Building

Requires the .NET 10 SDK (Windows, Linux or macOS; the exe runs on Windows only).

```bash
dotnet test tests/WOSetup.Core.Tests                         # unit tests
dotnet publish src/WOSetup.App -p:PublishProfile=win-x64       # -> publish/WOSetupWizard.exe
```

- **LGPO.exe:** put Microsoft's `LGPO.exe` in `third_party/LGPO/` before
  publishing to bundle it (it is never committed; see that folder's README).
- **Step lists:** generated from `docs/WIZARD_FLOW.md`. After editing it, run
  `python3 tools/flowgen/generate_flows.py` and commit the JSON it writes.
- **CI** (`.github/workflows/ci.yml`, Windows runner): unit tests, PowerShell
  parse-check and Pester under Windows PowerShell 5.1, and the published exe as
  a build artifact.

## Repository

| Path | What |
| --- | --- |
| `docs/checklists/` | Field-tested build checklists (WO6, WO7): the order of the wizard |
| `scripts/` | `WO6-Setup.ps1`, `WO7-Setup.ps1`: what the automation does (embedded in the exe) |
| `src/WOSetup.Core/` | Step model, state file, options, confirmation text, result parsing (unit-tested) |
| `src/WOSetup.App/` | The WPF wizard; `Engine/Invoke-WOEngine.ps1` runs the scripts |
| `tests/` | xUnit tests for the core, Pester tests for the scripts |
| `tools/flowgen/` | Generates the step lists from `docs/WIZARD_FLOW.md` |
| `docs/` | `PROJECT_CONTEXT.md` (why), `ARCHITECTURE.md`, `WIZARD_FLOW.md`, `MILESTONES.md`, `OPEN_QUESTIONS.md` |
| `AGENTS.md` | Instructions for coding agents |
