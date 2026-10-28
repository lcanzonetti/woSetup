# Open questions

Decide these with the owner before or during the first milestones.

Each item keeps the original question, then a **Recommendation** (Oct 2026)
and an **Owner decision** line to fill in. Items 11–22 are new: they came up
while reading the scripts and checklists for `docs/ARCHITECTURE.md` and
`docs/WIZARD_FLOW.md`. None of the recommendations is implemented; anything
that deviates from the checklists or adds behaviour waits for the owner.

| # | Topic | Blocks | Status |
| --- | --- | --- | --- |
| 1 | Tech stack / .NET version | M1 | Decided |
| 2 | Engine: scripts as-is, result file | M2 | Decided |
| 3 | LGPO.exe | M2 | Decided |
| 4 | WinUtil step | M3 | Decided (tweak list for S3 pending) |
| 5 | Code signing | M5 | Decided |
| 6 | Single exe | M1 | Decided |
| 7 | Machine profiles | M4 | Decided |
| 8 | Report | M5 | Decided |
| 9 | Diagnostics page | after M5 | Deferred |
| 10 | Untested behaviour | M2–M5 (verification plan) | Decided (audit mode implemented) |
| 11 | `-KeepService` array via `-File` | M2 | Decided |
| 12 | Reboot after PreUpdate? | M2 | Decided |
| 13 | WO7 §8 registry checks after the reboot | M3 | Decided |
| 14 | WO7 §8 settings: manual or reuse WO6 automation | M3 | Decided |
| 15 | Backups on re-run: restore from the first one | M2/M4 | Decided |
| 16 | Proposed read-only checks (†) | M3 | Decided |
| 17 | Wizard vs WATCHPOINT full screen after reboot (WO6) | M1/M3 | Superseded by 23 |
| 18 | Show account must be a local administrator | M2 | Decided |
| 19 | WO7 install-path detection takes the first "WATCHOUT" entry | M2 | Closed (not needed) |
| 20 | WO6: cable unplugged before WinUtil, which needs internet | M3 | Decided |
| 21 | Smart App Control | M5 | Closed (not now) |
| 22 | Finish before or after imaging | M5 | Closed (not now) |
| 23 | Portable exe vs resume after reboot | M1 | Decided |
| 24 | Audit labels (Set / Not Set / N/A) | S4 | Decided |

---

## 1. Tech stack

> C# .NET 8 WPF single-file exe (proposed) vs PowerShell WPF + PS2EXE.

**Recommendation:** C# WPF single-file self-contained `win-x64`, as proposed,
**but on .NET 10 (LTS) instead of .NET 8.**

