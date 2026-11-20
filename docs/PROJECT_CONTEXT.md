# Project context and decision log

Everything learned while building and field-testing the WATCHOUT 6/7 server
procedure (Oct 2026). This is the "why" behind the checklists and scripts.
Items marked **[Uncertain]** were not confirmed against primary documentation
or real hardware.

## 1. Scope and starting point

- Base reference: Dataton **"WATCHOUT Windows 10 Enterprise Tweaking Guide"**,
  doc. 3749 rev 1.3 (2018), chapters 1–13. Adapted to Windows 11 Pro 25H2.
- OS: Windows 11 Pro 64-bit **25H2**, built as a stripped **MicroWin** ISO with
  Chris Titus **WinUtil**. 25H2 = the 24H2 codebase + an enablement package.
- WATCHOUT 7: tested against **7.8.4** (user guide generated for 7.8.2, July 2026).
- WATCHOUT 6: no official Windows 11 certification; Dataton KB (30 Mar 2026)
  reports it works on Win11 Pro and suggests Win11 IoT Enterprise LTSC if unstable.
- Owner's original WO7 routine (kept): MicroWin ISO → SearchOrderConfig 0 →
  all updates → all drivers → WinUtil debloat → install WATCHOUT → services
  to Manual (not disabled) → NVIDIA global profile "Workstation – Dynamic
  Streaming" → firewall and real-time protection off.

## 2. Install-phase knowledge (RAID, boot)

- **AMD RAIDXpert2 driver order** (Setup "Load driver", `drvload`, `pnputil`):
  `rcbottom` → `rcraid` → `rccfg` (Dell KB 000443715, 24 May 2026).
  Need the full .inf/.sys/.cat set, not just .sys.
- **Broadcom MegaRAID**: one driver per controller, no order
  (9500/9600 series e.g. 9560-8i: `megasas35.inf`). Older 9361 and IT-mode
  HBAs use different drivers **[Uncertain]**.
- With AMD NVMe RAID, raw member disks can be visible in Setup **before** the
  driver is loaded (inbox NVMe driver). **Never partition/install while member
  disks are shown raw**: writing a GPT to a raw member can destroy the RAID
  metadata (likely kept at the end of the disk **[Uncertain]**) → array shows
  **Offline** at next boot. This happened on the ThinkStation P8 (30HH); fix
  was deleting and recreating the array.
- Create the **system volume first** (Array 1), then the media RAID0. Dell's AMD
  guide states the first RAID volume is the only supported OS target.
- Missing "Windows Boot Manager" after install: check where the FAT32 ESP is
  (`diskpart list vol`); Setup puts the ESP on "Disk 0" or reuses an existing
  ESP. Fix: `bcdboot W:\Windows /s S: /f UEFI`, `bcdedit /enum firmware`;
  UEFI-only boot, no CSM.
- Drivers loaded with "Load driver" during Setup are carried into the installed
  OS (at least the boot-critical ones; booting proves rcraid/rcbottom arrived).
  `rccfg` may not be **[Uncertain]** → verify with `pnputil /enum-drivers`.
- Injecting drivers into an ISO: mount `boot.wim` index 2 (Setup) and
  `install.wim`, `dism /Add-Driver /Recurse`, commit, rebuild with
  `oscdimg -m -o -u2 -udfver102 -bootdata:2#p0,e,b<etfsboot.com>#pEF,e,b<efisys.bin>`
  (bootdata paths may not contain spaces or quotes). DISM mount needs an
  **NTFS** volume (error 0xc142011f = no reparse points, e.g. exFAT/USB).

## 2a. Partition layout with the factory-restore partition (WO7, Nov 2026)

Owner decision (20 Nov 2026): the recovery partition is made **in Windows
Setup**, not by the wizard, so the wizard never shrinks C:. Size 40–50 GB
(**45 GB** below) is the suggestion, not a limit: make it larger if the
images need it (C: and D: together; the capture checks the room first). Layout of the system disk: EFI | MSR | Windows (C:) |
`WO_RECOVERY`. The media RAID0 stays a separate disk.

