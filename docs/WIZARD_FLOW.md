# Wizard flow — WATCHOUT 7 and WATCHOUT 6 profiles

Status: **proposal for owner review** (Oct 2026).
Order and content follow the checklists exactly:

- WO7: `docs/checklists/WATCHOUT7-Server-Build-Checklist.md` (Oct 14, 2026; WATCHOUT 7.8.4, Windows 11 25H2)
- WO6: `docs/checklists/WATCHOUT6-Server-Build-Checklist.md` (Oct 23, 2026; Windows 11 Pro 64-bit 25H2)

## Legend

| Mark | Meaning |
| --- | --- |
| **A** | **Automated**: the wizard runs it (engine phase or a command written in the checklist), after a confirmation where required. |
| **M** | **Manual**: instructions + optional "Open" button + **Mark done**. |
| **C** | **Check**: read-only verification; shows the checklist command and the expected result. |
| **M+C** | Manual step with a check attached. |
| **†** | **Check not written in the checklist.** Read-only, changes nothing. All approved by the owner (Oct 2026, OQ 16); the owner may strike individual ones later. |
| **pre-Win** | Happens before Windows exists (BIOS, Windows Setup). The wizard cannot run there: it shows these steps as a printable pre-flight list, and on first launch offers a read-only **retro-check** where one exists. |
| **⟳ Rn** | Reboot point. The wizard stores `pendingReboot`, offers "Reboot now", and when the operator starts the exe again from the USB stick it confirms the reboot through `LastBootUpTime` (ARCHITECTURE §7). |
| **🔒** | Explicit confirmation required (security-reducing or destructive; AGENTS.md rule 3). |
| **🌐** | Needs internet. **✈** must be offline. |
| **[Uncertain]** | Carried over from the checklists, scripts or PROJECT_CONTEXT; shown next to the step in the UI. |

Step ids are `<profile>-<checklist section>.<item>`; they are the keys in
`state.json`. Section numbers match the checklist.

---

## 0. Wizard start (both profiles — application plumbing, not a checklist item)

These steps prepare the wizard itself. They change nothing in Windows'
configuration; the only thing written is the wizard's own folder
(`%ProgramData%\WOSetupWizard`: state, logs, run folders). Nothing is
installed and nothing starts automatically (decided OQ 23): after every
reboot the operator starts the exe from the USB stick again.

| Id | Step | Type | Uses | Reboot |
| --- | --- | --- | --- | --- |
| W-00.1 | Choose profile (WATCHOUT 7 / WATCHOUT 6) and role (Display / Production). Profile is locked after the first automated step. | M | — | |
| W-00.2 | **LGPO.exe** is bundled inside the wizard exe (decided OQ 3): verify the extracted copy's Microsoft signature and SHA-256. | C | `Get-AuthenticodeSignature <path>` | |
| W-00.3 | Environment pre-flight: elevated; show account = elevated user; Windows PowerShell 5.1; no GPO-forced execution policy; OS = Windows 11 Pro 24H2/25H2. | C | ARCHITECTURE §10 | |
| W-00.4 | Create `%ProgramData%\WOSetupWizard` (state, logs). No copy of the exe, no scheduled task. | A | ARCHITECTURE §7 | |
| W-00.5 | Record machine info into state/report: model, BIOS version and date, OS build. | C† | `Get-CimInstance Win32_BIOS, Win32_ComputerSystem, Win32_OperatingSystem` | |

W-00.5 covers part of checklist §1 "write down the BIOS version" automatically
(the storage/RAID mode is still typed in by the operator: it is not readable
from Windows in a vendor-neutral way).

---

## WATCHOUT 7 profile

### WO7 §1 Before you start

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-01.1 | MicroWin installer USB (Windows 11 Pro), booted in UEFI mode | M pre-Win | Retro-check C†: firmware type UEFI — `$env:firmware_type` / `bcdedit /enum {current}` path ends in `winload.efi` | |
| WO7-01.2 | AMD RAID drivers rcbottom, rcraid, rccfg (.inf + .sys + .cat each) + AMD RAID package with RAIDXpert2 | M | C†: operator picks the driver folder; wizard lists which of `rcbottom/rcraid/rccfg` have all three of `.inf`, `.sys`, `.cat` (file presence only) | |
| WO7-01.3 | NIC driver | M | Folder captured for WO7-03.3 | |
| WO7-01.4 | NVIDIA driver at the version in the WATCHOUT release notes, not "latest" | M | Capture: tested version (typed) → used by WO7-04.5 | |
| WO7-01.5 | Chipset, capture and audio drivers | M | — | |
| WO7-01.6 | WO7-Setup.ps1 and LGPO.exe in the same folder | C | Both are embedded in the wizard exe; W-00.2 verifies LGPO.exe | |
| WO7-01.7 | BIOS: UEFI only (CSM off), Secure Boot as on last good build, Fast Boot off | M pre-Win | Retro-check C†: `Confirm-SecureBootUEFI` → **recorded**, not judged ("as on your last good build"). CSM/Fast Boot not readable from Windows. | |
| WO7-01.8 | BIOS: write down BIOS version and storage/RAID mode | M pre-Win | Version auto-recorded (W-00.5); RAID mode typed | |
| WO7-01.9 | RAID utility: system volume (1 TB) **first**, then RAID0 media array | M pre-Win | Retro-check C†: `Get-Disk \| Select Number, FriendlyName, Size, PartitionStyle, OperationalStatus` — shows two array disks, system volume holds C:. **[Uncertain]** how RAIDXpert2 arrays are named/numbered in `Get-Disk`. | |
| WO7-01.10 | No array shows Offline; if one does, delete and recreate | M pre-Win | Same retro-check: `OperationalStatus` | |