- .NET 8 (LTS) and .NET 9 reach end of support on **10 Nov 2026**, two weeks
  from now; .NET 10 is LTS, supported until Nov 2028
  ([Microsoft .NET blog, 29 Jun 2026](https://devblogs.microsoft.com/dotnet/dotnet-8-9-end-of-support/);
  [InfoWorld](https://www.infoworld.com/article/4191704/end-of-support-looms-for-net-8-and-net-9.html)).
  A self-contained .NET 8 exe would still run, but its bundled runtime would
  never get another security fix. The exact .NET 10 end date is given as
  Nov 2028 by Microsoft and as 14 Nov 2028 by a third party
  **[Conflicting sources on the exact day]** — check the Microsoft lifecycle
  page; it does not change the decision.
- PS2EXE: keep rejected. It wraps a script in a small host exe, which AV
  engines often flag (AGENTS.md), and it would not remove the PowerShell 5.1
  limits for the UI.
- WPF does not support trimming, so the exe will be large (tens of MB)
  **[Uncertain exact size until the first build]**. Not an issue on a USB stick.

**Owner decision (Oct 2026):** **.NET 10 LTS.** AGENTS.md updated.

## 2. Engine

> Keep running the two .ps1 scripts (embedded) first, port to C# later? (proposed: yes)

**Recommendation:** yes. Run the scripts **unchanged** through a small
wrapper (`Invoke-WOEngine.ps1`, ARCHITECTURE §6.3) that only handles
argument binding, UTF-8 output and exit codes. Port to C# after M5, one
function at a time, with parity tests on a VM (MILESTONES "M7").

Two optional, behaviour-neutral script changes would make the wizard more
robust. Neither is a tweak; both need your OK because they touch the scripts:

1. **Result file:** an optional `-ResultPath <file>` parameter; at the end
   the script writes `{ phase, warnings[], backups[], restoreCommands[] }` as
   JSON. Without it, the wizard parses the `[OK]`/`[WARN]` text (works, but
   any wording change in a script can break parsing).
2. **Testability:** move the LGPO text rendering out of `Invoke-PolicyApply`
   into its own function (e.g. `ConvertTo-LgpoText`), so Pester can test it
   without calling LGPO.exe. AGENTS.md asks for that test; today it can only
   be done by running the whole function.

**Owner decision (Oct 2026):** **Scripts as-is; result file yes** (MILESTONES S2). **Testability refactor: yes** (LGPO text rendering moved into its own function, no behaviour change; MILESTONES S2).

*What "testability" means:* AGENTS.md asks for automated (Pester) tests of the LGPO text rendering, i.e. that the queued policies turn into exactly the right `Computer / Key / Name / DWORD:n` lines. Today that code sits inside `Invoke-PolicyApply`, which in the same breath backs up the Local GPO, calls `LGPO.exe` and runs `gpupdate /force`, so it can only be tested by changing a real machine. Moving the dozen rendering lines into their own function (e.g. `ConvertTo-LgpoText`, called from the same place) changes no behaviour and lets CI check the text file on every commit, on any machine. Without it, that test is dropped and rendering is only checked on the VM.

## 3. LGPO.exe

> Bundle (check Microsoft licence terms), ask the user for its path, or write Registry.pol natively?

**Recommendation:** **do not bundle; ask for it and verify it.** Native
Registry.pol later, if at all.

- The licence is in "Microsoft Security Compliance Toolkit – Standalone Use
  Terms.pdf" inside the LGPO download (per a Microsoft answer on
  [Microsoft Tech Community](https://techcommunity.microsoft.com/discussions/security-baselines/welcome/690634)).
  I have **not** read that PDF, so redistribution rights are
  **[Uncertain]**. A Microsoft engineer said of a related tool
  (Apply_LGPO_Delta) that it should not be redistributed outside your
  organisation ([Microsoft archived blog](https://learn.microsoft.com/en-us/archive/blogs/fdcc/sample-files-for-apply_lgpo_delta)) —
  that comment is about a different tool and predates LGPO.exe, so it only
  suggests the direction. To resolve: read the PDF in your copy of LGPO.zip.
- Wizard behaviour (ARCHITECTURE §6.5): look for `LGPO.exe` next to the
  wizard and on removable drives, or browse; check the Microsoft Authenticode
  signature; copy into `%ProgramData%\WOSetupWizard\tools`. Continuing without
  it needs explicit confirmation, with the script's fallback limits spelled out.
- Native Registry.pol: the PReg file format is documented, but LGPO also
  updates `gpt.ini` (version, extension GUIDs) so Windows applies and gpedit
  shows the policies. Re-implementing that correctly is real work and needs
  VM verification; worth it only if the licence rules out asking operators
  to download LGPO themselves.

**Owner decision (Oct 2026):** **Bundle it**: one portable exe run from a USB stick. Licence terms stay **[Uncertain]** (owner's call, own use). Plan: not committed to git, build-time download with pinned SHA-256, runtime signature check (ARCHITECTURE §6.5). "No installation" → item 23.

## 4. WinUtil step

> Launch WinUtil and show the tick list (needs internet: `irm christitus.com/win | iex`), or re-implement the selected tweaks natively?

**Recommendation:** **do not re-implement.** Manual step with the exact tick
list from the checklist, plus an optional **"Launch WinUtil (internet
required)"** button that opens a visible elevated PowerShell window running
the official command, clearly labelled as online.

- Re-implementing would duplicate a third-party tool's tweaks in this
  project (effectively "adding tweaks"), and they would drift as WinUtil
  changes.
- WinUtil can load an exported config: `-Config "<file>.json"` and, per its
  user guide, `-Run` to apply without clicking
  ([WinUtil automation guide](https://winutil.christitus.com/userguide/automation)).
  The two official pages differ on whether `-Run` is required, and the launch
  still downloads the script **[Uncertain: no documented fully offline mode]**.
  Option for later: you export your tick list once from WinUtil, the wizard
  ships that JSON and passes it to the launch command. The config format can
  change between WinUtil versions, so it must be re-checked per WinUtil
  release.
- The wizard records the WinUtil version/date typed by the operator in the report.
- See item 20 for the WO6 offline conflict.

**Owner decision (Oct 2026):** **Manual tick list; WinUtil started either online (cable plugged in briefly) or from a local offline copy of the WinUtil script.** Later, a chosen subset of WinUtil tweaks may be integrated into the scripts — owner to pick the list (MILESTONES S3). Shipping an exported config: not decided.

## 5. Code signing

> Certificate available? Unsigned elevated exes trigger SmartScreen and AV warnings.

**Recommendation:** ship M1–M4 **unsigned for your own use** (with a SHA-256
file per release); decide on a certificate before giving the exe to anyone else.

- SmartScreen checks files that carry the Mark of the Web (downloaded
  files). An exe copied from a FAT32/exFAT USB stick loses that mark, so
  SmartScreen usually does not prompt **[Uncertain: confirm on VM in M5]**.
  Defender AV still scans it (and Defender is turned off only at PostInstall).
  Smart App Control is a separate risk: item 21.
- Options, if you need one:
  - **Azure Artifact Signing** (formerly Trusted Signing): about US$9.99/month
    (Basic). Open to **individuals only in the USA and Canada**; to
    organisations also in the EU and UK
    ([Microsoft Learn – code signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options);
    [Azure pricing](https://azure.microsoft.com/en-us/products/artifact-signing)).
    Whether a sole trader (e.g. Italian *ditta individuale*) qualifies as an
    organisation is **[Uncertain]**; check the eligibility FAQ.
  - **OV certificate** from a public CA, on a hardware token or cloud HSM.
  - **EV** no longer gives instant SmartScreen reputation; EV and OV now
    build reputation the same way
    ([ToDesktop, PSA on EV certs](https://www.todesktop.com/blog/posts/windows-apps-psa-ev-certs-do-not-grant-immediate-reputation-anymore)).
    The effective date is reported as March 2024 by SSL.com and August 2024
    elsewhere **[Conflicting sources]**; it does not change the advice: EV is
    not worth the premium for this.

**Owner decision (Oct 2026):** **Individual, unsigned**; mostly run from a USB stick. Releases ship with a SHA-256 file.

## 6. Single exe

> Single exe for WO6 and WO7 with a profile choice at start (proposed), or two builds?

**Recommendation:** **single exe**, profile chosen at start (W-00.1) and
**locked after the first automated step** (PreUpdate). Both flows share 90 %
of the code; the flow files differ. Changing the profile afterwards means
"Start over" (state archived, not deleted).

**Owner decision (Oct 2026):** **Single exe**, profile chosen at start and locked after the first automated step.

## 7. Machine profiles

> Save/load an options profile (role, paths, switches) per show/client to reuse on twin servers?

**Recommendation:** **yes, in M4.** A small JSON with profile, role and
script options only — no machine state, no machine name, no secrets.
Import shows a diff against the current options and warns on paths that do
not exist on this machine (e.g. `E:\Shows`). It never skips steps: a twin
still goes through the whole flow.

**Owner decision (Oct 2026):** **Yes** (M4).

## 8. Report

> Generate a per-machine HTML/PDF build report (what was applied, warnings, versions) for the client file?

**Recommendation:** **yes, HTML in M5**, one self-contained file (no external
files or scripts), printable to PDF from any browser. Content: MILESTONES M5.
A direct PDF export would need either a PDF library or WebView2; not worth it
for v1. Note: "Microsoft Print to PDF" may be missing on a MicroWin build
**[Uncertain]** — print from the workstation that receives the report instead.

**Owner decision (Oct 2026):** **Yes**, self-contained HTML (M5).

## 9. Diagnostics page

> Include the HAP-stutter logging recipe (nvidia-smi + logman) as a "record performance during soak test" tool?

**Recommendation:** **yes, but after M5** (M6). It is a read-only recorder,
not a tweak: start/stop buttons that run the PROJECT_CONTEXT §9 recipe
(`nvidia-smi --query-gpu=... -l 1 -f gpu.csv`, a `logman` counter set),
write into the machine log folder, show free disk space, and never start
during a show unless the operator presses Start. The exact `nvidia-smi`
query fields and `logman` counters need your field list (the context file
abbreviates them). Because the twin-server stutter is unresolved, this is
the most useful post-v1 feature.

**Owner decision (Oct 2026):** **Not for now**; maybe later (M6, unscheduled).

## 10. Untested behaviour

> Verify on hardware: UserPreferencesMask value, NotifyOnUsbErrors, LGPO merge behaviour, WaaSMedic re-enabling wuauserv, DisableAntiSpyware visibility in gpedit on 25H2.

**Recommendation:** verification plan; each item stays **[Uncertain]** in
the UI until done. The wizard's own checks help collect the evidence.

| Item | How to verify (VM-EN unless noted) | Wizard support |
| --- | --- | --- |
| `UserPreferencesMask 90 12 03 80 10 00 00 00` (WO6) | After PostInstall + reboot, open Performance Options: every effect unticked? Compare the binary value with what the dialog writes when you click "Adjust for best performance" by hand on a clean checkpoint. | WO6-09.6 |
| `NotifyOnUsbErrors` (WO6) | After reboot, Settings → Bluetooth & devices → USB: toggle shown Off? Then toggle it by hand on a clean checkpoint and see which value changes (Process Monitor). | WO6-09.7, WO7-08.6 |
| LGPO `/t` merge | On a checkpoint, set an unrelated policy in gpedit, run PostInstall, check it is still set (`LGPO.exe /parse /m C:\Windows\System32\GroupPolicy\Machine\Registry.pol`). | Backup always taken first |
| WaaSMedicSvc re-enabling `wuauserv` | After PostInstall: reboot, wait 24 h idle with network, reboot again; check `Get-Service wuauserv` start type each time. | WO7-10.3a, WO6-10.5a |
| `DisableAntiSpyware` not in gpedit on 25H2 | `LGPO.exe /parse` shows whether the value is in Registry.pol. If it is, the cause is the ADMX (gpedit only shows settings defined in the installed templates) **[Uncertain]**; if not, LGPO rejected or skipped it. | Verify page |

Plus the hardware-only items: AMD `rccfg` carried into the OS (WO7-04.2),
RAIDXpert2 array naming in `Get-Disk`, Broadcom 9361/IT-mode drivers.

**Owner decision (Oct 2026):** **Add an audit mode to the scripts**: every step, setting, registry key, group policy etc. is checked against what the script would apply and flagged **Set** or **Not Set** (MILESTONES S4, ARCHITECTURE §6.4a). The verification plan above stays: an audit shows a value is *set*, not that Windows *honours* it, so the [Uncertain] items still need the hands-on checks. Labels for skipped items → item 24.

---

## 11. `-KeepService` and other options through `powershell.exe -File` (new)

**Finding:** WO6 `-KeepService` is `[string[]]`. Typed in an elevated
prompt (`.\WO6-Setup.ps1 -KeepService TermService,SessionEnv,UmRdpService`),
PowerShell builds an array. Passed via `powershell.exe -File … -KeepService
TermService,SessionEnv,UmRdpService`, it arrives as **one string**, so
`$KeepService -contains 'TermService'` is false and the RDP services would be
disabled. **Not a script bug**: the checklist usage is correct. It matters
only for how the wizard calls the script.

**Recommendation:** the wizard never passes options on the command line; the
wrapper reads JSON and splats (ARCHITECTURE §6.3). Covered by an M2
acceptance test.

**Owner decision (Oct 2026):** **OK with the wrapper.**

## 12. Reboot after PreUpdate? (new)

**Finding:** both scripts end with "Completed with no warnings. **Reboot
now.**" for **both** phases. The checklists put no reboot after PreUpdate
(next item: install the NIC driver). `SearchOrderConfig` and the policies
are applied by `gpupdate /force`, so a reboot does not look necessary.

**Recommendation:** follow the checklist (no reboot), show the script's line
as-is, and add a one-line note in the wizard. Optional script fix: print
"Reboot now" only after PostInstall.

**Owner decision (Oct 2026):** **The scripts are right: reboot after PreUpdate.** Both checklists now have a "Reboot (cable still unplugged)" line after PreUpdate; WIZARD_FLOW has reboot point R0b.

## 13. WO7 §8 registry checks: when to run them (new)

**Finding:** the WO7 checklist lists the `TdrDelay`/`TdrDdiDelay`/
`SystemResponsiveness`/`Win32PrioritySeparation` items in §8 (before
PostInstall in §9) but says they are "applied by PostInstall; listed to check
after a reboot".

**Recommendation:** keep them in §8 in the left rail, but the wizard runs
them only after the PostInstall reboot (they appear as pending checks in §10
until then). No `reg add` is ever run by the wizard. This is a display
choice, not a change of order.

**Owner decision (Oct 2026):** **Move them after PostInstall.** Done: the WO7 checklist now checks them in §10 with `reg query`; WIZARD_FLOW WO7-10.3b–d.

## 14. WO7 §8 settings: manual, or reuse the WO6 automation? (new)

**Finding:** for WO7 the checklist makes UAC never notify, Remote Assistance
off, No Sounds, defrag schedule off, USB notifications off and taskbar
badges off **manual**. `WO6-Setup.ps1` already automates the same items
(`Set-WindowsSettings`).

**Recommendation:** **keep them manual for WO7** (checklist is the source of
truth), with read-only checks (†). If you want them automated for WO7, that
is a change to `WO7-Setup.ps1` and to the WO7 checklist, done first in the
script and verified on a VM, not in the wizard.

**Owner decision (Oct 2026):** **Automate them in WO7-Setup.ps1 like WO6-Setup.ps1** (MILESTONES S1, separate PR). Assumed scope: the whole `Set-WindowsSettings` function, i.e. visual effects too (WO7 checklist 10.3 says "skip if ticked in WinUtil"; applying both is harmless). Indexing (10.15) stays manual for WO7: WO6 covers it by disabling the Windows Search service, which is part of the ch. 11 service list, not of `Set-WindowsSettings`. **Confirm this scope.**

**Final scope (Oct 2026):** everything WO6 automates for these items, except adapter bindings and the chapter 11 services: the whole `Set-WindowsSettings` function (UAC, Remote Assistance, visual effects, No Sounds, defrag schedule, USB notifications, taskbar badges), indexing off via the Windows Search service, and the 96 DPI values. Implemented as S1 (not yet run on Windows).

## 15. Backups when a phase is re-run (new)

**Finding:** every run writes new backups (`LGPO_Backup_<stamp>`,
`Services_Backup_<stamp>.csv`, `UpdateServices_Backup_<stamp>.csv`). On a
**re-run**, the services are already `Disabled`, so the new CSV records
"Disabled"; restoring from it restores nothing. Same for the Local GPO
backup, which then contains the already-applied policies.

**Recommendation:** the wizard marks the **first** backup of each kind as
**baseline**, keeps all of them, and restore actions use the baseline.
Later backups stay in their run folders (and the support bundle) for
reference only; their printed restore lines are not offered as actions.

**Owner decision (Oct 2026):** **Always use the first (baseline) backup.**

## 16. Proposed read-only checks (new)

**Finding:** `docs/WIZARD_FLOW.md` marks with **†** checks that are not
written in the checklists (e.g. "no physical adapter Up before PreUpdate",
`SearchOrderConfig` read-back, NVIDIA version compare, auto-logon registry
values, display DPI = 96, indexing off per volume, CodeMeter service running,
no WATCHPOINT Startup shortcut). All are reads; none changes the machine.

**Recommendation:** approve them as a group, or strike the ones you do not
want. Without approval those steps remain plain manual steps.

**Owner decision (Oct 2026):** **All approved**; the owner may strike individual ones later.

## 17. Wizard vs WATCHPOINT after reboot (WO6) (new)

**Finding:** after WO6 PostInstall, WATCHPOINT starts at logon (8 s delay)
and goes full screen; the wizard's resume task also starts at logon, so one
covers the other. WO6-10.1 needs WATCHPOINT to start *undisturbed*, because
the point is to see that nothing steals focus.

**Recommendation:** after PostInstall (WO6 Display), the resume task starts
the wizard **minimised to the taskbar** with a 60 s delay, and does not take
focus. The operator brings it up with Alt+Tab when ready. The verification
step asks "Did WATCHPOINT start full screen on its own?" and then reads the
task result (WO6-10.2).

**Owner decision (Oct 2026):** **Superseded by item 23 (C):** the wizard never starts by itself, so it cannot cover WATCHPOINT. The operator checks WATCHPOINT first, then starts the wizard.

## 18. Show account must be a local administrator (new)

**Finding:** both checklists say "Elevated, from the show account", and the
scripts write HKCU values and (WO6) register the WATCHPOINT task for
`$env:USERNAME`. If the show account were a standard user and someone
elevated with another admin account, those settings would land in the wrong
profile.

**Recommendation:** the wizard requires the elevated user to be the
interactive (show) user and blocks otherwise (ARCHITECTURE §10). This implies
the show account is a local administrator, which also matches the WO6
"highest privileges" WATCHPOINT task. Confirm this is always the case on your
builds.

**Owner decision (Oct 2026):** **Yes**, always.

## 19. WO7 install-path detection takes the first "WATCHOUT" entry (new)

**Finding:** `WO7-Setup.ps1` `Get-WatchoutInstallPath` returns the first
Uninstall entry whose `DisplayName` matches `WATCHOUT` and has an
`InstallLocation`. On a machine with WATCHOUT 6 leftovers or a companion
product, it could pick the wrong folder for the Defender exclusions. (The WO6
version is stricter: it requires `WATCHPOINT.exe`/`WATCHMAKER.exe` in the
folder.)

**Recommendation:** the wizard shows all matching entries at WO7-07.1 and
passes `-WatchoutPath` explicitly when more than one exists. Optional script
fix later: prefer an entry with "7" in the name or a known WATCHOUT 7
executable — that needs the exact WATCHOUT 7 file names from you.

**Owner decision (Oct 2026):** **Not needed**: firewall and Defender are fully disabled on these builds anyway. No wizard warning, no script change. (The path still matters only if `-DefenderMode Exclusions` is ever used.)

## 20. WO6: cable unplugged before WinUtil (new)

**Finding:** WO6 checklist §4 ends with "Unplug the network cable again if
the machine will stay offline", but §6 WinUtil is launched with
`irm christitus.com/win | iex`, which needs internet.

**Recommendation:** in the wizard, move nothing; at WO6-06.x show "WinUtil
needs internet: plug the cable in for this step, unplug it afterwards" when
the adapter is down. Alternatively, swap the order in the WO6 checklist (unplug
after WinUtil). Either way it is your call, since it changes the checklist
wording or order.

**Owner decision (Oct 2026):** **Re-plug the cable briefly for an online WinUtil launch, or use an offline copy of the WinUtil script** (same as item 4). Checklist order unchanged.

## 21. Smart App Control (new)

**Finding:** on clean Windows 11 installs Smart App Control can start in
evaluation mode and, once on, blocks unsigned apps it does not know
**[Uncertain whether MicroWin builds keep it, and how it treats this exe]**.

**Recommendation:** the pre-flight shows `Get-MpComputerStatus`
`SmartAppControlState` (read-only). Test on VM-EN in M5 with an unsigned
build; if SAC blocks it, that is a strong argument for signing (item 5).

**Owner decision (Oct 2026):** **Not needed for now.**

## 22. Finish before or after imaging (new)

**Finding:** the last checklist step is "Image the system disk". If the
wizard is still installed at that point, the image (and every clone) carries
the resume task and the wizard's state.

**Recommendation:** place **Finish** (remove the resume task and
`bin\WOSetupWizard.exe`, keep logs and report) **just before** the imaging
step, and show the imaging step as the last manual item after Finish. This
moves the wizard's own step, not a checklist item.

**Owner decision (Oct 2026):** **Not needed for now**; Finish stays the last step.

## 23. Portable exe vs resume after reboot (new)

**Finding:** you want one exe that runs from the USB stick with no
installation. AGENTS.md also requires the wizard to reopen by itself at the
next logon after each reboot, which needs a scheduled task pointing at an exe
path. A USB path is fragile: the drive letter can change and the stick may be
unplugged between reboots. State and logs are not the issue: they stay on the
machine in `%ProgramData%\WOSetupWizard` either way.

Options:

- **A — temporary local copy (recommended):** the USB exe copies itself to
  `%ProgramData%\WOSetupWizard\bin` (locked down so standard users cannot
  replace it) and the task starts that copy. No installer, nothing in
  "Apps", no registry entries of its own; **Finish deletes the copy and the
  task**, leaving only logs and the report. Resume always works.
- **B — run only from the stick:** the task points at the exe on the stick
  (identified by the stick's volume serial). If the stick is missing or got
  another letter, nothing opens and you start it by hand; state picks up
  where it was. Nothing is copied.
- **C — no auto-resume:** you always start it from the stick after a reboot;
  the wizard reopens on the right step. Simplest, but deviates from AGENTS.md.

**Owner decision (Oct 2026):** **C — no auto-resume.** The exe runs only from the USB stick; after each reboot the operator starts it again and it reopens on the current step. AGENTS.md updated.

## 24. Audit labels: only Set / Not Set? (new)

**Finding:** some items are deliberately not applied with the chosen
options or hardware (`-KeepFirewall`, `-Role Production`, `-KeepService`,
`-ForcePcieLinkSpeed` off, no AMD GPU), and a few lines are one-off actions,
not settings (clearing `SoftwareDistribution`, `gpupdate`). Reporting those
as "Not Set" would look like a failure.

**Recommendation:** three labels: **Set**, **Not Set**, and **N/A** with the
reason (option, hardware, or "action, not a setting"). The final audit
passes when nothing is "Not Set".

**Owner decision (Oct 2026):** **Set / Not Set / N/A, as recommended.**

## 25. New checks and actions not confirmed on real hardware (new, v0.2)

Written for the "check and do" redesign without a Windows test machine.
Each needs a test on a VM, the **[Uncertain]** ones on real hardware:

- **[Uncertain] Blank-password detection** (`auto-logon` check). With no
  auto-logon in the registry, the check tries a local logon with an empty
  password: success or error 1327 (blank passwords limited to console
  logon) = no password, 1326 = has a password. On an account with a
  password this counts as one failed logon (event 4625, and one step
  towards the lockout threshold, reset after the lockout window).
- **[Uncertain] WATCHOUT 7 programs entry** (`watchout-installed`, start
  screen suggestion): matched as "WATCHOUT" with "7" in the name or a
  version starting with 7. The real installer name/version is unknown.
- **[Uncertain] CodeMeter service name** (`codemeter-running`): any service
  whose name or display name contains "CodeMeter".
- **[Uncertain] AMD RAID detection** (`amd-raid-drivers`): rcbottom, rcraid,
  rccfg `.inf` names in the driver store; "no AMD RAID" when none is found
  and no device name matches "AMD ... RAID".
- **Wake on Magic Packet**: matched by the advanced property's display name
  and an Enabled/On value, like EEE in the scripts. Vendor names may differ;
  "Allow this device to wake the computer" (power management tab) is not
  set by the wizard.
- **Display scale**: per-monitor DPI read by the wizard; 96 DPI = 100 %.
- **Static IP**: replaces the adapter's IPv4 addresses and default route;
  not tested with several addresses per adapter or with teaming.
- **BitLocker off**: `manage-bde -off` then a read-back via
  `Win32_EncryptableVolume`; decryption in progress is reported as "not
  done" with the percentage.
- **Media drive**: only RAW disks are offered; Storage Spaces or a RAID
  volume that Windows shows as offline/read-only is brought online first.
- **WinUtil, NVIDIA Control Panel, startup apps, Windows Update**: no
  reliable check from Windows; the operator confirms (one list for steps
  done earlier).

**Needed from the owner:** test results per item.

**Owner decision (Oct 2026):** the four detections that depended on
unconfirmed names are **not wanted** and were removed: the blank-password
logon test (auto-logon), the WATCHOUT 7 programs-entry lookup (and the
start-screen profile suggestion built on it), the CodeMeter service check,
and AMD RAID / RAID-app detection. Those steps stay in checklist order as
manual steps without a check (WATCHOUT 6 is still found by WATCHPOINT.exe /
WATCHMAKER.exe, as in the script). The remaining items above (Wake on
Magic Packet, display scale, static IP, BitLocker, media drive) are the
owner-requested actions and stay, untested until run on a VM.

## 26. Redesign: what the wizard does itself (new, v0.2)

**Owner decisions (Oct 2026):** the wizard runs on machines where Windows is
already installed (checklist sections "Before you start" and "Install
Windows" removed; the "have ready" list stays as a note on the start
screen). Automatic: BitLocker off, media drive initialise + format,
indexing off, static IP, Wake on Magic Packet. Manual: Windows Update,
drivers from the USB folder, NVIDIA driver, WinUtil, NVIDIA Control Panel,
WATCHOUT install, startup apps. Auto-logon: not needed (the only account
has no password; the check confirms it). Steps found done by a check are
marked done and the wizard jumps to what is missing; "Fix what's missing"
confirms each step.