In Windows Setup, after "Load driver" for the RAID controller (never while
raw member disks are shown, §2), press **Shift+F10**:

```text
diskpart
list disk
select disk <n>              the system array: check the size
list partition               must list nothing; otherwise delete the old
                             partitions in Setup's disk screen first
convert gpt                  "not convertible" here = already GPT, carry on
create partition efi size=260
format quick fs=fat32 label="System"
create partition msr size=16
create partition primary
shrink minimum=46080         45 GB left at the end of the disk
format quick fs=ntfs label="Windows"
create partition primary
format quick fs=ntfs label="WO_RECOVERY"
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
list partition
exit
```

Then **Refresh** in Setup's disk screen, select the "Windows" partition and
install into it. Recovery type ID and attributes (platform-required + no
drive letter) are the ones Microsoft documents for its own recovery
partition ([UEFI/GPT-based hard drive partitions](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions)).
EFI 260 MB covers 4K-native drives (Microsoft's minimum is 100 MB).
No `clean`: the repo rule against `diskpart clean` stays (AGENTS.md rule 7).

**[Uncertain]:** whether Windows 11 25H2 Setup then puts its own WinRE
(`\Recovery\WindowsRE\winre.wim`, ~1 GB) into `WO_RECOVERY`, into C:, or
into a new partition it creates; MicroWin may remove WinRE altogether.
Check after the install with `Get-Partition` and `reagentc /info`. Any of
the three is acceptable; the toolkit must leave a `\Recovery` folder alone.

## 3. Phase order and why

1. **PreUpdate offline** (cable unplugged): `SearchOrderConfig=0` +
   policy "Do not include drivers with Windows Updates"
   (`ExcludeWUDriversInQualityUpdate=1`) + driver-search prompt off.
   SearchOrderConfig alone does NOT stop Windows Update offering drivers.
2. NIC driver from USB (`pnputil /add-driver <path>\*.inf /subdirs /install`),
   then plug in the cable.
3. Windows Update until nothing is left.
4. Drivers (RAID check + RAIDXpert2, chipset, NVIDIA at the version tested for
   the WATCHOUT release, capture/audio).
5. BitLocker: 24H2+ enables device encryption by default; disable it
   (`manage-bde -off C:`) or a BIOS/RAID change can trigger a recovery-key prompt.
6. WinUtil debloat (after updates/drivers: updates can re-add apps; some driver
   companion apps are Store-based and can fail if the Store is gone first).
7. WATCHOUT install (+ working directory / Shows folder on the media drive).
8. Tamper Protection OFF (manual) → **PostInstall** → reboot.
9. Verify, soak test, image the system disk.

## 4. WinUtil selection (both versions)

- Tweaks: Activity History, ConsumerFeatures, Delivery Optimization, Explorer
  folder discovery, Hibernation, Location, Store search results, Services to
  Manual, Telemetry, Temp files, Widgets, WPBT, Home and Gallery, OneDrive
  removal, System Tray notifications, Windows AI; plus BitLocker - Disable,
  Visual Effects - Best Performance, Storage Sense - Disable.
- Skip: Edge removal (keeps WebView2), IPv6 disable, UTC time, O&O ShutUp10++,
  Ultimate Performance buttons (PostInstall makes its own plan),
  "Disable all updates" in WinUtil (PostInstall does the same later).
- Preferences: BSoD Verbose on, Lock Screen - Disable on, Sticky Keys off,
  Game Mode off; Multiplane Overlay left Enabled (disable only if soak test
  shows flicker; registry method reportedly ignored on 24H2+ **[Uncertain]**).
- Known harmless WinUtil errors on a stripped install: `wermgr` service not
  found, `PeriodInNanoSeconds` missing, `store.db` missing, `FileCoAuth` not
  running, `icacls $Env:OneDrive` empty variable.

## 5. Script design decisions (both scripts)

- **LGPO.exe** (Microsoft Security Compliance Toolkit) writes policies into the
  Local GPO (Registry.pol) so they show in gpedit; backup first with `LGPO /b`,
  rollback `LGPO /g`. Without LGPO.exe the scripts fall back to direct registry
  writes (User-scope policies then only reach the running account).
  Redistribution terms of LGPO.exe **[Uncertain]** → do not bundle without
  checking; alternatively implement Registry.pol (PReg format) natively.
- Policies are queued and de-duplicated (last definition of Scope+Key+Name wins).
- **Tamper Protection**: if on, `-DefenderMode Off` does NOT write the
  real-time policies (they'd be ignored) and warns. Exclusions are always
  added as a fallback. `DisableAntiSpyware` is ignored on client Windows since
  Defender 4.18.2007.8 (Aug 2020): written for guide parity only.
  Field observation: `DisableAntiSpyware` did not appear in gpedit on 25H2
  while the other Defender policies did — cause not established.
- Store/consumer-experiences/tips policies are **ignored on Pro** (Enterprise/
  Education only, KB3135657): written for parity, labelled "IGNORED ON PRO".
- "Do not connect to any WU Internet locations" only works with a WSUS server set.
- **Power**: plan cloned from Ultimate Performance under a fixed GUID
  ("WATCHOUT 7" / "WATCHOUT 6"), sleep/hibernate/display/disk never, PCIe ASPM
  off, USB selective suspend off, **CPU min 0 % / max 100 %** (owner's choice).
- NIC: OS power-off disabled, EEE/Green Ethernet off (vendor-specific names,
  matched by pattern). Changing NIC properties resets the link — never during a show.
- Network location forced Private; `NewNetworkWindowOff` key suppresses the flyout.
- **Windows Update: fully disabled by default** (owner's decision: servers are
  never patched in place; a newer OS is reinstalled from a fresh ISO).
  Exactly WinUtil's "Disable all updates" steps (owner decision, Oct 2026;
  WinUtil `Invoke-WPFUpdatesdisable.ps1`, checked 30 Oct 2026): NoAutoUpdate
  and AUOptions 1 written straight to the registry, DODownloadMode 0,
  BITS/wuauserv/UsoSvc disabled (CSV backup added by the script),
  SoftwareDistribution cleared, update scheduled tasks disabled. The earlier
  extras (guide 7.4.11.1 / 7.4.11.3 policies, feature-version pin,
  update-notification policy, `-PinVersion`) were dropped.
  `-KeepUpdateService` keeps the services and tasks. Side effects:
  Settings → Windows Update and Activation pages show 0x80070422; check
  activation with `slmgr /xpr`. WaaSMedicSvc (protected) may re-enable
  wuauserv — re-check after reboot.
- Windows 11 26H2 was released 29 Sep 2026 as an enablement package; with only
  NoAutoUpdate it was still *offered* → hence the pin and the full disable.
- Registry (guide ch. 12): TdrDelay 15, TdrDdiDelay 60, SystemResponsiveness 10
  (guide says 5; values <10 reportedly treated as 10 **[Uncertain]**),
  Win32PrioritySeparation 0x28 only with `-Role Production`.
- Re-running: safe with the SAME options; switching an option later does NOT
  remove what an earlier run applied (restore LGPO backup or set policies to
  Not configured first).
- PreUpdate is safe to run again; PostInstall prints a warnings summary and
  keeps a transcript next to the script.

## 6. WATCHOUT 7 specifics (WO7-Setup.ps1)

- WATCHOUT 7 runs as **services** (Process Manager etc.) and **creates and
  self-heals its own Windows Firewall rules** at every node start (UDP 123,
  3011, 3012 + program rules; TCP 3017–3025, Asset Manager 3023).
  Firewall off is still the default (guide 7.1); `-KeepFirewall` is valid.
- Working directory default: `.wo` next to the install; move it to the media
  RAID0 via Nodes → Node Properties → Change Working Directory (folder must exist).
  Since Nov 2026 WATCHOUT 7 itself is installed on the RAID0 too (factory
  image covers C: and D:); the working directory stays in its own folder,
  outside the program folder.
- Services: owner keeps WinUtil "Set to Manual"; WO7 script does not disable
  chapter-11 services (only WSearch, see below).
- Oct 2026 (owner's decision): WO7 PostInstall also applies what WO6 automates
  for guide ch. 10 and 12.3: `Set-WindowsSettings` copied unchanged (UAC never
  notify, visual effects, Remote Assistance off, No Sounds, defrag schedule
  off, USB notifications off, taskbar badges off), indexing off by disabling
  WSearch (CSV backup), and Win8DpiScaling 1 / LogPixels 96. Adapter bindings
  (10.10) and the chapter 11 service list stay WO6-only. WATCHOUT 7 not
  depending on Windows Search is **[Uncertain]**.
- Dataton recommends keeping Windows 11 updated for WO7 rendering — the owner
  instead updates once at build time, then freezes for good.
- NVIDIA: Power Management Mode = Prefer Maximum Performance, V-Sync Off;
  driver version as listed in WATCHOUT release notes.
- Multicast discovery 239.2.2.2: IGMP snooping/multicast forwarding on managed
  switches; VLAN/VPN/NAT break discovery.

## 7. WATCHOUT 6 specifics (WO6-Setup.ps1)

- WATCHPOINT is a desktop app: **logon scheduled task** `\WATCHOUT\WATCHPOINT
  auto-start` (guide 13.1): highest privileges (needed for remote software
  upgrades), working dir = install folder, **ExecutionTimeLimit 0** (default
  72 h would kill it), **Priority 4** (default 7 = below normal),
  **`-Delay 8` by default** (`-StartDelay`), optional `-ShowsPath`.
  Scheduled tasks do not appear in Settings/Task Manager startup lists or
  shell:startup — look in Task Scheduler Library → WATCHOUT.
- **Guide 13.2 SSD retrim task removed** at the owner's request (NTFS still
  issues TRIM on delete). Weekly optimisation schedule is still disabled (10.9).
- Firewall: WATCHOUT 6 does NOT create rules. Default off; `-KeepFirewall` adds
  program rules for WATCHPOINT, WATCHMAKER, ImageServer. Ports (Dataton KB,
  2019): 3039 display cluster control, 3040 production control, 3041 VNC,
  5900, 6454 Art-Net, plus dynamic ports (file server, NDI, DIS).
- WATCHOUT 6 is **32-bit**: DirectShow ThreadPriority (0xF9) written to both
  registry views (WOW6432Node). Effect on current Windows **[Uncertain]**.
- Default install folder `C:\WATCHOUT 6`; Shows in `<install>\Shows`.
  Detection probes `.NET` file APIs (Join-Path throws on a missing drive letter
  under StrictMode — real bug found and fixed).
- Guide ch. 10 settings scripted: UAC never notify (ConsentPromptBehaviorAdmin
  0, PromptOnSecureDesktop 0, EnableLUA stays 1), Remote Assistance off,
  sound scheme ".None" + every event's `.Current` cleared, defrag schedule
  off, USB error notifications off **[Uncertain value]**, taskbar badges off,
  **visual effects**: `VisualFXSetting=2` alone does NOT apply effects —
  also writes UserPreferencesMask `90 12 03 80 10 00 00 00` **[Uncertain]**,
  DragFullWindows 0, FontSmoothing 0, MinAnimate 0, TaskbarAnimations 0,
  ListviewAlphaSelect 0, ListviewShadow 0, IconsOnly 1, EnableAeroPeek 0,
  AlwaysHibernateThumbnails 0, EnableTransparency 0 (takes effect after sign-in).
- Guide 10.10 IPv4-only bindings on physical adapters (`-KeepAdapterBindings`
  to skip; needed for SMB shares).
- Guide ch. 11 services disabled with CSV backup; `-KeepService` exceptions
  (e.g. TermService,SessionEnv,UmRdpService for RDP). Deliberately NOT
  disabled: TabletInputService (breaks typing in Start/Settings on Win11),
  WdNisSvc (protected), CodeMeter, Intel HDCP/HECI (vendor names vary).
  Disabling `wlidsvc` contributes to the Settings Activation page error.
- Licence key: CodeMeter (WIBU) per Dataton KB (WO7 section) **[Uncertain for WO6]**.
- DPI: Win8DpiScaling 1 + LogPixels 96 (Remote Access misaligns with scaling).
- HideAutoLogonUI (Windows Embedded key) written for parity, likely no effect on Pro.
- ForcePcieLinkSpeed opt-in only (AMD GPUs; guide warns of boot crashes).

## 8. Cloning / imaging knowledge

- Custom ISO from a finished machine: Sysprep `/generalize /oobe /shutdown`
  with unattend `Microsoft-Windows-PnpSysprep/PersistAllDeviceInstalls=true`
  (identical hardware only), capture with `dism /Capture-Image` from WinPE
  (load RAID drivers with `drvload` first), replace `install.wim`, rebuild ISO.
  Sysprep fails on per-user-but-not-provisioned Appx (0x80073cf2) and
  reportedly on BitLocker/encryption state; logs in `%WINDIR%\System32\Sysprep\Panther`.
- Per-user settings, the WATCHPOINT logon task, computer name, SID and
  activation don't survive generalize → re-run PostInstall after OOBE.
- Simpler for exact twins: disk image clone + rename + new IP.
- Licensing: one Windows licence per machine; formal reimaging rights belong
  to Commercial (Volume) Licensing media **[Uncertain how it applies here]**.

- **Factory restore (WO7, decided Nov 2026):** image of C: and the RAID0
  (D:, where WATCHOUT 7 is installed) taken at the end of the build, before
  any show, on the hidden `WO_RECOVERY` partition (§2a), restored from a
  WinPE that boots from that partition (RAM disk entry in the BCD) or from
  a USB stick. A reset erases C: and D:; shows and assets are uploaded
  again. New versions: rebuild (strict) or reset + update + capture
  (faster), WO7 checklist §9. Built (not yet run on Windows): ARCHITECTURE
  §14, `recovery/`, `tools/recovery/`, wizard steps WO7-08.13 to 08.18. Not
  "Reset this PC" (rebuilds from WinSxS, restores only inbox apps and INF
  drivers; the scripts also set the WinRE `DisableSetup` and `DisableSR`
  policies). Toolkit (untested templates): `recovery/`. Same machine only, no
  Sysprep; the CodeMeter dongle carries the licence, so a restore does not
  touch licensing. Open items: OPEN_QUESTIONS 29.

## 9. Field issues log

- **WO6 twin server, cyclical HAP stutter** (Oct 2026, unresolved at hand-off):
  twin built by hand with identical BIOS/NVCP/script; outputs fed to a
  Pixelhue P20 via identical EDIDs; Quadro Sync II installed but not
  configured on either machine; secondary Gen4 NVMe (7 GB/s CrystalDiskMark),
  no RAID. Owner believes the machine "can't keep up". Pending checks:
  GPU PCIe link gen/width under load (lane sharing with the M.2 slot),
  DIMM population/channels, GPU power connectors / throttle reasons, WHEA
  events, Defender actually off, then GPU swap between twins.
  Background logging recipe: `nvidia-smi --query-gpu=... -l 1 -f gpu.csv`
  and `logman create counter ...`, LatencyMon.
- Settings Activation page 0x80070422 → expected with updates/wlidsvc disabled;
  use `slmgr /xpr` / `slmgr /dli`.

## 10. Owner preferences

- Freelance media-server operator; WATCHOUT 6 & 7, Ross Vertex, vMix,
  Resolume, Barco Event Master, Pixelhue.
- Wants **all guide tweaks applied** (even if not strictly necessary),
  adapted to Windows 11; precise, professionally accurate behaviour; uncertain
  items flagged explicitly.
- Prefers the aggressive WinUtil-style Windows Update disable.
- English by default (Italian possible).