### WO7 §2 Install Windows (all pre-Win, guidance only)

Shown with the checklist warning: *never touch a disk in Setup before the RAID
drivers are loaded*. The wizard never runs any of these commands.

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-02.1 | Load driver: rcbottom → rcraid → rccfg | M pre-Win | — | |
| WO7-02.2 | Disk list shows the arrays, not member disks | M pre-Win | — | |
| WO7-02.3 | Shift+F10 → `diskpart` → `clean` system volume and RAID0 | M pre-Win | Guidance only (AGENTS.md rule 7) | |
| WO7-02.4 | Install to unallocated space on the system volume; leave RAID0 untouched | M pre-Win | — | |
| WO7-02.5 | First reboot: "Windows Boot Manager" in the boot menu (F12 on Lenovo) | M pre-Win | Retro-check C: `bcdedit /enum firmware` (checklist command). C†: which disk holds the FAT32 ESP: `Get-Partition \| Where GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'` | ⟳ R0 (Windows Setup, outside the wizard) |
| — | If the boot entry is missing: `bcdboot W:\Windows /s S: /f UEFI`, `bcdedit /enum firmware` | M | Shown as recovery text, never executed | |

**The wizard is first launched here**, on the first boot, from the USB stick
(W-00.x run now).

### WO7 §3 First boot, still offline ✈

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-03.1 | Log in with the show (auto-logon) account | M+C | C: W-00.3 identity check; records the show account SID (later checks) | |
| WO7-03.2 | Elevated PowerShell: `.\WO7-Setup.ps1 -Phase PreUpdate` (preceded by `-Audit`, S4) | **A** ✈ | Engine: **WO7-Setup.ps1 -Phase PreUpdate** (no other parameters). Pre-check C†: no physical adapter `Up` (`Get-NetAdapter -Physical`). Post-check C†: `SearchOrderConfig = 0` (`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching`), policies `ExcludeWUDriversInQualityUpdate = 1`, `DontPromptForWindowsUpdate = 1` read back. | ⟳ **R0b** (cable still unplugged; decided OQ 12) |
| WO7-03.2a | Reboot (cable still unplugged) | M | Checklist line added Oct 2026 (the script's "Reboot now" is right, OQ 12). Pre-check C†: still no physical adapter `Up`. | ⟳ **R0b** |
| WO7-03.3 | Install NIC driver from USB | **A** | Checklist command: `pnputil /add-driver <path>\*.inf /subdirs /install` (operator picks `<path>`). Exit code `3010` = success, reboot required → offer reboot. | ⟳ only if pnputil returns 3010 |
| WO7-03.4 | Adapter in Device Manager without warning icon | M+C | Open `devmgmt.msc`. C†: `Get-PnpDevice -Class Net -PresentOnly \| Select FriendlyName, Status, Problem` → physical NIC `Status = OK` | |
| WO7-03.5 | Plug in the network cable | M+C | C†: adapter `Status = Up` | |

### WO7 §4 Updates and drivers 🌐

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-04.1 | Windows Update: install everything, reboot, repeat until nothing is left | M 🌐 | Open `ms-settings:windowsupdate`. C†: pending-reboot probe (ARCHITECTURE §7.3). The step loops: "Reboot and come back" / "Nothing left — done". | ⟳ **R1** (repeated, operator-driven) |
| WO7-04.2 | RAID: three AMD drivers present | C | `pnputil /enum-drivers \| findstr /i /c:"rcbottom" /c:"rcraid" /c:"rccfg"` → **all three** found. Not applicable if no AMD RAID (operator confirms). PROJECT_CONTEXT: `rccfg` may not be carried over from Setup **[Uncertain]** — this check is how you find out. | |
| WO7-04.3 | Install AMD RAID package with RAIDXpert2 (same driver version as loaded in Setup) | M | C†: show `rcraid` driver version from `Get-WindowsDriver -Online` before/after for comparison (display only) | ⟳ R2 if installer asks |
| WO7-04.4 | Chipset and storage drivers | M | C† pending-reboot probe | ⟳ R2 if installer asks |
| WO7-04.5 | NVIDIA driver at the version tested for your WATCHOUT release | M+C | C†: `nvidia-smi --query-gpu=name,driver_version --format=csv,noheader` (or `Win32_VideoController.DriverVersion`) compared with the version captured in WO7-01.4 | ⟳ R2 if installer asks |
| WO7-04.6 | Capture and audio drivers; test each in the vendor's app | M | — | ⟳ R2 if installer asks |

### WO7 §5 Disks

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-05.1 | `manage-bde -status C:` → if not "Fully Decrypted" … | C | Shows `manage-bde -status C:`; evaluates `Get-BitLockerVolume -MountPoint C:` (`VolumeStatus = FullyDecrypted`) so it works on a localised Windows | |
| WO7-05.1a | … run `manage-bde -off C:` and wait | **A** 🔒 | Checklist command `manage-bde -off C:`; progress polled from `EncryptionPercentage` until FullyDecrypted. Shown only if 05.1 fails. | No reboot needed |
| WO7-05.2 | Disk Management: initialise RAID0 as GPT, format NTFS (64 KB optional) | M | Open `diskmgmt.msc`. **Never automated** (AGENTS.md rule 7). C†: `Get-Disk` (`PartitionStyle = GPT`) + `Get-Volume` (`FileSystem = NTFS`, `AllocationUnitSize`) for the RAID0 | |
| WO7-05.3 | Turn off indexing on the RAID0 drive | M+C | C†: `Get-CimInstance Win32_Volume \| Select DriveLetter, IndexingEnabled` → `False` for the RAID0 | |
| WO7-05.4 | RAIDXpert2: array healthy; write-back cache / read-ahead optional | M | — | |

### WO7 §6 WinUtil debloat 🌐

Shown with the checklist note: errors about `wermgr`, `PeriodInNanoSeconds`,
`store.db`, `FileCoAuth` and `$Env:OneDrive` are harmless on a stripped install.
WinUtil start (decided, OQ 4), operator's choice on this step:

- **Online:** plug the cable in briefly if needed; the wizard opens a visible
  elevated PowerShell window with `irm christitus.com/win | iex` (🌐).
- **Offline copy:** the operator picks a local `winutil.ps1`; the wizard shows
  and records its SHA-256 and the WinUtil version/date, then runs it elevated
  in a visible window. Whether every selected tweak works fully offline is
  **[Uncertain]** — check WinUtil's own log for download errors.

Later, a chosen subset of WinUtil tweaks may move into the scripts (owner to
pick the list); until then this section stays manual.

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-06.1 | Tweaks: Activity History, ConsumerFeatures, Delivery Optimization, Explorer folder discovery, Hibernation, Location, Store search results, Services to Manual, Telemetry, Temp files, Widgets, WPBT, Home and Gallery, OneDrive removal, System Tray notifications, Windows AI | M (tick list) | Capture: WinUtil version/date (typed) | |
| WO7-06.2 | Also tick: **BitLocker - Disable**, Visual Effects - Best Performance, Storage Sense - Disable | M (tick list) | — | |
| WO7-06.3 | Skip: Edge removal, IPv6 disable, UTC time, O&O ShutUp10++, "Disable all updates" | M (tick list) | — | |
| WO7-06.4 | Preferences: BSoD Verbose on, Lock Screen - Disable on, Sticky Keys off, Game Mode off | M (tick list) | — | |
| WO7-06.5 | Do NOT click either Ultimate Performance button | M | — | |
| WO7-06.6 | Multiplane Overlay: leave Enabled; disable only if soak test shows flicker/blackouts | M | Note: registry method reportedly ignored on 24H2+ **[Uncertain]** | |
| — | (after WinUtil) | C† | Pending-reboot probe; the checklist specifies no reboot here | ⟳ only if pending |
| — | Online launch used: unplug the cable again if the machine should stay offline | M | Shown only if the cable was plugged in for this step | |

### WO7 §7 WATCHOUT 7 and NVIDIA

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-07.1 | Install WATCHOUT | M+C | C†: Uninstall entry `DisplayName -match 'WATCHOUT'` with `InstallLocation` (same lookup as the script's `Get-WatchoutInstallPath`) → pre-fills `-WatchoutPath`; version captured for the report. | ⟳ if installer asks |
| WO7-07.2 | Folder on the RAID0, then Nodes → Node Properties → **Change Working Directory** | M+C | Capture: the path → option `-WorkingDirectory`. C†: `Test-Path <path>` | |
| WO7-07.3 | Auto-logon with `netplwiz` (missing checkbox → turn off "only allow Windows Hello sign-in") | M+C | Open `netplwiz`, `ms-settings:signinoptions`. C†: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon` `AutoAdminLogon = 1`, `DefaultUserName = <show account>` (password never read) | |
| WO7-07.4 | NVIDIA Control Panel: global profile "Workstation – Dynamic Streaming" | M | — | |
| WO7-07.5 | Confirm Power Management Mode = Prefer Maximum Performance, Vertical Sync = Off | M | — | |
| WO7-07.6 | Static IPs; one subnet; IGMP snooping / multicast forwarding for 239.2.2.2 | M+C | C†: physical adapters with `Get-NetIPInterface -AddressFamily IPv4` `Dhcp = Disabled`, IPv4 address and prefix listed (switch config cannot be checked) | |

### WO7 §8 Windows settings from the Dataton guide

**Automated since S1 (OQ 14, Oct 2026):** `WO7-Setup.ps1 -Phase PostInstall`
now applies WO7-08.1 to 08.7 (WO6's `Set-WindowsSettings`, copied unchanged),
08.9 (indexing off by disabling the Windows Search service) and the 96 DPI
values behind 08.10. The WO7 checklist lists them as "Applied by PostInstall"
and checks them in §10. In the wizard these rows are **C** steps run after
the PostInstall reboot (they also appear in the §10 audit, S4); their Open
buttons stay for a visual check. Still manual: 08.8 startup apps, 08.10
scale per output, 08.11 bindings, 08.12 Wake-on-LAN, 08.16 services.

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-08.1 | UAC → **Never notify** (10.8) | C (after ⟳ R3) | Open `UserAccountControlSettings.exe`. C†: `HKLM\…\Policies\System` `ConsentPromptBehaviorAdmin = 0`, `PromptOnSecureDesktop = 0` (the values the WO6 script uses for "Never notify") | |
| WO7-08.2 | Visual effects → Adjust for best performance (10.3; skip if ticked in WinUtil) | C (after ⟳ R3) | Open `SystemPropertiesPerformance.exe`. C†: `HKCU\…\Explorer\VisualEffects` `VisualFXSetting = 2` | |
| WO7-08.3 | Remote Assistance off (10.4) | C (after ⟳ R3) | Open `SystemPropertiesRemote.exe`. C†: `HKLM\SYSTEM\CurrentControlSet\Control\Remote Assistance` `fAllowToGetHelp = 0` | |
| WO7-08.4 | Sounds → "No Sounds" (10.7) | C (after ⟳ R3) | Open `mmsys.cpl`. C†: `HKCU\AppEvents\Schemes` default = `.None` | |
| WO7-08.5 | `dfrgui` → untick "Run on a schedule" (10.9) | C (after ⟳ R3) | Open `dfrgui`. C†: `Get-ScheduledTask -TaskPath '\Microsoft\Windows\Defrag\' -TaskName ScheduledDefrag` → `Disabled` | |
| WO7-08.6 | USB: connection and USB-issue notifications off (10.12) | C (after ⟳ R3) | Open `ms-settings:usb`. C†: `HKCU\Software\Microsoft\Shell\USB` `NotifyOnUsbErrors = 0` **[Uncertain value name]** | |
| WO7-08.7 | Taskbar: show badges off (10.13) | C (after ⟳ R3) | Open `ms-settings:taskbar`. C†: `HKCU\…\Explorer\Advanced` `TaskbarBadges = 0` | |
| WO7-08.8 | Startup apps: off for everything not needed (10.14) | M | Open `ms-settings:startupapps` | |
| WO7-08.9 | Indexing off on every drive (10.15) | C (after ⟳ R3) | PostInstall disables the Windows Search service (S1). C: `Get-Service WSearch` → `StartType = Disabled`. C† (informational): `Win32_Volume.IndexingEnabled` per fixed volume | |
| WO7-08.10 | Display scale 100 % on every output (12.3) | M+C | PostInstall also writes `Win8DpiScaling = 1`, `LogPixels = 96` (S1; system DPI only **[Uncertain]** for multi-display). Open `ms-settings:display`. C†: per-monitor DPI = 96 (`GetDpiForMonitor`, app is PerMonitorV2-aware) | |
| WO7-08.11 | `ncpa.cpl` → each show adapter: everything except IPv4 unticked; keep Client for MS Networks / File and Printer Sharing for shares (10.10) | M+C | Open `ncpa.cpl`. C†: `Get-NetAdapterBinding` per physical adapter — list what is still enabled (informational: the checklist allows exceptions) | |
| WO7-08.12 | Wake-on-LAN: BIOS + NIC "Wake on Magic Packet" = Enabled (10.11) | M+C | C†: `Get-NetAdapterAdvancedProperty` matching "Wake on Magic Packet" (display name is vendor-specific) | |
| WO7-08.16 | Services: WinUtil "Set to Manual" covers it; optionally disable Print Spooler, Fax, Bluetooth; never any WATCHOUT/Dataton service | M | Open `services.msc`. Not automated for WO7. | |
| WO7-08.17 | No auto-start task (WATCHOUT 7 runs as services; 13.1 not needed) | M (info) | — | |

Shown as information (checklist): *Skip from the guide: DirectShow
ThreadPriority, ForcePcieLinkSpeed, HideAutoLogonUI, Win8DpiScaling/LogPixels*,
and *already handled elsewhere: ch. 7 policies, AutoPlay, power plan, USB
selective suspend, PCIe link power management, hibernation (PostInstall);
apps, OneDrive, Cortana (WinUtil); auto-logon (§7)*.

### WO7 §9 PostInstall

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-09.1 | Windows Security → Manage settings → **Tamper Protection Off** | M+C | Open Windows Security (`windowsdefender://threatsettings` **[Uncertain URI on 25H2]**). C: `Get-MpComputerStatus \| Select IsTamperProtected` → `False`. Required only for `-DefenderMode Off`. | |
| WO7-09.2 | Options (checklist option table) | M | Options page (MILESTONES M4): `-Role`, `-DefenderMode`, `-KeepFirewall`, `-PinVersion`, `-KeepUpdateService`, `-WatchoutPath`, `-WorkingDirectory`. Shows the exact command line. | |
| WO7-09.3 | Elevated, from the show account: `.\WO7-Setup.ps1 -Phase PostInstall` | **A** 🔒 | Engine: **WO7-Setup.ps1 -Phase PostInstall** + options. Pre-checks: show account = elevated user; Tamper Protection (if Off mode); LGPO.exe. Confirmation summary (ARCHITECTURE §4.5). | |
| WO7-09.2a | Audit before applying: `WO7-Setup.ps1 -Phase PostInstall -Audit` with the same options → each item **Set** / **Not Set** | C | Read-only (decided OQ 10; script change S4). Feeds the confirmation summary: only "Not Set" items will change. | |
| WO7-09.4 | Read the warnings summary; fix and re-run if needed (safe to repeat) | C | Parsed `[WARN]` lines vs "Completed with N warning(s)". Re-run = same step, same options (banner if options changed: earlier changes are not undone). | |
| WO7-09.5 | Reboot | M | | ⟳ **R3** |

### WO7 §10 Verify, soak test, image

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO7-10.1 | Defender | C | `Get-MpComputerStatus \| Select IsTamperProtected, RealTimeProtectionEnabled, BehaviorMonitorEnabled, OnAccessProtectionEnabled` → **all False** (Off mode). Exclusions mode: real-time stays on → expectation shown as "Exclusions present": `Get-MpPreference \| Select ExclusionPath, ExclusionProcess`. Skip mode: NotApplicable. | |
| WO7-10.2 | Power plan | C | `powercfg /getactivescheme` → "WATCHOUT 7" (matched by GUID `6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e57`) | |
| WO7-10.3 | BitLocker | C | `manage-bde -status C:` → Protection Off (evaluated via `Get-BitLockerVolume`) | |
| WO7-10.3a | Update services still disabled after the reboot (the script asks for this re-check: WaaSMedicSvc may re-enable `wuauserv`) | C | `Get-Service BITS, wuauserv, UsoSvc \| Select Name, StartType` → `Disabled`. NotApplicable with `-KeepUpdateService`. Source: script comment, not a checklist line. | |
| WO7-10.3b | Registry: `TdrDelay = 15`, `TdrDdiDelay = 60` (12.2) | C | `reg query "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v TdrDelay` and `/v TdrDdiDelay`. Moved from §8 to here (decided OQ 13; checklist updated). | |
| WO7-10.3c | Registry: `SystemResponsiveness = 10` (12.1; guide says 5; values < 10 reportedly treated as 10 **[Uncertain]**) | C | `reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness` | |
| WO7-10.3d | Registry (Production only): `Win32PrioritySeparation = 40` (0x28) (12.3) | C | `reg query "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation`; NotApplicable for Display | |
| WO7-10.3e | Full audit after the reboot: `WO7-Setup.ps1 -Phase PostInstall -Audit` (and `-Phase PreUpdate -Audit`) → every item **Set** | C | Read-only (S4). Any "Not Set" is listed as a warning in the report. | |
| WO7-10.4 | All nodes discover each other; asset transfer to the RAID0 works | M | — | |
| WO7-10.5 | Optional: `secpol.msc` → Network List Manager Policies → User cannot change location | M | Open `secpol.msc` | |
| WO7-10.6 | Soak test: representative show, several hours, all outputs | M | Optional recorder (OQ 9) | |
| WO7-10.7 | Image the system disk | M | — | |
| W-99 | **Finish**: mark the build complete, generate report, offer support bundle | A | ARCHITECTURE §8 | |

### WO7 §11 Maintenance (information page + report section, not steps)

No in-place updates; `slmgr /xpr` for activation (C† button:
`cscript //nologo %windir%\System32\slmgr.vbs /xpr`); NVIDIA only tested
versions; image before RAID driver/BIOS updates; Offline array → RAIDXpert2
event log.

---

## WATCHOUT 6 profile

Differences from WO7 are in **bold** in the step text.

### WO6 §1 Before you start

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-01.1 | MicroWin USB (Windows 11 Pro 64-bit 25H2), UEFI | M pre-Win | Retro-check C† as WO7-01.1 | |
| WO6-01.2 | **WATCHOUT 6 installer, same version on every machine** | M | Capture: version (report) | |
| WO6-01.3 | **WATCHOUT licence key (USB) for this machine; production PC needs one too** | M | — | |
| WO6-01.4 | RAID drivers (**AMD: rcbottom, rcraid, rccfg; Broadcom MegaRAID: one driver, e.g. megasas35**) + RAID management app | M | C† folder scan as WO7-01.2 (AMD); for MegaRAID: `.inf` present. Older 9361 / IT-mode HBAs use other drivers **[Uncertain]** | |
| WO6-01.5 | NIC driver | M | Folder captured | |
| WO6-01.6 | NVIDIA driver at a version tested with your WATCHOUT 6 release | M | Capture: tested version | |
| WO6-01.7 | Chipset, capture and audio drivers (**capture cards need Windows 11 drivers**) | M | — | |
| WO6-01.8 | WO6-Setup.ps1 and LGPO.exe in the same folder | C | Both embedded; W-00.2 | |
| WO6-01.9 | BIOS: UEFI only, Fast Boot off, Secure Boot as last good build | M pre-Win | Retro-check C† as WO7-01.7 | |
| WO6-01.10 | BIOS: write down version and storage/RAID mode | M pre-Win | W-00.5 + typed RAID mode | |
| WO6-01.11 | RAID utility: system volume first, then media array; none Offline | M pre-Win | Retro-check C† as WO7-01.9 | |
| WO6-01.12 | **Plan a separate drive/partition for WATCHOUT and its Shows folder (guide ch. 1 and 9)** | M | Feeds WO6-05.3 | |

### WO6 §2 Install Windows (pre-Win, guidance only)

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-02.1 | Load driver: **AMD rcbottom, rcraid, rccfg; Broadcom: the single MegaRAID driver** | M pre-Win | — | |
| WO6-02.2 | Disk list shows arrays, not member disks | M pre-Win | — | |
| WO6-02.3 | Shift+F10 → `diskpart` → `clean` system volume and media array | M pre-Win | Guidance only | |
| WO6-02.4 | Install to unallocated space on the system volume; leave media array untouched | M pre-Win | — | |
| WO6-02.5 | **Local account named for the show (becomes the auto-logon account)** | M pre-Win | Retro-check C†: current user is a local account (not a Microsoft account) | |
| WO6-02.6 | First reboot: "Windows Boot Manager" in the boot menu | M pre-Win | Retro-check C: `bcdedit /enum firmware`; C† ESP location as WO7-02.5 | ⟳ R0 (outside) |

The WO6 checklist has no separate "boot entry missing" note; the WO7 recovery
text is shown for both profiles (PROJECT_CONTEXT §2 covers both).

### WO6 §3 First boot, still offline ✈

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-03.1 | Log in with the show account | M+C | As WO7-03.1 | |
| WO6-03.2 | Elevated PowerShell: `.\WO6-Setup.ps1 -Phase PreUpdate` | **A** ✈ | Engine: **WO6-Setup.ps1 -Phase PreUpdate**. Pre/post checks as WO7-03.2. | ⟳ **R0b** (decided OQ 12) |
| WO6-03.2a | Reboot (cable still unplugged) | M | As WO7-03.2a | ⟳ **R0b** |
| WO6-03.3 | NIC driver from USB: `pnputil /add-driver <path>\*.inf /subdirs /install` | **A** | As WO7-03.3 | ⟳ only on 3010 |
| WO6-03.4 | Adapter in Device Manager without a warning icon | M+C | As WO7-03.4 | |
| WO6-03.5 | Plug in the network cable | M+C | As WO7-03.5 | |

### WO6 §4 Updates and drivers 🌐

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-04.1 | Windows Update: everything, reboot, repeat | M 🌐 | As WO7-04.1 | ⟳ **R1** (repeated) |
| WO6-04.2 | RAID drivers present (AMD: `pnputil /enum-drivers \| findstr /i /c:"rcbottom" /c:"rcraid" /c:"rccfg"`), then the RAID management app | C + M | AMD: checklist command, three matches. **Broadcom: C†** `pnputil /enum-drivers \| findstr /i megasas` (the checklist gives only the AMD command). Then M: install the management app. | ⟳ R2 if installer asks |
| WO6-04.3 | Chipset and storage drivers | M | C† pending-reboot probe | ⟳ R2 if asked |
| WO6-04.4 | NVIDIA driver at the tested version | M+C | C† as WO7-04.5 | ⟳ R2 if asked |
| WO6-04.5 | Capture and audio drivers; **test each card in its vendor app before WATCHOUT** | M | — | ⟳ R2 if asked |
| WO6-04.6 | **Unplug the network cable again if the machine will stay offline (guide ch. 8)** | M+C | C†: adapter state recorded. If WinUtil is launched online in §6, the cable is plugged in briefly there (decided, OQ 20) | |

### WO6 §5 Disks

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-05.1 | `manage-bde -status C:` → if not "Fully Decrypted" … | C | As WO7-05.1 | |
| WO6-05.1a | … `manage-bde -off C:` and wait | **A** 🔒 | As WO7-05.1a | |
| WO6-05.2 | Media volume: GPT, NTFS (64 KB optional) | M+C | As WO7-05.2 (never automated) | |
| WO6-05.3 | **Decide: WATCHOUT on the media drive (e.g. `D:\WATCHOUT 6`) or default `C:\WATCHOUT 6` + Shows folder on the media drive** | M | Capture → options `-WatchoutPath` (expected install folder) and `-ShowsPath` | |
| WO6-05.4 | RAID management app: array healthy | M | — | |

### WO6 §6 WinUtil debloat 🌐

Same tick lists as WO7 §6 (WO6-06.1 … WO6-06.6), with the WO6 wording for the
skip list: *IPv6 disable (the script unbinds it per adapter)*, and *PostInstall
makes its own "WATCHOUT 6" plan*. Same harmless-errors note. Pending-reboot C†
afterwards. WinUtil start as in WO7 §6 (online or offline copy, OQ 4).

### WO6 §7 WATCHOUT 6, licence and NVIDIA

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-07.1 | Install WATCHOUT 6 to the folder chosen in §5 | M+C | C†: `WATCHPOINT.exe` or `WATCHMAKER.exe` exists in the chosen folder — same rule as the script's `Get-WatchoutInstallPath` (Uninstall entry, then `C:\WATCHOUT 6`, `D:\WATCHOUT 6`, `D:\WATCHOUT`). Mismatch with §5 → warning. | ⟳ if installer asks |
| WO6-07.2 | Plug in the licence key directly (no hub; rear ports preferred) | M | — | |
| WO6-07.3 | Key detected in CodeMeter Control Center | M+C | C†: CodeMeter runtime service present and running (`Get-Service CodeMeter`) **[Uncertain service name; CodeMeter for WO6 also [Uncertain] per PROJECT_CONTEXT §7]**. Licence visibility itself stays manual. Never modified. | |
| WO6-07.4 | Do NOT create a Startup-folder shortcut to WATCHPOINT | M+C | C†: no `.lnk` targeting WATCHPOINT in either Startup folder (the script warns about the same thing in PostInstall) | |
| WO6-07.5 | Auto-logon with `netplwiz` | M+C | As WO7-07.3 | |
| WO6-07.6 | NVIDIA Control Panel: Power Management = Prefer Maximum Performance, V-Sync Off | M | — | |
| WO6-07.7 | Display resolution and refresh set manually per output | M | Open `ms-settings:display` | |
| WO6-07.8 | Production PC: "Scroll inactive windows when hovering" Off | M | Role = Production only; open `ms-settings:mousetouchpad` | |
| WO6-07.9 | Fixed IPs (or by name), one subnet, no Wi-Fi for show traffic | M+C | C† as WO7-07.6, plus list any Wi-Fi adapter that is Up | |

### WO6 §8 PostInstall

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-08.1 | Tamper Protection Off | M+C | As WO7-09.1 | |
| WO6-08.2 | **Network cable to show devices unplugged or idle (bindings and NIC changes reset the link)** | M | Included in the confirmation text | |
| WO6-08.3 | Options (checklist option table) | M | Options page: `-Role`, `-ShowsPath`, `-StartDelay`, `-KeepService`, `-KeepServices`, `-KeepAdapterBindings`, `-KeepFirewall`, `-DefenderMode`, `-KeepUpdateService`, `-ForcePcieLinkSpeed`, `-WatchoutPath`, `-PinVersion` | |
| WO6-08.4 | Elevated, from the show account: `.\WO6-Setup.ps1 -Phase PostInstall` (+ options) | **A** 🔒 | Engine: **WO6-Setup.ps1 -Phase PostInstall** + options via the wrapper (array `-KeepService` splatted correctly). Pre-checks as WO7-09.3. Confirmation summary includes services, bindings, firewall, Defender, Windows Update. | |
| WO6-08.3a | Audit before applying: `WO6-Setup.ps1 -Phase PostInstall -Audit` with the same options → **Set** / **Not Set** | C | As WO7-09.2a | |
| WO6-08.5 | Read the warnings summary; fix and re-run with the SAME options | C | As WO7-09.4 | |
| WO6-08.6 | Keep `Services_Backup_<timestamp>.csv` and the `LGPO_Backup_<timestamp>` folder | A | Automatic: they stay in the run folder, are listed in Backups & tools and in the report, and go into the support bundle. Operator can also copy them to USB. | |
| WO6-08.7 | Reboot | M | | ⟳ **R3** |

### WO6 §9 Manual steps

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-09.1 | Display scale 100 % on every output | M+C | C† per-monitor DPI = 96, as WO7-08.10 | |
| WO6-09.2 | Startup apps: off for anything that can steal focus from WATCHPOINT (10.14) | M | Open `ms-settings:startupapps` | |
| WO6-09.3 | Vendor services if installed: Intel Content Protection HDCP / HECI, NVIDIA telemetry → Disabled in `services.msc` (11) | M+C | Open `services.msc`. C†: list services whose display name matches these (vendor names vary) and their start type — read-only | |
| WO6-09.4 | Wake-on-LAN: BIOS + "Wake on Magic Packet" = Enabled (10.11) | M+C | C† as WO7-08.12 | |
| WO6-09.5 | Optional: `secpol.msc` → User cannot change location (7.2) | M | — | |
| WO6-09.6 | **After the reboot**, open Performance Options once and confirm "Adjust for best performance" (10.3) | M+C | Open `SystemPropertiesPerformance.exe`. C†: `VisualFXSetting = 2`. Visual check needed because `UserPreferencesMask 90 12 03 80 10 00 00 00` is **[Uncertain]**. | after ⟳ R3 |
| WO6-09.7 | Settings → Bluetooth & devices → USB: notifications off (10.12) | M+C | C†: `NotifyOnUsbErrors = 0` **[Uncertain]** | |

### WO6 §10 Verify, soak test, image

| Id | Checklist item | Type | Uses / verification | Reboot |
| --- | --- | --- | --- | --- |
| WO6-10.1 | Reboot → auto-logon → WATCHPOINT starts full screen on its own | M | Display role only. Watch WATCHPOINT start on its own first, then start the wizard from the USB stick (OQ 23). | ⟳ **R4** |
| WO6-10.2 | Task Scheduler → WATCHOUT → "WATCHPOINT auto-start": last result 0x41301 (running), no time limit | C | `Get-ScheduledTask -TaskPath '\WATCHOUT\' -TaskName 'WATCHPOINT auto-start'` → `Settings.ExecutionTimeLimit = PT0S`; `Get-ScheduledTaskInfo` → `LastTaskResult = 267009` (0x41301). Display role only. | |
| WO6-10.3 | Defender: `Get-MpComputerStatus \| Select IsTamperProtected, RealTimeProtectionEnabled, BehaviorMonitorEnabled, OnAccessProtectionEnabled` → all False (Off mode) | C | As WO7-10.1 | |
| WO6-10.4 | `powercfg /getactivescheme` → "WATCHOUT 6" | C | GUID `6f1c2a10-7a3e-4b0e-9d1a-0a0b0c0d0e56` | |
| WO6-10.5 | `manage-bde -status C:` → Protection Off | C | As WO7-10.3 | |
| WO6-10.5a | Update services still disabled after reboot (script note on WaaSMedicSvc) | C | As WO7-10.3a | |
| WO6-10.5b | Full audit after the reboot (`-Audit`, both phases) → every item **Set** | C | As WO7-10.3e | |
| WO6-10.6 | Production PC goes online: every display computer found, media transfers complete | M | — | |
| WO6-10.7 | Remote Access from the production PC lines up with the display | M | — | |
| WO6-10.8 | Soak test: several hours, all outputs | M | Optional recorder (OQ 9) | |
| WO6-10.9 | Image the system disk | M | — | |
| W-99 | **Finish** | A | As WO7 | |

### WO6 §11 Maintenance (information page + report)

As WO7, plus: *before 25H2 support ends (about 24 months for Pro, so late 2027;
check Microsoft's release information) plan the rebuild*, and *re-run
PostInstall with the same options after any big change; re-image when verified*.

---

## Reboot summary

| Point | When | Who triggers | Profile |
| --- | --- | --- | --- |
| R0 | Windows Setup first reboot | Windows Setup (before the wizard exists) | both |
| R0b | After PreUpdate, cable still unplugged (checklists updated Oct 2026, OQ 12) | wizard offers | both |
| (opt.) | NIC driver, if `pnputil` returns 3010 | wizard offers | both |
| R1 | Windows Update loop, as many times as needed | operator, wizard offers | both |
| R2 | After any driver/vendor installer that asks, or when a reboot is pending | operator, wizard offers | both |
| R3 | After PostInstall (checklist) | wizard offers | both |
| R4 | Verification reboot: auto-logon + WATCHPOINT auto-start | operator | WO6 Display |

BitLocker decryption needs no reboot.

## Options captured along the way (pre-fill for the PostInstall options page)

| Captured at | Becomes |
| --- | --- |
| W-00.1 role | `-Role` |
| WO7-07.1 / WO6-07.1 install location | `-WatchoutPath` (only passed if it differs from what the script would detect) |
| WO7-07.2 working directory | `-WorkingDirectory` |
| WO6-05.3 Shows folder | `-ShowsPath` |

## [Uncertain] items surfaced in the UI

From the scripts, checklists and PROJECT_CONTEXT; each appears next to the
step it affects and in the report.

| Item | Where in the flow |
| --- | --- |
| LGPO `/t` merges with existing settings | Every engine run (backup taken first) |
| `NewNetworkWindowOff` keeps the discovery flyout hidden | PostInstall summary |
| Firewall policies may not show in gpedit's "Advanced Security" node; verify in `wf.msc` | PostInstall summary, verify |
| `NoInplaceSharing` value name | PostInstall summary |
| `UserPreferencesMask 90 12 03 80 10 00 00 00` (both scripts since S1) | WO6-09.6, WO7-08.2 |
| `NotifyOnUsbErrors` value (both scripts since S1) | WO7-08.6, WO6-09.7 |
| WATCHOUT 7 does not depend on Windows Search (WSearch disabled, S1) | WO7-08.9 |
| `LogPixels` sets the system DPI only, not each display's scale | WO7-08.10, WO6-09.1 |
| DirectShow `ThreadPriority` effect on current Windows (WO6) | PostInstall summary |
| `HideAutoLogonUI` likely no effect on Pro (WO6) | PostInstall summary |
| `SystemResponsiveness` < 10 treated as 10 | WO7-10.3c, WO6 report |
| Multiplane Overlay registry method ignored on 24H2+ | WO7-06.6, WO6-06.6 |
| AMD RAID metadata at end of disk; `rccfg` carried into the OS | §2 guidance, WO7-04.2 / WO6-04.2 |
| Broadcom 9361 / IT-mode drivers | WO6-01.4 |
| CodeMeter as the WO6 licence runtime | WO6-07.3 |
| `DisableAntiSpyware` not visible in gpedit on 25H2 | Verify page |
| WaaSMedicSvc re-enabling `wuauserv` | WO7-10.3a, WO6-10.5a |
| Reimaging rights under the licence | §10 image step note |
| `windowsdefender://threatsettings` URI | WO7-09.1, WO6-08.1 |
| RAIDXpert2 array naming in `Get-Disk` | WO7-01.9 retro-check |
